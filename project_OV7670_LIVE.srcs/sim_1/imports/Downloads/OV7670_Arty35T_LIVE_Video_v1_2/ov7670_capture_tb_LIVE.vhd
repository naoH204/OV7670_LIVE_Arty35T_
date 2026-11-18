LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE std.env.ALL;

-- Tests auto-capture across two complete QVGA frames, with NO BTN3 pulse.
-- The real blk_mem_gen_1 and VGA blocks are unchanged from v1.1.
ENTITY ov7670_capture_tb_LIVE IS
END ENTITY;

ARCHITECTURE sim OF ov7670_capture_tb_LIVE IS
    CONSTANT W : INTEGER := 320;
    CONSTANT H : INTEGER := 240;
    CONSTANT NP : INTEGER := W * H;

    SIGNAL clk100 : STD_LOGIC := '0';
    SIGNAL cam_pclk : STD_LOGIC := '0';
    SIGNAL rst : STD_LOGIC := '1';
    SIGNAL config_finished : STD_LOGIC := '0';
    SIGNAL cam_vsync : STD_LOGIC := '1';
    SIGNAL cam_href : STD_LOGIC := '0';
    SIGNAL cam_data : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
    SIGNAL start : STD_LOGIC := '0'; -- NEVER asserted
    SIGNAL frame_finished : STD_LOGIC;
    SIGNAL wea : STD_LOGIC_VECTOR(0 DOWNTO 0);
    SIGNAL dina : STD_LOGIC_VECTOR(11 DOWNTO 0);
    SIGNAL addra : STD_LOGIC_VECTOR(16 DOWNTO 0);
    SIGNAL writes : INTEGER RANGE 0 TO NP*2 + 1 := 0;
    SIGNAL done_count : INTEGER RANGE 0 TO 3 := 0;
    SIGNAL input_frame : INTEGER RANGE 0 TO 2 := 0;

    FUNCTION rgb_value(frame_id : INTEGER; pixel_id : INTEGER)
        RETURN STD_LOGIC_VECTOR IS
    BEGIN
        RETURN STD_LOGIC_VECTOR(TO_UNSIGNED((frame_id * 911 + pixel_id * 73) MOD 4096, 12));
    END FUNCTION;
BEGIN
    clk100 <= NOT clk100 AFTER 5 ns;
    cam_pclk <= NOT cam_pclk AFTER 20 ns; -- continuous 25 MHz

    DUT : ENTITY work.ov7670_capture(rtl)
        PORT MAP (
            clk => clk100,
            rst => rst,
            config_finished => config_finished,
            ov7670_vsync => cam_vsync,
            ov7670_href => cam_href,
            ov7670_pclk => cam_pclk,
            ov7670_data => cam_data,
            start => start,
            frame_finished_o => frame_finished,
            pixel_data => OPEN,
            wea => wea,
            dina => dina,
            addra => addra
        );

    -- Same edge that samples WEA/ADDR/DATA into Port A of BRAM.
    MONITOR_WRITES : PROCESS(cam_pclk)
        VARIABLE global_pixel : INTEGER;
        VARIABLE expected_frame : INTEGER;
        VARIABLE local_pixel : INTEGER;
    BEGIN
        IF rising_edge(cam_pclk) THEN
            IF wea(0) = '1' THEN
                global_pixel := writes;
                expected_frame := (global_pixel / NP) + 1;
                local_pixel := global_pixel MOD NP;
                ASSERT expected_frame <= 2
                    REPORT "FAIL: unexpected third-frame write" SEVERITY failure;
                ASSERT input_frame = expected_frame
                    REPORT "FAIL: write outside target frame" SEVERITY failure;
                ASSERT to_integer(unsigned(addra)) = local_pixel
                    REPORT "FAIL: BRAM address error at global pixel " & INTEGER'image(global_pixel)
                    SEVERITY failure;
                ASSERT dina = rgb_value(expected_frame, local_pixel)
                    REPORT "FAIL: RGB444 mismatch at global pixel " & INTEGER'image(global_pixel)
                    SEVERITY failure;
                writes <= writes + 1;
            END IF;
        END IF;
    END PROCESS;

    MONITOR_DONE : PROCESS(clk100)
    BEGIN
        IF rising_edge(clk100) THEN
            IF frame_finished = '1' THEN
                ASSERT done_count < 2
                    REPORT "FAIL: unexpected extra frame_finished" SEVERITY failure;
                ASSERT writes = (done_count + 1) * NP
                    REPORT "FAIL: frame_finished without a complete frame" SEVERITY failure;
                done_count <= done_count + 1;
            END IF;
        END IF;
    END PROCESS;

    STIMULUS : PROCESS
        PROCEDURE sync_cam(constant cycles : IN POSITIVE) IS
        BEGIN
            FOR i IN 1 TO cycles LOOP
                WAIT UNTIL rising_edge(cam_pclk);
            END LOOP;
            WAIT FOR 1 ns;
        END PROCEDURE;
        PROCEDURE send_byte(constant val : IN STD_LOGIC_VECTOR(7 DOWNTO 0)) IS
        BEGIN
            WAIT UNTIL falling_edge(cam_pclk);
            cam_data <= val;
            WAIT UNTIL rising_edge(cam_pclk);
            WAIT FOR 1 ns;
        END PROCEDURE;
        VARIABLE rgb : STD_LOGIC_VECTOR(11 DOWNTO 0);
    BEGIN
        sync_cam(10);
        rst <= '0';
        sync_cam(15);

        -- Video before SCCB completes must NOT be written to BRAM.
        cam_vsync <= '1';
        sync_cam(6);
        cam_vsync <= '0';
        sync_cam(6);
        cam_href <= '1';
        FOR i IN 0 TO 7 LOOP
            send_byte(x"A5");
        END LOOP;
        cam_href <= '0';
        sync_cam(12);
        ASSERT writes = 0 REPORT "FAIL: wrote before config_finished" SEVERITY failure;

        config_finished <= '1';
        sync_cam(3);
        config_finished <= '0';
        sync_cam(15); -- allow sys100 -> camera PCLK CDC to settle

        -- Two full frames with different pixel patterns.
        -- No start/BTN3 event at any point in this test.
        FOR frame_id IN 1 TO 2 LOOP
            cam_vsync <= '1';
            sync_cam(8);
            cam_vsync <= '0';
            input_frame <= frame_id;
            sync_cam(8);
            FOR row IN 0 TO H-1 LOOP
                cam_href <= '1';
                FOR col IN 0 TO W-1 LOOP
                    rgb := rgb_value(frame_id, row*W + col);
                    send_byte(x"A" & rgb(11 DOWNTO 8));
                    send_byte(rgb(7 DOWNTO 0));
                END LOOP;
                cam_href <= '0';
                sync_cam(5);
            END LOOP;
            sync_cam(25);
            ASSERT writes = frame_id * NP
                REPORT "FAIL: number of writes for frame " & INTEGER'image(frame_id)
                SEVERITY failure;
            ASSERT done_count = frame_id
                REPORT "FAIL: frame_finished count for frame " & INTEGER'image(frame_id)
                SEVERITY failure;
            ASSERT to_integer(unsigned(addra)) = NP - 1
                REPORT "FAIL: final frame address should be 76799" SEVERITY failure;
        END LOOP;

        -- No VSYNC means no additional capture after the final row.
        sync_cam(50);
        ASSERT writes = 2*NP REPORT "FAIL: wrote beyond two complete frames" SEVERITY failure;
        ASSERT done_count = 2 REPORT "FAIL: expected two done pulses" SEVERITY failure;
        ASSERT start = '0' REPORT "FAIL: BTN3 was unexpectedly used" SEVERITY failure;
        REPORT "PASS: LIVE two frames, 153600 writes, RGB444, address wrap, no BTN3" SEVERITY note;
        finish;
    END PROCESS;

    WATCHDOG : PROCESS
    BEGIN
        WAIT FOR 20 ms;
        ASSERT false REPORT "FAIL: LIVE capture test timeout" SEVERITY failure;
        WAIT;
    END PROCESS;
END ARCHITECTURE;
