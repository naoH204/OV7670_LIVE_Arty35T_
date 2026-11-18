LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE std.env.ALL;

ENTITY ov7670_capture_tb_CONTINUOUS_PCLK IS
END;

ARCHITECTURE sim OF ov7670_capture_tb_CONTINUOUS_PCLK IS
    SIGNAL clk100          : STD_LOGIC := '0';
    SIGNAL rst             : STD_LOGIC := '1';
    SIGNAL config_finished : STD_LOGIC := '0';
    SIGNAL start           : STD_LOGIC := '0';
    SIGNAL cam_vsync       : STD_LOGIC := '1';
    SIGNAL cam_href        : STD_LOGIC := '0';
    SIGNAL cam_pclk        : STD_LOGIC := '0';
    SIGNAL cam_data        : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
    SIGNAL frame_finished  : STD_LOGIC;
    SIGNAL pixel_data      : STD_LOGIC_VECTOR(15 DOWNTO 0);
    SIGNAL wea             : STD_LOGIC_VECTOR(0 DOWNTO 0);
    SIGNAL dina            : STD_LOGIC_VECTOR(11 DOWNTO 0);
    SIGNAL addra           : STD_LOGIC_VECTOR(16 DOWNTO 0);
    SIGNAL writes          : INTEGER := 0;
    SIGNAL done_count      : INTEGER := 0;
    SIGNAL target_frame    : STD_LOGIC := '0';
BEGIN
    clk100 <= NOT clk100 AFTER 5 ns;
    cam_pclk <= NOT cam_pclk AFTER 20 ns; -- continuous 25MHz for functional test

    dut : ENTITY work.ov7670_capture(rtl)
        PORT MAP (
            clk => clk100, rst => rst, config_finished => config_finished,
            ov7670_vsync => cam_vsync, ov7670_href => cam_href,
            ov7670_pclk => cam_pclk, ov7670_data => cam_data,
            start => start, frame_finished_o => frame_finished,
            pixel_data => pixel_data, wea => wea, dina => dina, addra => addra
        );

    PROCESS(cam_pclk)
    BEGIN
        IF rising_edge(cam_pclk) THEN
            IF wea(0) = '1' THEN
                ASSERT target_frame = '1' REPORT "FAIL: wrote outside requested target frame" SEVERITY failure;
                ASSERT writes < 76800 REPORT "FAIL: too many writes" SEVERITY failure;
                ASSERT to_integer(unsigned(addra)) = writes
                    REPORT "FAIL: address at pixel " & INTEGER'image(writes) SEVERITY failure;
                ASSERT to_integer(unsigned(dina)) = (writes MOD 4096)
                    REPORT "FAIL: RGB444 pixel value at " & INTEGER'image(writes) SEVERITY failure;
                writes <= writes + 1;
            END IF;
        END IF;
    END PROCESS;

    PROCESS(clk100)
    BEGIN
        IF rising_edge(clk100) THEN
            IF frame_finished = '1' THEN
                ASSERT done_count = 0 REPORT "FAIL: duplicate done pulse" SEVERITY failure;
                ASSERT writes = 76800 REPORT "FAIL: done before 76800 pixels" SEVERITY failure;
                done_count <= done_count + 1;
            END IF;
        END IF;
    END PROCESS;

    stimulus : PROCESS
        PROCEDURE send_byte(constant value : IN STD_LOGIC_VECTOR(7 DOWNTO 0)) IS
        BEGIN
            WAIT UNTIL falling_edge(cam_pclk);
            cam_data <= value;
            WAIT UNTIL rising_edge(cam_pclk);
            WAIT FOR 1 ns;
        END PROCEDURE;
        PROCEDURE sync_cam(constant n : IN POSITIVE) IS
        BEGIN
            FOR i IN 1 TO n LOOP
                WAIT UNTIL rising_edge(cam_pclk);
            END LOOP;
            WAIT FOR 1 ns;
        END PROCEDURE;
        VARIABLE rgb : STD_LOGIC_VECTOR(11 DOWNTO 0);
    BEGIN
        sync_cam(10);
        rst <= '0';
        sync_cam(10);
        config_finished <= '1';
        sync_cam(3);
        config_finished <= '0';

        -- Unarmed frame with HREF; it must be skipped.
        cam_vsync <= '1';
        sync_cam(5);
        cam_vsync <= '0';
        sync_cam(5);
        cam_href <= '1';
        FOR i IN 0 TO 7 LOOP
            send_byte(x"A5");
        END LOOP;
        cam_href <= '0';
        sync_cam(6);

        -- 10ns BTN pulse AFTER frame began. Must wait until next VSYNC.
        start <= '1';
        WAIT FOR 10 ns;
        start <= '0';
        sync_cam(10);
        cam_href <= '1';
        FOR i IN 0 TO 7 LOOP
            send_byte(x"EE");
        END LOOP;
        cam_href <= '0';
        sync_cam(6);
        ASSERT writes = 0 REPORT "FAIL: captured partial frame" SEVERITY failure;

        -- Fresh VSYNC after start -> accept exactly the next full frame.
        cam_vsync <= '1';
        sync_cam(6);
        cam_vsync <= '0';
        sync_cam(6);
        target_frame <= '1';
        FOR row IN 0 TO 239 LOOP
            cam_href <= '1';
            FOR col IN 0 TO 319 LOOP
                rgb := STD_LOGIC_VECTOR(TO_UNSIGNED(((row*320)+col) MOD 4096, 12));
                send_byte(x"A" & rgb(11 DOWNTO 8));
                send_byte(rgb(7 DOWNTO 0));
            END LOOP;
            cam_href <= '0';
            sync_cam(5);
        END LOOP;
        sync_cam(25);
        ASSERT writes = 76800 REPORT "FAIL: expected exactly 76800 BRAM writes" SEVERITY failure;
        ASSERT done_count = 1 REPORT "FAIL: expected one DONE pulse" SEVERITY failure;
        ASSERT to_integer(unsigned(addra)) = 76799
           REPORT "FAIL: address 76799 not preserved" SEVERITY failure;

        -- New free-running frame without new BTN3: no more writes.
        target_frame <= '0';
        cam_vsync <= '1';
        sync_cam(6);
        cam_vsync <= '0';
        sync_cam(5);
        cam_href <= '1';
        FOR i IN 0 TO 7 LOOP
            send_byte(x"AB");
        END LOOP;
        cam_href <= '0';
        sync_cam(10);
        ASSERT writes = 76800 REPORT "FAIL: repeated capture without BTN3" SEVERITY failure;
        ASSERT done_count = 1 REPORT "FAIL: duplicate DONE without BTN3" SEVERITY failure;
        REPORT "PASS: 76800 writes, RGB444, START CDC, single-frame, continuous PCLK" SEVERITY note;
        finish;
    END PROCESS;
END sim;
