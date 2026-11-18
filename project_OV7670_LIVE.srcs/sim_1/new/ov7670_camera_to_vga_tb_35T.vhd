-- Step 7: End-to-end QVGA capture -> actual dual-port BRAM IP -> VGA 2x display.
-- Arty A7-35T, Vivado 2022.2, VHDL-2008.
-- Top: ov7670_camera_to_vga_tb_35T
-- Required sources: ov7670_capture.vhd (35T last-pixel fix),
--   vga_controller.vhd (35T QVGA mapping fix), blk_mem_gen_1 IP
--   configured 76800 x 12 bits, 17-bit addresses, read latency = 1.
-- This test bypasses SCCB configuration by asserting config_finished, whose
-- real FSM+I2C behavior was separately verified in Step 6.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity ov7670_camera_to_vga_tb_35T is
end entity;

architecture sim of ov7670_camera_to_vga_tb_35T is
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
    constant PCLK_HALF    : time := 25 ns;   -- camera stimulus = 20 MHz

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

    function source_pixel(index : natural) return std_logic_vector is
    begin
        -- Use precisely the same varying two-byte camera stimulus as the
        -- previously passing ov7670_capture_tb, making address shifts visible.
        return std_logic_vector(to_unsigned((16#1234# + 73 * index) mod 65536, 16));
    end function;

    procedure send_byte(
        signal pclk : out std_logic;
        signal data : out std_logic_vector(7 downto 0);
        constant byte_value : in std_logic_vector(7 downto 0)
    ) is
    begin
        data <= byte_value;
        pclk <= '0';
        wait for PCLK_HALF;
        pclk <= '1';
        wait for PCLK_HALF;
        pclk <= '0';
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
            pixel_data => pixel_data,
            wea => wea,
            dina => dina,
            addra => addra
        );

    -- Actual dual-clock IP, not a permissive combinational RAM mock.
    FRAME_BUFFER_DUT : blk_mem_gen_1
        port map (
            clka => clk100,
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
    WRITE_MONITOR : process(clk100)
        variable got_address : natural;
        variable expected16 : std_logic_vector(15 downto 0);
    begin
        if rising_edge(clk100) then
            if rst = '0' then
                if wea(0) = '1' then
                    assert writes < N_PIXELS
                        report "CAPTURE->BRAM FAIL: too many writes" severity failure;
                    got_address := to_integer(unsigned(addra));
                    assert got_address = writes
                        report "CAPTURE->BRAM FAIL: address expected=" & integer'image(writes) &
                               " got=" & integer'image(got_address) severity failure;
                    expected16 := source_pixel(writes);
                    assert dina = expected16(11 downto 0)
                        report "CAPTURE->BRAM FAIL: RGB444 data at pixel=" & integer'image(writes) &
                               " expected=0x" & to_hstring(expected16(11 downto 0)) &
                               " got=0x" & to_hstring(dina) severity failure;
                    writes <= writes + 1;
                end if;
                if frame_finished = '1' then
                    assert frame_pulses = 0
                        report "CAPTURE FAIL: extra frame_finished pulse" severity failure;
                    frame_pulses <= frame_pulses + 1;
                end if;
            end if;
        end if;
    end process;

    -- Stimulate a complete 320 x 240 QVGA frame in the real byte format.
    CAMERA_STIMULUS : process
        variable word16 : std_logic_vector(15 downto 0);
    begin
        wait for 100 ns;
        wait until falling_edge(clk100);
        rst <= '0';
        config_finished <= '1';  -- configuration already verified in Step 6
        capture_start <= '1';
        wait for 100 ns;
        wait until falling_edge(clk100);
        capture_start <= '0';
        wait for 100 ns;
        ov7670_vsync <= '0';
        wait for 200 ns;

        for y in 0 to IMG_H - 1 loop
            ov7670_href <= '1';
            wait for 100 ns;
            for x in 0 to IMG_W - 1 loop
                word16 := source_pixel(y * IMG_W + x);
                send_byte(ov7670_pclk, ov7670_data, word16(15 downto 8));
                send_byte(ov7670_pclk, ov7670_data, word16(7 downto 0));
            end loop;
            ov7670_href <= '0';
            wait for 150 ns;
        end loop;
        ov7670_vsync <= '1';
        wait for 200 ns;

        if writes < N_PIXELS then
            wait until writes = N_PIXELS for 20 us;
        end if;
        assert writes = N_PIXELS
            report "CAPTURE->BRAM FAIL: missing writes, got=" & integer'image(writes)
            severity failure;
        wait for 100 ns;
        assert frame_pulses = 1
            report "CAPTURE FAIL: frame_finished not asserted exactly once" severity failure;
        report "CAPTURE PASS: exactly 76800 camera RGB444 pixels written at 0..76799" severity note;
        report "FRAME PASS: exactly one frame_finished pulse" severity note;
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
                       " expected=0x" & to_hstring(expected_rgb) &
                       " got=0x" & to_hstring(observed_rgb) &
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

        report "BRAM PASS: real dual-port RAM stored and returned all 76800 RGB444 pixels" severity note;
        report "VGA PASS: 640x480 RGB444 mapping, 307200 visible pixels verified" severity note;
        report "SYNC PASS: HSYNC 96/800, VSYNC 2/525" severity note;
        report "PASS: camera -> BRAM -> VGA integrated frame completed for Arty A7-35T" severity note;
        finish;
        wait;
    end process;

    WATCHDOG : process
    begin
        wait for 35 ms;
        assert false report "TIMEOUT FAIL: camera -> BRAM -> VGA did not complete in 35 ms"
            severity failure;
        wait;
    end process;
end architecture;
