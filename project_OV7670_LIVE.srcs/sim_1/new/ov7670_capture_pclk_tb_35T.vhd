LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

ENTITY ov7670_capture_pclk_tb_35T IS
END ENTITY;

ARCHITECTURE sim OF ov7670_capture_pclk_tb_35T IS
    SIGNAL clk100         : STD_LOGIC := '0';
    SIGNAL rst            : STD_LOGIC := '1';
    SIGNAL config_finished: STD_LOGIC := '0';
    SIGNAL start          : STD_LOGIC := '0';
    SIGNAL cam_vsync      : STD_LOGIC := '1';
    SIGNAL cam_href       : STD_LOGIC := '0';
    SIGNAL cam_pclk       : STD_LOGIC := '0';
    SIGNAL cam_data       : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
    SIGNAL frame_finished : STD_LOGIC;
    SIGNAL pixel_data     : STD_LOGIC_VECTOR(15 DOWNTO 0);
    SIGNAL wea            : STD_LOGIC_VECTOR(0 DOWNTO 0);
    SIGNAL dina           : STD_LOGIC_VECTOR(11 DOWNTO 0);
    SIGNAL addra          : STD_LOGIC_VECTOR(16 DOWNTO 0);
    SIGNAL writes         : INTEGER RANGE 0 TO 76800 := 0;
    SIGNAL done_count     : INTEGER RANGE 0 TO 2 := 0;
    SIGNAL verify_frame   : STD_LOGIC := '0';
BEGIN
    clk100 <= NOT clk100 AFTER 5 ns;

    dut: ENTITY work.ov7670_capture(rtl)
        PORT MAP(
            clk => clk100, rst => rst,
            config_finished => config_finished,
            ov7670_vsync => cam_vsync, ov7670_href => cam_href,
            ov7670_pclk => cam_pclk, ov7670_data => cam_data,
            start => start, frame_finished_o => frame_finished,
            pixel_data => pixel_data, wea => wea, dina => dina, addra => addra
        );

    -- Behavioral write port of BRAM: same camera PCLK clock as DUT.
    PROCESS(cam_pclk)
    BEGIN
        IF rising_edge(cam_pclk) THEN
            IF wea(0) = '1' THEN
                ASSERT verify_frame = '1'
                    REPORT "FAIL: Unexpected BRAM write before target frame" SEVERITY failure;
                ASSERT writes < 76800
                    REPORT "FAIL: More than 76800 writes" SEVERITY failure;
                ASSERT to_integer(unsigned(addra)) = writes
                    REPORT "FAIL: BRAM write address mismatch at pixel " & INTEGER'image(writes)
                    SEVERITY failure;
                ASSERT to_integer(unsigned(dina)) = (writes MOD 4096)
                    REPORT "FAIL: RGB444 data mismatch at pixel " & INTEGER'image(writes)
                    SEVERITY failure;
                writes <= writes + 1;
            END IF;
        END IF;
    END PROCESS;

    PROCESS(clk100)
    BEGIN
        IF rising_edge(clk100) THEN
            IF frame_finished = '1' THEN
                ASSERT done_count = 0
                    REPORT "FAIL: Multiple frame_finished pulses" SEVERITY failure;
                done_count <= done_count + 1;
                ASSERT writes = 76800
                    REPORT "FAIL: frame_finished before all 76800 BRAM writes" SEVERITY failure;
            END IF;
        END IF;
    END PROCESS;

    stimulus: PROCESS
        PROCEDURE send_byte (
            SIGNAL pclk_o: OUT STD_LOGIC;
            SIGNAL data_o: OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
            CONSTANT b   : IN  STD_LOGIC_VECTOR(7 DOWNTO 0)
        ) IS
        BEGIN
            data_o <= b;
            WAIT FOR 10 ns;
            pclk_o <= '1';
            WAIT FOR 20 ns;
            pclk_o <= '0';
            WAIT FOR 10 ns;
        END PROCEDURE;
        VARIABLE rgb : STD_LOGIC_VECTOR(11 DOWNTO 0);
    BEGIN
        WAIT FOR 100 ns;
        rst <= '0';
        WAIT FOR 40 ns;
        -- Configuration can be a short pulse in the 100 MHz domain.
        config_finished <= '1';
        WAIT FOR 10 ns;
        config_finished <= '0';
        WAIT FOR 40 ns;
        -- START is a 10 ns pulse while PCLK is stopped (HREF low).
        start <= '1';
        WAIT FOR 10 ns;
        start <= '0';
        WAIT FOR 60 ns;

        -- Prime start-toggle CDC. This incomplete frame MUST be skipped.
        cam_vsync <= '0';
        cam_href <= '1';
        FOR i IN 0 TO 5 LOOP
            send_byte(cam_pclk, cam_data, x"AB");
        END LOOP;
        cam_href <= '0';
        WAIT FOR 80 ns;

        -- Real target frame. PCLK remains LOW while VSYNC/HREF are inactive.
        cam_vsync <= '1';
        WAIT FOR 120 ns;
        cam_vsync <= '0';
        verify_frame <= '1';
        WAIT FOR 70 ns;
        FOR row IN 0 TO 239 LOOP
            cam_href <= '1';
            WAIT FOR 10 ns;
            FOR col IN 0 TO 319 LOOP
                rgb := STD_LOGIC_VECTOR(TO_UNSIGNED(((row * 320) + col) MOD 4096, 12));
                -- First byte: high nibble ignored, low nibble = R.
                send_byte(cam_pclk, cam_data, x"A" & rgb(11 DOWNTO 8));
                -- Second byte: G and B, must be written on THIS PCLK edge.
                send_byte(cam_pclk, cam_data, rgb(7 DOWNTO 0));
            END LOOP;
            cam_href <= '0';
            -- Horizontal blank: absolutely no PCLK edges here.
            WAIT FOR 80 ns;
        END LOOP;

        WAIT FOR 100 ns;
        ASSERT writes = 76800
            REPORT "FAIL: Expected 76800 writes, got " & INTEGER'image(writes)
            SEVERITY failure;
        ASSERT done_count = 1
            REPORT "FAIL: Expected exactly one frame_finished pulse" SEVERITY failure;
        ASSERT to_integer(unsigned(addra)) = 76799
            REPORT "FAIL: Final BRAM address must remain 76799" SEVERITY failure;

        REPORT "CAPTURE PASS: all 76800 RGB444 writes at addresses 0..76799" SEVERITY note;
        REPORT "PCLK-GATING PASS: last pixel written without another PCLK edge" SEVERITY note;
        REPORT "CDC PASS: 10 ns START pulse received after PCLK resumed" SEVERITY note;
        REPORT "DONE PASS: one frame_finished pulse in 100 MHz domain" SEVERITY note;
        REPORT "PASS: OV7670 PCLK capture test completed for Arty A7-35T" SEVERITY note;
        WAIT;
    END PROCESS;
END sim;
