LIBRARY ieee;
LIBRARY unisim;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE unisim.vcomponents.ALL;

-- Debug build for Arty A7-35T + OV7670 (no FIFO) + Pmod VGA.
-- Same entity name, same top-level ports and pin constraints as the user's top.
-- SW2=1: independent 640x480 VGA color bars (no camera/BRAM required).
-- SW2=0: original camera -> BRAM -> VGA path (enable with SW1=1).
-- SW3=0: LD4=PLL, LD5=PCLK, LD6=config_finished, LD7=frame_finished latched.
-- SW2/SW3 select four LED diagnostic pages; see README.
-- SCCB register readback is checked instead of relying on I2C ACK semantics.
ENTITY top IS
    PORT (
        clk              : IN    STD_LOGIC;
        uart_txd_in      : IN    STD_LOGIC;
        scl              : INOUT STD_LOGIC;
        sda              : INOUT STD_LOGIC;
        ov7670_vsync     : IN    STD_LOGIC;
        ov7670_href      : IN    STD_LOGIC;
        ov7670_pclk      : IN    STD_LOGIC;
        ov7670_xclk      : OUT   STD_LOGIC;
        ov7670_data      : IN    STD_LOGIC_VECTOR(7 DOWNTO 0);
        uart_rxd_out     : OUT   STD_LOGIC;
        btn              : IN    STD_LOGIC_VECTOR(3 DOWNTO 0);
        sw               : IN    STD_LOGIC_VECTOR(3 DOWNTO 0);
        led              : OUT   STD_LOGIC_VECTOR(3 DOWNTO 0);
        ov7670_pwdn      : OUT   STD_LOGIC;
        ov7670_reset     : OUT   STD_LOGIC;
        VGA_HS_O         : OUT   STD_LOGIC;
        VGA_VS_O         : OUT   STD_LOGIC;
        VGA_R            : OUT   STD_LOGIC_VECTOR(3 DOWNTO 0);
        VGA_B            : OUT   STD_LOGIC_VECTOR(3 DOWNTO 0);
        VGA_G            : OUT   STD_LOGIC_VECTOR(3 DOWNTO 0)
    );
END top;

ARCHITECTURE rtl OF top IS
    -- Synchronous, per-domain reset release. MMCM LOCKED inputs are
    -- synchronized individually before combining to avoid a LUT driving
    -- asynchronous reset pins (Vivado LUTAR-1 and BRAM REQP-1839).
    SIGNAL rst          : STD_LOGIC := '1';
    SIGNAL rst_vga      : STD_LOGIC := '1';
    SIGNAL xlock_sys_meta, xlock_sys_sync : STD_LOGIC := '0';
    SIGNAL vlock_sys_meta, vlock_sys_sync : STD_LOGIC := '0';
    SIGNAL xlock_vga_meta, xlock_vga_sync : STD_LOGIC := '0';
    SIGNAL vlock_vga_meta, vlock_vga_sync : STD_LOGIC := '0';
    SIGNAL xclk_locked  : STD_LOGIC := '0';
    SIGNAL vga_locked   : STD_LOGIC := '0';
    SIGNAL clocks_ready : STD_LOGIC := '0';

    SIGNAL pxl_clk      : STD_LOGIC := '0';
    SIGNAL cam_pclk_buf : STD_LOGIC;
    SIGNAL xclk_ov7670  : STD_LOGIC := '0';

    COMPONENT clk_generator IS
        PORT (
            reset           : IN  STD_LOGIC;
            clk_in1         : IN  STD_LOGIC;
            locked          : OUT STD_LOGIC;
            o_xclk_ov7670   : OUT STD_LOGIC
        );
    END COMPONENT;

    COMPONENT vga_clk_gen IS
        PORT (
            clk_in1    : IN  STD_LOGIC;
            reset      : IN  STD_LOGIC;
            clk_out1   : OUT STD_LOGIC;
            locked     : OUT STD_LOGIC
        );
    END COMPONENT;

    COMPONENT blk_mem_gen_1 IS
        PORT (
            clka  : IN  STD_LOGIC;
            ena   : IN  STD_LOGIC;
            wea   : IN  STD_LOGIC_VECTOR(0 DOWNTO 0);
            addra : IN  STD_LOGIC_VECTOR(16 DOWNTO 0);
            dina  : IN  STD_LOGIC_VECTOR(11 DOWNTO 0);
            clkb  : IN  STD_LOGIC;
            enb   : IN  STD_LOGIC;
            addrb : IN  STD_LOGIC_VECTOR(16 DOWNTO 0);
            doutb : OUT STD_LOGIC_VECTOR(11 DOWNTO 0)
        );
    END COMPONENT;

    SIGNAL edge             : STD_LOGIC_VECTOR(3 DOWNTO 0) := (OTHERS => '0');
    SIGNAL config_finished  : STD_LOGIC := '0';
    SIGNAL i2c_ack_err      : STD_LOGIC := '0';
    SIGNAL readback_index   : INTEGER RANGE 0 TO 78 := 0;
    SIGNAL readback_prev    : STD_LOGIC := '0';
    SIGNAL readback_match   : STD_LOGIC_VECTOR(2 DOWNTO 0) := (OTHERS => '0');
    SIGNAL readback_all_ok  : STD_LOGIC := '0';
    SIGNAL uart_start       : STD_LOGIC := '0';
    SIGNAL uart_serial      : STD_LOGIC := '0';
    SIGNAL uart_done_tx     : STD_LOGIC := '0';
    SIGNAL uart_byte_tx     : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
    SIGNAL frame_finished   : STD_LOGIC := '0';
    SIGNAL frame_seen       : STD_LOGIC := '0';

    SIGNAL wea              : STD_LOGIC_VECTOR(0 DOWNTO 0) := (OTHERS => '0');
    SIGNAL addra            : STD_LOGIC_VECTOR(16 DOWNTO 0) := (OTHERS => '0');
    SIGNAL dina             : STD_LOGIC_VECTOR(11 DOWNTO 0) := (OTHERS => '0');
    SIGNAL addrb            : STD_LOGIC_VECTOR(16 DOWNTO 0) := (OTHERS => '0');
    SIGNAL doutb            : STD_LOGIC_VECTOR(11 DOWNTO 0) := (OTHERS => '0');

    SIGNAL pclk_meta, pclk_sync, pclk_prev : STD_LOGIC := '0';
    SIGNAL vsync_meta, vsync_sync, vsync_prev : STD_LOGIC := '0';
    SIGNAL vsync_seen      : STD_LOGIC := '0';
    SIGNAL pclk_hold       : INTEGER RANGE 0 TO 10000000 := 0; -- ~100 ms at 100 MHz

    -- Extra synchronous-domain diagnostic observations only; no impact on
    -- Capture, BRAM or VGA functional paths.
    SIGNAL href_meta, href_sync : STD_LOGIC := '0';
    SIGNAL wr_meta, wr_sync     : STD_LOGIC := '0';
    SIGNAL wr_seen_pclk         : STD_LOGIC := '0'; -- sticky source-domain status
    SIGNAL high_meta, high_sync : STD_LOGIC := '0';
    SIGNAL href_seen, wr_seen   : STD_LOGIC := '0';
    SIGNAL high_seen, btn3_seen : STD_LOGIC := '0';

    SIGNAL sw1_meta, sw1_sync : STD_LOGIC := '0';
    SIGNAL sw2_meta, sw2_sync : STD_LOGIC := '0';

    SIGNAL normal_hs        : STD_LOGIC := '1';
    SIGNAL normal_vs        : STD_LOGIC := '1';
    SIGNAL normal_r         : STD_LOGIC_VECTOR(3 DOWNTO 0) := (OTHERS => '0');
    SIGNAL normal_g         : STD_LOGIC_VECTOR(3 DOWNTO 0) := (OTHERS => '0');
    SIGNAL normal_b         : STD_LOGIC_VECTOR(3 DOWNTO 0) := (OTHERS => '0');

    SIGNAL test_h           : INTEGER RANGE 0 TO 799 := 0;
    SIGNAL test_v           : INTEGER RANGE 0 TO 524 := 0;
    SIGNAL test_hs          : STD_LOGIC := '1';
    SIGNAL test_vs          : STD_LOGIC := '1';
    SIGNAL test_rgb         : STD_LOGIC_VECTOR(11 DOWNTO 0) := (OTHERS => '0');

    ATTRIBUTE ASYNC_REG : STRING;
    ATTRIBUTE ASYNC_REG OF xlock_sys_meta : SIGNAL IS "TRUE";
    ATTRIBUTE ASYNC_REG OF xlock_sys_sync : SIGNAL IS "TRUE";
    ATTRIBUTE ASYNC_REG OF vlock_sys_meta : SIGNAL IS "TRUE";
    ATTRIBUTE ASYNC_REG OF vlock_sys_sync : SIGNAL IS "TRUE";
    ATTRIBUTE ASYNC_REG OF xlock_vga_meta : SIGNAL IS "TRUE";
    ATTRIBUTE ASYNC_REG OF xlock_vga_sync : SIGNAL IS "TRUE";
    ATTRIBUTE ASYNC_REG OF vlock_vga_meta : SIGNAL IS "TRUE";
    ATTRIBUTE ASYNC_REG OF vlock_vga_sync : SIGNAL IS "TRUE";
    ATTRIBUTE ASYNC_REG OF pclk_meta : SIGNAL IS "TRUE";
    ATTRIBUTE ASYNC_REG OF pclk_sync : SIGNAL IS "TRUE";
    ATTRIBUTE ASYNC_REG OF vsync_meta : SIGNAL IS "TRUE";
    ATTRIBUTE ASYNC_REG OF vsync_sync : SIGNAL IS "TRUE";
    ATTRIBUTE ASYNC_REG OF href_meta : SIGNAL IS "TRUE";
    ATTRIBUTE ASYNC_REG OF href_sync : SIGNAL IS "TRUE";
    ATTRIBUTE ASYNC_REG OF wr_meta   : SIGNAL IS "TRUE";
    ATTRIBUTE ASYNC_REG OF wr_sync   : SIGNAL IS "TRUE";
    ATTRIBUTE ASYNC_REG OF high_meta : SIGNAL IS "TRUE";
    ATTRIBUTE ASYNC_REG OF high_sync : SIGNAL IS "TRUE";
    ATTRIBUTE ASYNC_REG OF sw1_meta : SIGNAL IS "TRUE";
    ATTRIBUTE ASYNC_REG OF sw1_sync : SIGNAL IS "TRUE";
    ATTRIBUTE ASYNC_REG OF sw2_meta : SIGNAL IS "TRUE";
    ATTRIBUTE ASYNC_REG OF sw2_sync : SIGNAL IS "TRUE";
BEGIN
    clocks_ready <= xclk_locked AND vga_locked;

    cam_pclk_global : BUFG
        PORT MAP (
            I => ov7670_pclk,
            O => cam_pclk_buf
        );

    -- Each MMCM LOCKED output is brought through 2 FFs before the AND.
    -- Reset is asserted/released *synchronously* in each local domain.
    -- Initial values keep both domains in reset during FPGA configuration.
    PROCESS(clk)
    BEGIN
        IF rising_edge(clk) THEN
            xlock_sys_meta <= xclk_locked;
            xlock_sys_sync <= xlock_sys_meta;
            vlock_sys_meta <= vga_locked;
            vlock_sys_sync <= vlock_sys_meta;
            rst <= NOT (xlock_sys_sync AND vlock_sys_sync);
        END IF;
    END PROCESS;

    PROCESS(pxl_clk)
    BEGIN
        IF rising_edge(pxl_clk) THEN
            xlock_vga_meta <= xclk_locked;
            xlock_vga_sync <= xlock_vga_meta;
            vlock_vga_meta <= vga_locked;
            vlock_vga_sync <= vlock_vga_meta;
            rst_vga <= NOT (xlock_vga_sync AND vlock_vga_sync);
        END IF;
    END PROCESS;

    xclk_pll : clk_generator
        PORT MAP (
            clk_in1 => clk,
            o_xclk_ov7670 => xclk_ov7670,
            reset => '0',
            locked => xclk_locked
        );

    vga_pll : vga_clk_gen
        PORT MAP (
            clk_in1 => clk,
            reset => '0',
            clk_out1 => pxl_clk,
            locked => vga_locked
        );

    ov7670_xclk <= xclk_ov7670;
    ov7670_pwdn <= '0';

    ov7670_configuration : ENTITY work.ov7670_configuration(Behavioral)
        PORT MAP (
            clk => clk,
            rst => rst,
            sda => sda,
            edge => edge,
            scl => scl,
            ov7670_reset => ov7670_reset,
            start => edge(0),
            ack_err => i2c_ack_err,
            done => uart_start,
            config_finished => config_finished,
            reg_value => uart_byte_tx
        );

    frame_buffer : blk_mem_gen_1
        PORT MAP (
            clka => cam_pclk_buf,
            ena => '1',
            wea => wea,
            addra => addra,
            dina => dina,
            clkb => pxl_clk,
            enb => '1',
            addrb => addrb,
            doutb => doutb
        );

    ov7670_capture : ENTITY work.ov7670_capture(rtl)
        PORT MAP (
            clk => clk,
            rst => rst,
            config_finished => config_finished,
            ov7670_pclk => cam_pclk_buf,
            ov7670_vsync => ov7670_vsync,
            ov7670_href => ov7670_href,
            ov7670_data => ov7670_data,
            start => edge(3),
            frame_finished_o => frame_finished,
            pixel_data => OPEN,
            wea => wea,
            dina => dina,
            addra => addra
        );

    EDGE_DETECT : ENTITY work.debounce(Behavioral)
        PORT MAP (
            clk => clk,
            btn => btn,
            edge => edge
        );

    UART_TX : ENTITY work.uart_tx_own(rtl)
        PORT MAP (
            clk => clk,
            rst => rst,
            i_start => uart_start,
            i_byte => uart_byte_tx,
            o_serial => uart_serial,
            o_done => uart_done_tx
        );

    -- Sample only slowly changing switches in the VGA clock domain.
    PROCESS(pxl_clk)
    BEGIN
        IF rising_edge(pxl_clk) THEN
            IF rst_vga = '1' THEN
                sw1_meta <= '0';
                sw1_sync <= '0';
                sw2_meta <= '0';
                sw2_sync <= '0';
            ELSE
                sw1_meta <= sw(1);
                sw1_sync <= sw1_meta;
                sw2_meta <= sw(2);
                sw2_sync <= sw2_meta;
            END IF;
        END IF;
    END PROCESS;

    vga_controller : ENTITY work.vga_controller(rtl)
        PORT MAP (
            clk => clk,
            rst => rst_vga,
            pxl_clk => pxl_clk,
            start => sw1_sync,
            VGA_HS_O => normal_hs,
            VGA_VS_O => normal_vs,
            VGA_R => normal_r,
            VGA_G => normal_g,
            VGA_B => normal_b,
            addrb => addrb,
            doutb => doutb
        );

    -- Independent VGA diagnostic: 640x480 visible, 800x525 total,
    -- 25.173 MHz pixel clock, eight 80-pixel-wide vertical color bars.
    PROCESS(pxl_clk)
    BEGIN
        IF rising_edge(pxl_clk) THEN
            IF rst_vga = '1' THEN
                test_h <= 0;
                test_v <= 0;
            ELSIF test_h = 799 THEN
                test_h <= 0;
                IF test_v = 524 THEN
                    test_v <= 0;
                ELSE
                    test_v <= test_v + 1;
                END IF;
            ELSE
                test_h <= test_h + 1;
            END IF;
        END IF;
    END PROCESS;

    test_hs <= '0' WHEN (test_h >= 656 AND test_h < 752) ELSE '1';
    test_vs <= '0' WHEN (test_v >= 490 AND test_v < 492) ELSE '1';

    PROCESS(test_h, test_v)
    BEGIN
        test_rgb <= (OTHERS => '0');
        IF test_h < 640 AND test_v < 480 THEN
            IF test_h < 80 THEN
                test_rgb <= x"FFF"; -- white
            ELSIF test_h < 160 THEN
                test_rgb <= x"FF0"; -- yellow
            ELSIF test_h < 240 THEN
                test_rgb <= x"0FF"; -- cyan
            ELSIF test_h < 320 THEN
                test_rgb <= x"0F0"; -- green
            ELSIF test_h < 400 THEN
                test_rgb <= x"F0F"; -- magenta
            ELSIF test_h < 480 THEN
                test_rgb <= x"F00"; -- red
            ELSIF test_h < 560 THEN
                test_rgb <= x"00F"; -- blue
            ELSE
                test_rgb <= x"000"; -- black
            END IF;
        END IF;
    END PROCESS;

    VGA_HS_O <= test_hs WHEN sw2_sync = '1' ELSE normal_hs;
    VGA_VS_O <= test_vs WHEN sw2_sync = '1' ELSE normal_vs;
    VGA_R <= test_rgb(11 DOWNTO 8) WHEN sw2_sync = '1' ELSE normal_r;
    VGA_G <= test_rgb(7 DOWNTO 4) WHEN sw2_sync = '1' ELSE normal_g;
    VGA_B <= test_rgb(3 DOWNTO 0) WHEN sw2_sync = '1' ELSE normal_b;

    -- A sticky BRAM-write observation registered in the CAMERA PCLK domain.
    -- Do not pass combinational WEA across CDC (previous CDC-10 Critical).
    -- Sticky until FPGA reconfiguration; there is deliberately no async reset
    -- on a BRAM-facing write-control path.
    PROCESS(cam_pclk_buf)
    BEGIN
        IF rising_edge(cam_pclk_buf) THEN
            IF wea(0) = '1' THEN
                wr_seen_pclk <= '1';
            END IF;
        END IF;
    END PROCESS;

    -- Diagnostic LEDs. In SW3=1 mode, display alternate diagnostics.
    PROCESS(clk)
    BEGIN
        IF rising_edge(clk) THEN
            IF rst = '1' THEN
                pclk_meta <= '0';
                pclk_sync <= '0';
                pclk_prev <= '0';
                vsync_meta <= '0';
                vsync_sync <= '0';
                vsync_prev <= '0';
                pclk_hold <= 0;
                vsync_seen <= '0';
                readback_index <= 0;
                readback_prev <= '0';
                readback_match <= (OTHERS => '0');
                frame_seen <= '0';
                href_meta <= '0';
                href_sync <= '0';
                wr_meta <= '0';
                wr_sync <= '0';
                high_meta <= '0';
                high_sync <= '0';
                href_seen <= '0';
                wr_seen <= '0';
                high_seen <= '0';
                btn3_seen <= '0';
            ELSE
                pclk_meta <= ov7670_pclk;
                pclk_sync <= pclk_meta;
                pclk_prev <= pclk_sync;
                href_meta <= ov7670_href;
                href_sync <= href_meta;
                wr_meta <= wr_seen_pclk;
                wr_sync <= wr_meta;
                high_meta <= addra(16);
                high_sync <= high_meta;
                vsync_meta <= ov7670_vsync;
                vsync_sync <= vsync_meta;
                vsync_prev <= vsync_sync;

                IF pclk_sync = '1' AND pclk_prev = '0' THEN
                    pclk_hold <= 10000000;
                ELSIF pclk_hold > 0 THEN
                    pclk_hold <= pclk_hold - 1;
                END IF;

                IF vsync_sync = '1' AND vsync_prev = '0' THEN
                    vsync_seen <= '1';
                END IF;
                -- SCCB readback check, sampled once per completed register read.
                -- ROM slots 1, 2, 3 are COM10, COM15, RGB444.
                -- The 9th SCCB bit can be Don't-Care: raw ACK is not reliable.
                readback_prev <= uart_start;
                IF edge(0) = '1' THEN
                    readback_index <= 0;
                    readback_match <= (OTHERS => '0');
                ELSIF uart_start = '1' AND readback_prev = '0' THEN
                    CASE readback_index IS
                        WHEN 1 =>
                            IF uart_byte_tx = x"00" THEN
                                readback_match(0) <= '1';
                            END IF;
                        WHEN 2 =>
                            IF uart_byte_tx = x"D0" THEN
                                readback_match(1) <= '1';
                            END IF;
                        WHEN 3 =>
                            IF uart_byte_tx = x"02" THEN
                                readback_match(2) <= '1';
                            END IF;
                        WHEN OTHERS => NULL;
                    END CASE;
                    IF readback_index < 78 THEN
                        readback_index <= readback_index + 1;
                    END IF;
                END IF;
                IF frame_finished = '1' THEN
                    frame_seen <= '1';
                END IF;
                IF edge(3) = '1' THEN
                    btn3_seen <= '1';
                END IF;
                IF href_sync = '1' THEN
                    href_seen <= '1';
                END IF;
                IF wr_sync = '1' THEN
                    wr_seen <= '1';
                END IF;
                IF high_sync = '1' THEN
                    high_seen <= '1';
                END IF;
            END IF;
        END IF;
    END PROCESS;

    readback_all_ok <= '1' WHEN readback_match = "111" ELSE '0';

    led(0) <= clocks_ready;                                -- LD4: PLL locked
    led(1) <= '1' WHEN pclk_hold > 0 ELSE '0';            -- LD5: PCLK detected
    -- Four debug display pages selected by SW2/SW3. They do not affect Capture.
    -- SW2=0, SW3=0: LD6=config_finished  LD7=frame_finished
    -- SW2=0, SW3=1: LD6=3 readbacks MATCH LD7=VSYNC seen
    -- SW2=1, SW3=0: LD6=BTN3 event seen  LD7=HREF seen
    -- SW2=1, SW3=1: LD6=BRAM WEA seen    LD7=BRAM address bit16 seen
    -- SW2 still selects independent VGA color bars when high.
    PROCESS(sw, config_finished, frame_seen, readback_all_ok, vsync_seen,
            btn3_seen, href_seen, wr_seen, high_seen)
    BEGIN
        led(2) <= '0';
        led(3) <= '0';
        IF sw(2) = '0' THEN
            IF sw(3) = '0' THEN
                led(2) <= config_finished;
                led(3) <= frame_seen;
            ELSE
                led(2) <= readback_all_ok;
                led(3) <= vsync_seen;
            END IF;
        ELSE
            IF sw(3) = '0' THEN
                led(2) <= btn3_seen;
                led(3) <= href_seen;
            ELSE
                led(2) <= wr_seen;
                led(3) <= high_seen;
            END IF;
        END IF;
    END PROCESS;

    uart_rxd_out <= uart_serial;
END rtl;
