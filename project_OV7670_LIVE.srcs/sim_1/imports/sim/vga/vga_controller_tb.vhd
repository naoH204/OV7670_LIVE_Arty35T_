--LIBRARY ieee;
--USE ieee.std_logic_1164.ALL;
--USE ieee.numeric_std.ALL;

--USE std.textio.ALL;
--USE std.env.finish;

--ENTITY vga_controller_tb IS
--END vga_controller_tb;

--ARCHITECTURE sim OF vga_controller_tb IS

--    CONSTANT pxclk_hz : INTEGER := 25e6;
--    CONSTANT clk_period : TIME := 1 sec / pxclk_hz;

--    SIGNAL clk : STD_LOGIC := '1';
--    SIGNAL rst : STD_LOGIC := '1';

--    SIGNAL hsync : STD_LOGIC := '0';
--    SIGNAL vsync : STD_LOGIC := '0';
--    SIGNAL vga_red : STD_LOGIC_VECTOR (3 DOWNTO 0) := (OTHERS => '0');
--    SIGNAL vga_blue : STD_LOGIC_VECTOR (3 DOWNTO 0) := (OTHERS => '0');
--    SIGNAL vga_green : STD_LOGIC_VECTOR (3 DOWNTO 0) := (OTHERS => '0');

--    SIGNAL addrb : STD_LOGIC_VECTOR(16 DOWNTO 0) := (OTHERS => '0');
--    SIGNAL doutb : STD_LOGIC_VECTOR(11 DOWNTO 0) := (OTHERS => '0');

--    SIGNAL vga_start : STD_LOGIC := '0';

--BEGIN

--    doutb <= x"F00" WHEN addrb = "00000000000000000" ELSE--17
--        x"0F0" WHEN addrb = "00000000000000001" ELSE
--        x"00F" WHEN addrb = "00000000000000010" ELSE
--        x"abc" WHEN addrb = "00000000000000011" ELSE
--        x"ef7" WHEN addrb = "00000000000000100" ELSE
--        (OTHERS => '0');

--    clk <= NOT clk AFTER clk_period / 2;

--    DUT : ENTITY work.vga_controller(rtl)
--        PORT MAP(
--            clk => clk,
--            rst => rst,
--            pxl_clk => clk,
--            VGA_HS_O => hsync,
--            VGA_VS_O => vsync,
--            start => vga_start,
--            VGA_R => vga_red,
--            VGA_B => vga_blue,
--            VGA_G => vga_green,
--            addrb => addrb,
--            doutb => doutb
--        );

--    vga_start <= '1';

--    SEQUENCER_PROC : PROCESS
--    BEGIN
--        WAIT FOR clk_period * 2;

--        rst <= '0';

--        WAIT FOR clk_period * 10;
--        WAIT ON vsync UNTIL falling_edge(vsync);

--        WAIT ON vsync UNTIL rising_edge(vsync);

--        WAIT FOR clk_period * 100;

--    END PROCESS;

--END ARCHITECTURE;

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE std.env.finish;

-- Arty A7-35T / OV7670 QVGA -> VGA pixel doubling test
-- Tests the actual blk_mem_gen_1 IP plus vga_controller (not an idealized RAM).
-- Requires the regenerated IP: 76800 x 12-bit, 17-bit addresses.
-- File type in Vivado: VHDL 2008.
ENTITY vga_controller_tb IS
END ENTITY;

ARCHITECTURE sim OF vga_controller_tb IS
    CONSTANT IMG_W       : NATURAL := 320;
    CONSTANT IMG_H       : NATURAL := 240;
    CONSTANT VGA_W       : NATURAL := 640;
    CONSTANT VGA_H       : NATURAL := 480;
    CONSTANT H_TOTAL     : NATURAL := 800;
    CONSTANT V_TOTAL     : NATURAL := 525;
    CONSTANT FRAME_WORDS : NATURAL := IMG_W * IMG_H;
    CONSTANT FRAME_TICKS : NATURAL := H_TOTAL * V_TOTAL;
    CONSTANT ACTIVE_PIX  : NATURAL := VGA_W * VGA_H;

    CONSTANT SYS_PERIOD  : TIME := 10 ns;
    CONSTANT PIX_PERIOD  : TIME := 39722 ps;  -- ~25.175 MHz

    SIGNAL clk100     : STD_LOGIC := '0';
    SIGNAL pxl_clk    : STD_LOGIC := '0';
    SIGNAL rst        : STD_LOGIC := '1';
    SIGNAL vga_start  : STD_LOGIC := '0';
    SIGNAL vga_hs     : STD_LOGIC := '1';
    SIGNAL vga_vs     : STD_LOGIC := '1';
    SIGNAL vga_red    : STD_LOGIC_VECTOR(3 DOWNTO 0);
    SIGNAL vga_green  : STD_LOGIC_VECTOR(3 DOWNTO 0);
    SIGNAL vga_blue   : STD_LOGIC_VECTOR(3 DOWNTO 0);

    SIGNAL wea        : STD_LOGIC_VECTOR(0 DOWNTO 0) := "0";
    SIGNAL addra      : STD_LOGIC_VECTOR(16 DOWNTO 0) := (OTHERS => '0');
    SIGNAL dina       : STD_LOGIC_VECTOR(11 DOWNTO 0) := (OTHERS => '0');
    SIGNAL addrb      : STD_LOGIC_VECTOR(16 DOWNTO 0);
    SIGNAL doutb      : STD_LOGIC_VECTOR(11 DOWNTO 0);
    SIGNAL enb        : STD_LOGIC := '0';

    -- Distinct RGB444 words make a one-pixel BRAM/VGA misalignment detectable.
    FUNCTION pixel_word(addr : NATURAL) RETURN STD_LOGIC_VECTOR IS
    BEGIN
        CASE addr IS
            WHEN 0                 => RETURN x"123";
            WHEN IMG_W - 1         => RETURN x"F00";
            WHEN IMG_W             => RETURN x"0F0";
            WHEN FRAME_WORDS - 1   => RETURN x"00F";
            WHEN OTHERS =>
                RETURN STD_LOGIC_VECTOR(to_unsigned(
                    (addr * 37 + (addr / IMG_W) * 113 + 16#35A#) MOD 4096, 12));
        END CASE;
    END FUNCTION;

    COMPONENT blk_mem_gen_1 IS
        PORT (
            clka  : IN STD_LOGIC;
            ena   : IN STD_LOGIC;
            wea   : IN STD_LOGIC_VECTOR(0 DOWNTO 0);
            addra : IN STD_LOGIC_VECTOR(16 DOWNTO 0);
            dina  : IN STD_LOGIC_VECTOR(11 DOWNTO 0);
            clkb  : IN STD_LOGIC;
            enb   : IN STD_LOGIC;
            addrb : IN STD_LOGIC_VECTOR(16 DOWNTO 0);
            doutb : OUT STD_LOGIC_VECTOR(11 DOWNTO 0)
        );
    END COMPONENT;

BEGIN
    clk100  <= NOT clk100 AFTER SYS_PERIOD / 2;
    pxl_clk <= NOT pxl_clk AFTER PIX_PERIOD / 2;

    -- Same dual-port frame-buffer IP as the top-level design.
    RAM : blk_mem_gen_1
        PORT MAP (
            clka  => clk100,
            ena   => '1',
            wea   => wea,
            addra => addra,
            dina  => dina,
            clkb  => pxl_clk,
            enb   => enb,
            addrb => addrb,
            doutb => doutb
        );

    VGA_DUT : ENTITY work.vga_controller(rtl)
        PORT MAP (
            clk      => clk100,
            rst      => rst,
            pxl_clk  => pxl_clk,
            VGA_HS_O => vga_hs,
            VGA_VS_O => vga_vs,
            VGA_R    => vga_red,
            VGA_G    => vga_green,
            VGA_B    => vga_blue,
            start    => vga_start,
            addrb    => addrb,
            doutb    => doutb
        );

    SEQUENCER_PROC : PROCESS
        VARIABLE x               : NATURAL := 0;
        VARIABLE y               : NATURAL := 0;
        VARIABLE next_x          : NATURAL := 0;
        VARIABLE next_y          : NATURAL := 0;
        VARIABLE expected_addr   : NATURAL := 0;
        VARIABLE visible_count   : NATURAL := 0;
        VARIABLE hsync_count     : NATURAL := 0;
        VARIABLE vsync_count     : NATURAL := 0;
        VARIABLE expected_hs     : STD_LOGIC;
        VARIABLE expected_vs     : STD_LOGIC;
        VARIABLE expected_rgb    : STD_LOGIC_VECTOR(11 DOWNTO 0);
        VARIABLE observed_rgb    : STD_LOGIC_VECTOR(11 DOWNTO 0);
    BEGIN
        WAIT FOR 100 ns;

        -- Stage 1: fill all 76800 camera pixels while VGA is held in reset.
        FOR i IN 0 TO FRAME_WORDS - 1 LOOP
            WAIT UNTIL falling_edge(clk100);
            wea   <= "1";
            addra <= STD_LOGIC_VECTOR(to_unsigned(i, 17));
            dina  <= pixel_word(i);
        END LOOP;
        WAIT UNTIL falling_edge(clk100);
        wea <= "0";
        REPORT "WRITE PASS: 76800 RGB444 values initialized in frame buffer" SEVERITY note;

        -- Preload the first read word, then start the VGA counters on a
        -- falling pixel-clock edge so testbench sampling is deterministic.
        enb <= '1';
        WAIT UNTIL falling_edge(pxl_clk);
        WAIT UNTIL falling_edge(pxl_clk);
        WAIT UNTIL falling_edge(pxl_clk);
        rst <= '0';
        vga_start <= '1';

        -- Stage 2: check every timing position of a COMPLETE 800x525 VGA frame.
        -- At reset the DUT counters are x=0, y=0. On each rising edge,
        -- the DUT advances to its next position; update the scoreboard too.
        FOR tick IN 1 TO FRAME_TICKS LOOP
            WAIT UNTIL rising_edge(pxl_clk);
            IF x = H_TOTAL - 1 THEN
                x := 0;
                IF y = V_TOTAL - 1 THEN
                    y := 0;
                ELSE
                    y := y + 1;
                END IF;
            ELSE
                x := x + 1;
            END IF;

            -- Let synchronous RAM output and concurrent RGB logic settle.
            WAIT FOR 1 ns;

            IF x >= VGA_W + 16 AND x < VGA_W + 16 + 96 THEN
                expected_hs := '0';
            ELSE
                expected_hs := '1';
            END IF;
            IF y >= VGA_H + 10 AND y < VGA_H + 10 + 2 THEN
                expected_vs := '0';
            ELSE
                expected_vs := '1';
            END IF;
            ASSERT vga_hs = expected_hs
                REPORT "HSYNC FAIL at x=" & INTEGER'image(x) &
                       ", y=" & INTEGER'image(y)
                SEVERITY failure;
            ASSERT vga_vs = expected_vs
                REPORT "VSYNC FAIL at x=" & INTEGER'image(x) &
                       ", y=" & INTEGER'image(y)
                SEVERITY failure;
            IF vga_hs = '0' THEN hsync_count := hsync_count + 1; END IF;
            IF vga_vs = '0' THEN vsync_count := vsync_count + 1; END IF;

            -- Verify VGA's *prefetch address* for the NEXT coordinate.
            -- The current displayed RGB is checked separately below.
            next_x := x;
            next_y := y;
            IF next_x = H_TOTAL - 1 THEN
                next_x := 0;
                IF next_y = V_TOTAL - 1 THEN
                    next_y := 0;
                ELSE
                    next_y := next_y + 1;
                END IF;
            ELSE
                next_x := next_x + 1;
            END IF;
            expected_addr := 0;
            IF next_x < VGA_W AND next_y < VGA_H THEN
                expected_addr := (next_y / 2) * IMG_W + (next_x / 2);
            END IF;
            ASSERT to_integer(unsigned(addrb)) = expected_addr
                REPORT "ADDRB FAIL at x=" & INTEGER'image(x) &
                       ", y=" & INTEGER'image(y) &
                       ": expected next address " & INTEGER'image(expected_addr) &
                       ", got " & INTEGER'image(to_integer(unsigned(addrb)))
                SEVERITY failure;

            observed_rgb := vga_red & vga_green & vga_blue;
            IF x < VGA_W AND y < VGA_H THEN
                expected_addr := (y / 2) * IMG_W + (x / 2);
                expected_rgb := pixel_word(expected_addr);
                visible_count := visible_count + 1;
            ELSE
                expected_rgb := (OTHERS => '0');
            END IF;
            ASSERT observed_rgb = expected_rgb
                REPORT "RGB / PIXEL DOUBLING FAIL at VGA x=" & INTEGER'image(x) &
                       ", y=" & INTEGER'image(y) &
                       "; expected 0x" & to_hstring(expected_rgb) &
                       ", got 0x" & to_hstring(observed_rgb) &
                       ". Check BRAM read latency and VGA prefetch."
                SEVERITY failure;
        END LOOP;

        ASSERT visible_count = ACTIVE_PIX
            REPORT "ACTIVE AREA FAIL: expected 307200 visible pixels, got " &
                   INTEGER'image(visible_count)
            SEVERITY failure;
        ASSERT hsync_count = 96 * V_TOTAL
            REPORT "HSYNC WIDTH FAIL: expected 50400 low samples, got " &
                   INTEGER'image(hsync_count)
            SEVERITY failure;
        ASSERT vsync_count = 2 * H_TOTAL
            REPORT "VSYNC WIDTH FAIL: expected 1600 low samples, got " &
                   INTEGER'image(vsync_count)
            SEVERITY failure;

        REPORT "HSYNC PASS: 96 low clocks per line; 800 clocks per line" SEVERITY note;
        REPORT "VSYNC PASS: 2 low lines per frame; 525 lines per frame" SEVERITY note;
        REPORT "ADDRB PASS: 17-bit QVGA address mapping in range 0..76799" SEVERITY note;
        REPORT "PIXEL DOUBLING PASS: all 307200 active VGA pixels matched 320x240 RGB444" SEVERITY note;
        REPORT "PASS: vga_controller_tb for Arty A7-35T completed" SEVERITY note;
        finish;
        WAIT;
    END PROCESS;

END ARCHITECTURE;
