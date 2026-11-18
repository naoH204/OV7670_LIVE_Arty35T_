--LIBRARY ieee;
--USE ieee.std_logic_1164.ALL;
--USE ieee.numeric_std.ALL;

---- Arty A7-35T / OV7670: single-frame QVGA RGB444 capture.
---- Requirement: COM10 register 0x15 = 0x00 -> PCLK runs during HBLANK/VSYNC.
---- PCLK and BRAM port A must be driven by the SAME buffered camera clock.
---- Port A write occurs on the rising PCLK edge carrying the second byte.
--ENTITY ov7670_capture IS
--    PORT (
--        clk              : IN  STD_LOGIC;
--        rst              : IN  STD_LOGIC;
--        config_finished  : IN  STD_LOGIC;
--        ov7670_vsync     : IN  STD_LOGIC;
--        ov7670_href      : IN  STD_LOGIC;
--        ov7670_pclk      : IN  STD_LOGIC;
--        ov7670_data      : IN  STD_LOGIC_VECTOR(7 DOWNTO 0);
--        start            : IN  STD_LOGIC;
--        frame_finished_o : OUT STD_LOGIC;
--        pixel_data       : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);
--        wea              : OUT STD_LOGIC_VECTOR(0 DOWNTO 0);
--        dina             : OUT STD_LOGIC_VECTOR(11 DOWNTO 0);
--        addra            : OUT STD_LOGIC_VECTOR(16 DOWNTO 0)
--    );
--END ov7670_capture;

--ARCHITECTURE rtl OF ov7670_capture IS
--    -- 100 MHz domain: capture one-cycle BTN3 and transfer as a toggle.
--    SIGNAL start_d, start_toggle_sys : STD_LOGIC := '0';
--    SIGNAL config_ready_sys : STD_LOGIC := '0';
--    SIGNAL done_meta, done_sync, done_prev : STD_LOGIC := '0';

--    -- Reset is async asserted to this two-flop reset synchronizer only;
--    -- all BRAM-facing camera state has synchronous reset in PCLK domain.
--    SIGNAL reset_meta, reset_pclk : STD_LOGIC := '1';
--    SIGNAL start_meta, start_sync, start_seen : STD_LOGIC := '0';
--    SIGNAL capture_armed : STD_LOGIC := '0';

--    SIGNAL frame_pending : STD_LOGIC := '1';
--    SIGNAL frame_active  : STD_LOGIC := '0';
--    SIGNAL row_index     : INTEGER RANGE 0 TO 239 := 0;
--    SIGNAL pixel_index   : INTEGER RANGE 0 TO 319 := 0;
--    SIGNAL write_address : UNSIGNED(16 DOWNTO 0) := (OTHERS => '0');
--    SIGNAL byte_phase, line_complete : STD_LOGIC := '0';
--    SIGNAL first_byte : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
--    SIGNAL rgb_debug  : STD_LOGIC_VECTOR(15 DOWNTO 0) := (OTHERS => '0');
--    SIGNAL done_toggle_pclk : STD_LOGIC := '0';
--    SIGNAL accept_byte, last_byte_valid : STD_LOGIC;

--    ATTRIBUTE ASYNC_REG : STRING;
--    ATTRIBUTE ASYNC_REG OF reset_meta : SIGNAL IS "TRUE";
--    ATTRIBUTE ASYNC_REG OF reset_pclk : SIGNAL IS "TRUE";
--    ATTRIBUTE ASYNC_REG OF start_meta : SIGNAL IS "TRUE";
--    ATTRIBUTE ASYNC_REG OF start_sync : SIGNAL IS "TRUE";
--    ATTRIBUTE ASYNC_REG OF done_meta  : SIGNAL IS "TRUE";
--    ATTRIBUTE ASYNC_REG OF done_sync  : SIGNAL IS "TRUE";
--BEGIN
--    addra <= STD_LOGIC_VECTOR(write_address);
--    dina <= first_byte(3 DOWNTO 0) & ov7670_data;
--    -- The BRAM samples WEA/DINA/ADDRA on the *current* second-byte PCLK edge.
--    accept_byte <= '1' WHEN ov7670_vsync = '0' AND ov7670_href = '1' AND
--                    line_complete = '0' AND
--                    (frame_active = '1' OR
--                     (frame_pending = '1' AND capture_armed = '1'))
--                   ELSE '0';
--    last_byte_valid <= accept_byte AND byte_phase;
--    wea(0) <= last_byte_valid;
--    pixel_data <= rgb_debug;
--    frame_finished_o <= done_sync XOR done_prev;

--    PROCESS(clk)
--    BEGIN
--        IF rising_edge(clk) THEN
--            IF rst = '1' THEN
--                start_d <= '0';
--                start_toggle_sys <= '0';
--                config_ready_sys <= '0';
--                done_meta <= '0';
--                done_sync <= '0';
--                done_prev <= '0';
--            ELSE
--                start_d <= start;
--                IF config_finished = '1' THEN
--                    config_ready_sys <= '1';
--                END IF;
--                IF start = '1' AND start_d = '0' AND
--                   (config_ready_sys = '1' OR config_finished = '1') THEN
--                    start_toggle_sys <= NOT start_toggle_sys;
--                END IF;
--                done_meta <= done_toggle_pclk;
--                done_sync <= done_meta;
--                done_prev <= done_sync;
--            END IF;
--        END IF;
--    END PROCESS;

--    PROCESS(ov7670_pclk, rst)
--    BEGIN
--        IF rst = '1' THEN
--            reset_meta <= '1';
--            reset_pclk <= '1';
--        ELSIF rising_edge(ov7670_pclk) THEN
--            reset_meta <= '0';
--            reset_pclk <= reset_meta;
--        END IF;
--    END PROCESS;

--    PROCESS(ov7670_pclk)
--    BEGIN
--        IF rising_edge(ov7670_pclk) THEN
--            IF reset_pclk = '1' THEN
--                start_meta <= '0';
--                start_sync <= '0';
--                start_seen <= '0';
--                capture_armed <= '0';
--                frame_pending <= '1';
--                frame_active <= '0';
--                row_index <= 0;
--                pixel_index <= 0;
--                write_address <= (OTHERS => '0');
--                byte_phase <= '0';
--                line_complete <= '0';
--                first_byte <= (OTHERS => '0');
--                done_toggle_pclk <= '0';
--                rgb_debug <= (OTHERS => '0');
--            ELSE
--                start_meta <= start_toggle_sys;
--                start_sync <= start_meta;
--                IF start_sync /= start_seen THEN
--                    start_seen <= start_sync;
--                    capture_armed <= '1';
--                END IF;

--                -- With COM10=0x00, PCLK remains available in VSYNC and HBLANK.
--                IF ov7670_vsync = '1' THEN
--                    frame_pending <= '1';
--                    frame_active <= '0';
--                    row_index <= 0;
--                    pixel_index <= 0;
--                    write_address <= (OTHERS => '0');
--                    byte_phase <= '0';
--                    line_complete <= '0';
--                ELSIF ov7670_href = '0' THEN
--                    -- Sync line reset instead of async reset on BRAM drivers.
--                    byte_phase <= '0';
--                    pixel_index <= 0;
--                    line_complete <= '0';
--                ELSIF frame_pending = '1' AND capture_armed = '0' THEN
--                    -- A frame already began before BTN3 was armed. Do not
--                    -- capture a partial frame; wait for the next VSYNC.
--                    frame_pending <= '0';
--                ELSIF accept_byte = '1' THEN
--                    IF frame_pending = '1' THEN
--                        frame_pending <= '0';
--                        frame_active <= '1';
--                        capture_armed <= '0'; -- exactly ONE frame per BTN3
--                    END IF;
--                    IF byte_phase = '0' THEN
--                        first_byte <= ov7670_data;
--                        byte_phase <= '1';
--                    ELSE
--                        byte_phase <= '0';
--                        rgb_debug <= first_byte & ov7670_data;
--                        IF pixel_index = 319 THEN
--                            line_complete <= '1';
--                            IF row_index = 239 THEN
--                                frame_active <= '0';
--                                done_toggle_pclk <= NOT done_toggle_pclk;
--                                -- Hold final address 76799 stable.
--                            ELSE
--                                row_index <= row_index + 1;
--                                write_address <= write_address + 1;
--                            END IF;
--                        ELSE
--                            pixel_index <= pixel_index + 1;
--                            write_address <= write_address + 1;
--                        END IF;
--                    END IF;
--                END IF;
--            END IF;
--        END IF;
--    END PROCESS;
--END rtl;
LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

-- Arty A7-35T / OV7670: automatic continuous QVGA RGB444 capture.
-- Requirement: COM10 register 0x15 = 0x00 -> PCLK runs during HBLANK/VSYNC.
-- PCLK and BRAM port A must be driven by the SAME buffered camera clock.
-- Port A write occurs on the rising PCLK edge carrying the second byte.
ENTITY ov7670_capture IS
    PORT (
        clk              : IN  STD_LOGIC;
        rst              : IN  STD_LOGIC;
        config_finished  : IN  STD_LOGIC;
        ov7670_vsync     : IN  STD_LOGIC;
        ov7670_href      : IN  STD_LOGIC;
        ov7670_pclk      : IN  STD_LOGIC;
        ov7670_data      : IN  STD_LOGIC_VECTOR(7 DOWNTO 0);
        start            : IN  STD_LOGIC; -- legacy, unused in live mode
        frame_finished_o : OUT STD_LOGIC;
        pixel_data       : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);
        wea              : OUT STD_LOGIC_VECTOR(0 DOWNTO 0);
        dina             : OUT STD_LOGIC_VECTOR(11 DOWNTO 0);
        addra            : OUT STD_LOGIC_VECTOR(16 DOWNTO 0)
    );
END ov7670_capture;

ARCHITECTURE rtl OF ov7670_capture IS
    -- 100 MHz domain: latch SCCB configuration finished.
    -- The start input is kept only for interface compatibility with top v1.1.
    -- Video capture runs automatically; BTN3 is no longer required.
    SIGNAL config_ready_sys : STD_LOGIC := '0';
    SIGNAL done_meta, done_sync, done_prev : STD_LOGIC := '0';

    -- Reset is async asserted to this two-flop reset synchronizer only;
    -- all BRAM-facing camera state has synchronous reset in PCLK domain.
    SIGNAL reset_meta, reset_pclk : STD_LOGIC := '1';
    SIGNAL config_meta, config_sync : STD_LOGIC := '0';

    SIGNAL frame_pending : STD_LOGIC := '1';
    SIGNAL frame_active  : STD_LOGIC := '0';
    SIGNAL row_index     : INTEGER RANGE 0 TO 239 := 0;
    SIGNAL pixel_index   : INTEGER RANGE 0 TO 319 := 0;
    SIGNAL write_address : UNSIGNED(16 DOWNTO 0) := (OTHERS => '0');
    SIGNAL byte_phase, line_complete : STD_LOGIC := '0';
    SIGNAL first_byte : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
    SIGNAL rgb_debug  : STD_LOGIC_VECTOR(15 DOWNTO 0) := (OTHERS => '0');
    SIGNAL done_toggle_pclk : STD_LOGIC := '0';
    SIGNAL accept_byte, last_byte_valid : STD_LOGIC;

    ATTRIBUTE ASYNC_REG : STRING;
    ATTRIBUTE ASYNC_REG OF reset_meta : SIGNAL IS "TRUE";
    ATTRIBUTE ASYNC_REG OF reset_pclk : SIGNAL IS "TRUE";
    ATTRIBUTE ASYNC_REG OF config_meta : SIGNAL IS "TRUE";
    ATTRIBUTE ASYNC_REG OF config_sync : SIGNAL IS "TRUE";
    ATTRIBUTE ASYNC_REG OF done_meta  : SIGNAL IS "TRUE";
    ATTRIBUTE ASYNC_REG OF done_sync  : SIGNAL IS "TRUE";
BEGIN
    addra <= STD_LOGIC_VECTOR(write_address);
    dina <= first_byte(3 DOWNTO 0) & ov7670_data;
    -- The BRAM samples WEA/DINA/ADDRA on the *current* second-byte PCLK edge.
    accept_byte <= '1' WHEN ov7670_vsync = '0' AND ov7670_href = '1' AND
                    line_complete = '0' AND
                    (frame_active = '1' OR
                     (frame_pending = '1' AND config_sync = '1'))
                   ELSE '0';
    last_byte_valid <= accept_byte AND byte_phase;
    wea(0) <= last_byte_valid;
    pixel_data <= rgb_debug;
    frame_finished_o <= done_sync XOR done_prev;

    PROCESS(clk)
    BEGIN
        IF rising_edge(clk) THEN
            IF rst = '1' THEN
                config_ready_sys <= '0';
                done_meta <= '0';
                done_sync <= '0';
                done_prev <= '0';
            ELSE
                IF config_finished = '1' THEN
                    config_ready_sys <= '1';
                END IF;
                done_meta <= done_toggle_pclk;
                done_sync <= done_meta;
                done_prev <= done_sync;
            END IF;
        END IF;
    END PROCESS;

    PROCESS(ov7670_pclk, rst)
    BEGIN
        IF rst = '1' THEN
            reset_meta <= '1';
            reset_pclk <= '1';
        ELSIF rising_edge(ov7670_pclk) THEN
            reset_meta <= '0';
            reset_pclk <= reset_meta;
        END IF;
    END PROCESS;

    PROCESS(ov7670_pclk)
    BEGIN
        IF rising_edge(ov7670_pclk) THEN
            IF reset_pclk = '1' THEN
                config_meta <= '0';
                config_sync <= '0';
                frame_pending <= '1';
                frame_active <= '0';
                row_index <= 0;
                pixel_index <= 0;
                write_address <= (OTHERS => '0');
                byte_phase <= '0';
                line_complete <= '0';
                first_byte <= (OTHERS => '0');
                done_toggle_pclk <= '0';
                rgb_debug <= (OTHERS => '0');
            ELSE
                -- 2-FF CDC: SCCB config_done (100 MHz) -> camera PCLK.
                config_meta <= config_ready_sys;
                config_sync <= config_meta;

                -- With COM10=0x00, PCLK remains available in VSYNC and HBLANK.
                IF ov7670_vsync = '1' THEN
                    frame_pending <= '1';
                    frame_active <= '0';
                    row_index <= 0;
                    pixel_index <= 0;
                    write_address <= (OTHERS => '0');
                    byte_phase <= '0';
                    line_complete <= '0';
                ELSIF ov7670_href = '0' THEN
                    -- Sync line reset instead of async reset on BRAM drivers.
                    byte_phase <= '0';
                    pixel_index <= 0;
                    line_complete <= '0';
                ELSIF frame_pending = '1' AND config_sync = '0' THEN
                    -- Config still incomplete: skip this entire frame.
                    -- Wait for a fresh VSYNC after SCCB is ready.
                    frame_pending <= '0';
                ELSIF accept_byte = '1' THEN
                    IF frame_pending = '1' THEN
                        frame_pending <= '0';
                        frame_active <= '1';
                        -- Keep capturing subsequent frames automatically.
                    END IF;
                    IF byte_phase = '0' THEN
                        first_byte <= ov7670_data;
                        byte_phase <= '1';
                    ELSE
                        byte_phase <= '0';
                        rgb_debug <= first_byte & ov7670_data;
                        IF pixel_index = 319 THEN
                            line_complete <= '1';
                            IF row_index = 239 THEN
                                frame_active <= '0';
                                done_toggle_pclk <= NOT done_toggle_pclk;
                                -- Hold final address 76799 stable.
                            ELSE
                                row_index <= row_index + 1;
                                write_address <= write_address + 1;
                            END IF;
                        ELSE
                            pixel_index <= pixel_index + 1;
                            write_address <= write_address + 1;
                        END IF;
                    END IF;
                END IF;
            END IF;
        END IF;
    END PROCESS;
END rtl;
