-- STEP 10: camera PCLK-domain capture -> real BRAM IP -> VGA 2x.
-- Arty A7-35T, Vivado 2022.2, VHDL-2008.
-- Simulation top: ov7670_pclk_to_vga_tb_35T
-- Uses the Step-9 PCLK-based ov7670_capture and the same 17-bit-address
-- VGA controller that PASSED the Step-7 end-to-end simulation.
-- The real blk_mem_gen_1 IP is required (NOT a mock RAM):
--   simple dual-port, 76800x12, 17-bit addresses, read latency 1.
-- Port A writes on the camera PCLK; port B reads on VGA pixel clock.
-- COM10=0x00: PCLK runs continuously during horizontal blanking.
-- Camera SCCB init is bypassed; it was tested separately in Step 6.
-- Functional simulation only: does not prove physical CDC/input timing.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity ov7670_pclk_to_vga_tb_35T is
end entity;

architecture sim of ov7670_pclk_to_vga_tb_35T is
    constant IMG_W        : natural := 320;
    constant IMG_H        : natural := 240;
    constant N_PIXELS     : natural := IMG_W * IMG_H;
    constant VGA_W        : natural := 640;
    constant VGA_H        : natural := 480;
    constant H_TOTAL      : natural := 800;
    constant V_TOTAL      : natural := 525;
    constant FRAME_TICKS  : natural := H_TOTAL * V_TOTAL;
    constant SYS_PERIOD   : time := 10 ns;
    constant PIX_PERIOD   : time := 39722 ps; -- approximately 25.175 MHz
    constant PCLK_HALF    : time := 20 ns;   -- camera stimulus = 25 MHz during active video

    signal clk100         : std_logic := '0';
    signal pxl_clk        : std_logic := '0';
    signal rst            : std_logic := '1';
    signal config_finished : std_logic := '0';
    signal capture_start  : std_logic := '0';
    signal vga_start      : std_logic := '0';
    signal ov7670_vsync   : std_logic := '1';
    signal ov7670_href    : std_logic := '0';
    signal ov7670_pclk    : std_logic := '0';
    signal ov7670_data    : std_logic_vector(7 downto 0) := (others => '0');
    signal frame_finished : std_logic;
    signal pixel_data     : std_logic_vector(15 downto 0);

    signal wea            : std_logic_vector(0 downto 0);
    signal addra          : std_logic_vector(16 downto 0);
    signal dina           : std_logic_vector(11 downto 0);
    signal addrb          : std_logic_vector(16 downto 0);
    signal doutb          : std_logic_vector(11 downto 0);
    signal enb            : std_logic := '0';
    signal hs             : std_logic;
    signal vs             : std_logic;
    signal red            : std_logic_vector(3 downto 0);
    signal green          : std_logic_vector(3 downto 0);
    signal blue           : std_logic_vector(3 downto 0);
    signal writes         : natural range 0 to N_PIXELS + 1 := 0;
    signal frame_pulses   : natural range 0 to 2 := 0;
    signal capture_ready  : std_logic := '0';
    signal target_frame   : std_logic := '0';

    function source_pixel(index : natural) return std_logic_vector is
    begin
        -- Use precisely the same varying two-byte camera stimulus as the
        -- previously passing ov7670_capture_tb, making address shifts visible.
        return std_logic_vector(to_unsigned((16#1234# + 73 * index) mod 65536, 16));
    end function;

    procedure send_byte(
        signal pclk : in std_logic;
        signal data : out std_logic_vector(7 downto 0);
        constant byte_value : in std_logic_vector(7 downto 0)
    ) is
    begin
        wait until falling_edge(pclk);
        data <= byte_value;
        wait until rising_edge(pclk);
        wait for 1 ns;
    end procedure;

    component blk_mem_gen_1 is
        port (
            clka  : in std_logic;
            ena   : in std_logic;
            wea   : in std_logic_vector(0 downto 0);
            addra : in std_logic_vector(16 downto 0);
            dina  : in std_logic_vector(11 downto 0);
            clkb  : in std_logic;
            enb   : in std_logic;
            addrb : in std_logic_vector(16 downto 0);
            doutb : out std_logic_vector(11 downto 0)
        );
    end component;
begin
    clk100  <= not clk100 after SYS_PERIOD / 2;
    pxl_clk <= not pxl_clk after PIX_PERIOD / 2;
    ov7670_pclk <= not ov7670_pclk after PCLK_HALF;

    CAPTURE_DUT : entity work.ov7670_capture(rtl)
        port map (
            clk => clk100,
            rst => rst,
            config_finished => config_finished,
            ov7670_vsync => ov7670_vsync,
            ov7670_href => ov7670_href,
            ov7670_pclk => ov7670_pclk,
            ov7670_data => ov7670_data,
            start => capture_start,
            frame_finished_o => frame_finished,
            pixel_data => open,
            wea => wea,
            dina => dina,
            addra => addra
        );

    -- Actual dual-clock IP, not a permissive combinational RAM mock.
    FRAME_BUFFER_DUT : blk_mem_gen_1
        port map (
            clka => ov7670_pclk,
            ena => '1',
            wea => wea,
            addra => addra,
            dina => dina,
            clkb => pxl_clk,
            enb => enb,
            addrb => addrb,
            doutb => doutb
        );

    VGA_DUT : entity work.vga_controller(rtl)
        port map (
            clk => clk100,
            rst => rst,
            pxl_clk => pxl_clk,
            start => vga_start,
            VGA_HS_O => hs,
            VGA_VS_O => vs,
            VGA_R => red,
            VGA_G => green,
            VGA_B => blue,
            addrb => addrb,
            doutb => doutb
        );

    -- Check the write address AND data before RAM clocks them into port A.
    WRITE_MONITOR : process(ov7670_pclk)
        variable got_address : natural;
        variable expected16 : std_logic_vector(15 downto 0);
    begin
        if rising_edge(ov7670_pclk) then
            if rst = '0' then
                if wea(0) = '1' then
                    assert target_frame = '1'
                        report "CAPTURE->BRAM FAIL: unexpected write in dummy frame"
                        severity failure;
                    assert writes < N_PIXELS
                        report "CAPTURE->BRAM FAIL: too many writes" severity failure;
                    got_address := to_integer(unsigned(addra));
                    assert got_address = writes
                        report "CAPTURE->BRAM FAIL: address expected=" & integer'image(writes) &
                               " got=" & integer'image(got_address) severity failure;
                    expected16 := source_pixel(writes);
                    assert dina = expected16(11 downto 0)
                        report "CAPTURE->BRAM FAIL: RGB444 data at pixel=" & integer'image(writes) &
                               " expected(dec)=" & integer'image(to_integer(unsigned(expected16(11 downto 0)))) &
                               " got(dec)=" & integer'image(to_integer(unsigned(dina))) severity failure;
                    writes <= writes + 1;
                end if;
            end if;
        end if;
    end process;

    -- FRAME_FINISHED belongs to the 100 MHz clock domain, NOT camera PCLK.
    -- Checking it on PCLK would miss a 10 ns pulse when PCLK is gated.
    FRAME_MONITOR : process(clk100)
    begin
        if rising_edge(clk100) then
            if rst = '0' and frame_finished = '1' then
                assert frame_pulses = 0
                    report "CAPTURE FAIL: extra frame_finished pulse" severity failure;
                frame_pulses <= frame_pulses + 1;
                assert writes = N_PIXELS
                    report "CAPTURE FAIL: frame_finished before all BRAM writes"
                    severity failure;
            end if;
        end if;
    end process;

    -- First use a dummy incomplete frame to allow START toggle to cross
    -- to the PCLK domain. The actual frame begins after a new VSYNC pulse.
    -- START (10 ns) and CONFIG_FINISHED (10 ns) occur with PCLK stopped.
    CAMERA_STIMULUS : process
        variable word16 : std_logic_vector(15 downto 0);
    begin
        wait for 100 ns;
        rst <= '0';
        wait for 400 ns;
        config_finished <= '1';
        wait for 10 ns;
        config_finished <= '0';
        wait for 300 ns;

        -- First ignore an unarmed line, then assert BTN3 mid-frame.
        ov7670_vsync <= '1';
        wait for 240 ns;
        ov7670_vsync <= '0';
        wait for 200 ns;
        ov7670_href <= '1';
        for i in 0 to 7 loop
            send_byte(ov7670_pclk, ov7670_data, x"AB");
        end loop;
        ov7670_href <= '0';
        wait for 200 ns;
        capture_start <= '1';
        wait for 10 ns;
        capture_start <= '0';
        wait for 300 ns;
        ov7670_href <= '1';
        for i in 0 to 7 loop
            send_byte(ov7670_pclk, ov7670_data, x"CD");
        end loop;
        ov7670_href <= '0';
        wait for 200 ns;
        assert writes = 0
            report "CAPTURE FAIL: wrote into RAM from partial frame" severity failure;

        ov7670_vsync <= '1';
        wait for 240 ns;
        ov7670_vsync <= '0';
        target_frame <= '1';
        wait for 200 ns;
        for y in 0 to IMG_H - 1 loop
            ov7670_href <= '1';
            for x in 0 to IMG_W - 1 loop
                word16 := source_pixel(y * IMG_W + x);
                send_byte(ov7670_pclk, ov7670_data, word16(15 downto 8));
                send_byte(ov7670_pclk, ov7670_data, word16(7 downto 0));
            end loop;
            ov7670_href <= '0';
            wait for 200 ns;
        end loop;
        wait for 400 ns;
        assert writes = N_PIXELS
            report "CAPTURE->BRAM FAIL: missing writes, got=" & integer'image(writes)
            severity failure;
        assert frame_pulses = 1
            report "CAPTURE FAIL: frame_finished not asserted exactly once" severity failure;
        assert to_integer(unsigned(addra)) = N_PIXELS - 1
            report "CAPTURE FAIL: final BRAM address not 76799" severity failure;
        report "CAPTURE PASS: 76800 RGB444 writes, continuous PCLK" severity note;
        capture_ready <= '1';
        wait;
    end process;

    VGA_SCOREBOARD : process
        variable x, y              : natural := 0;
        variable next_x, next_y    : natural := 0;
        variable expected_addr     : natural := 0;
        variable displayed_count   : natural := 0;
        variable hsync_low_count   : natural := 0;
        variable vsync_low_count   : natural := 0;
        variable expected_hs       : std_logic;
        variable expected_vs       : std_logic;
        variable expected_rgb      : std_logic_vector(11 downto 0);
        variable observed_rgb      : std_logic_vector(11 downto 0);
        variable pix16             : std_logic_vector(15 downto 0);
    begin
        wait until capture_ready = '1';
        -- Three read clocks preload RAM address 0 before enabling VGA.
        enb <= '1';
        wait until falling_edge(pxl_clk);
        wait until falling_edge(pxl_clk);
        wait until falling_edge(pxl_clk);
        vga_start <= '1';

        -- Verify a COMPLETE frame, including blanking and every active pixel.
        for tick in 1 to FRAME_TICKS loop
            wait until rising_edge(pxl_clk);
            if x = H_TOTAL - 1 then
                x := 0;
                if y = V_TOTAL - 1 then
                    y := 0;
                else
                    y := y + 1;
                end if;
            else
                x := x + 1;
            end if;
            wait for 1 ns;

            if x >= VGA_W + 16 and x < VGA_W + 16 + 96 then
                expected_hs := '0';
            else
                expected_hs := '1';
            end if;
            if y >= VGA_H + 10 and y < VGA_H + 10 + 2 then
                expected_vs := '0';
            else
                expected_vs := '1';
            end if;
            assert hs = expected_hs
                report "VGA HSYNC FAIL at x=" & integer'image(x) & " y=" & integer'image(y)
                severity failure;
            assert vs = expected_vs
                report "VGA VSYNC FAIL at x=" & integer'image(x) & " y=" & integer'image(y)
                severity failure;
            if hs = '0' then hsync_low_count := hsync_low_count + 1; end if;
            if vs = '0' then vsync_low_count := vsync_low_count + 1; end if;

            next_x := x;
            next_y := y;
            if next_x = H_TOTAL - 1 then
                next_x := 0;
                if next_y = V_TOTAL - 1 then
                    next_y := 0;
                else
                    next_y := next_y + 1;
                end if;
            else
                next_x := next_x + 1;
            end if;
            expected_addr := 0;
            if next_x < VGA_W and next_y < VGA_H then
                expected_addr := (next_y / 2) * IMG_W + (next_x / 2);
            end if;
            assert to_integer(unsigned(addrb)) = expected_addr
                report "VGA ADDRB FAIL at x=" & integer'image(x) & " y=" & integer'image(y) &
                       " expected=" & integer'image(expected_addr) &
                       " got=" & integer'image(to_integer(unsigned(addrb)))
                severity failure;

            observed_rgb := red & green & blue;
            if x < VGA_W and y < VGA_H then
                expected_addr := (y / 2) * IMG_W + (x / 2);
                pix16 := source_pixel(expected_addr);
                expected_rgb := pix16(11 downto 0);
                displayed_count := displayed_count + 1;
            else
                expected_rgb := (others => '0');
            end if;
            assert observed_rgb = expected_rgb
                report "CAMERA->VGA FAIL at x=" & integer'image(x) & " y=" & integer'image(y) &
                       " expected(dec)=" & integer'image(to_integer(unsigned(expected_rgb))) &
                       " got(dec)=" & integer'image(to_integer(unsigned(observed_rgb))) &
                       ". Check RAM latency, address mapping and source widths."
                severity failure;
        end loop;

        assert displayed_count = VGA_W * VGA_H
            report "VGA FAIL: visible pixel count" severity failure;
        assert hsync_low_count = 96 * V_TOTAL
            report "VGA FAIL: HSYNC low count" severity failure;
        assert vsync_low_count = 2 * H_TOTAL
            report "VGA FAIL: VSYNC low count" severity failure;
        assert writes = N_PIXELS and frame_pulses = 1
            report "END-TO-END FAIL: source frame changed during VGA scan"
            severity failure;

        report "BRAM PASS: real IP returned expected RGB444 through VGA scan" severity note;
        report "VGA PASS: 640x480 RGB444 mapping, 307200 visible pixels verified" severity note;
        report "SYNC PASS: HSYNC 96/800, VSYNC 2/525" severity note;
        report "PASS: STEP 10 PCLK camera -> REAL BRAM -> VGA for Arty A7-35T" severity note;
        finish;
        wait;
    end process;

    WATCHDOG : process
    begin
        wait for 35 ms;
        assert false report "TIMEOUT FAIL: STEP 10 PCLK -> real BRAM -> VGA did not complete in 35 ms"
            severity failure;
        wait;
    end process;
end architecture;
