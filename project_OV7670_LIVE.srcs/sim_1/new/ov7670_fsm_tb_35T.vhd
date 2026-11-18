-- Testbench for the real OV7670 FSM/ROM used in the Arty A7-35T project.
-- Stimulates the FSM-side i2c_busy handshake (NOT the physical SDA/SCL bus).
-- Compile as VHDL-2008. Compile common_pkg.vhd and OV7670_fsm_35T_fixed.vhd first.
LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE std.env.ALL;
USE work.common_pkg.ALL;

ENTITY ov7670_fsm_tb IS
END ENTITY;

ARCHITECTURE sim OF ov7670_fsm_tb IS
    CONSTANT CLK_PERIOD : TIME := 10 ns;
    CONSTANT N_REGS : INTEGER := register_config_rom'length;

    SIGNAL clk : STD_LOGIC := '0';
    SIGNAL rst : STD_LOGIC := '1';
    SIGNAL start : STD_LOGIC := '0';
    SIGNAL i2c_busy : STD_LOGIC := '0';
    SIGNAL i2c_rdata : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
    SIGNAL i2c_addr : STD_LOGIC_VECTOR(6 DOWNTO 0);
    SIGNAL i2c_wdata : STD_LOGIC_VECTOR(7 DOWNTO 0);
    SIGNAL i2c_ena, i2c_rw, ov7670_reset : STD_LOGIC;
    SIGNAL reg_value : STD_LOGIC_VECTOR(7 DOWNTO 0);
    SIGNAL config_finished, done : STD_LOGIC;

    SIGNAL done_count : INTEGER := 0;
    SIGNAL config_rise_count : INTEGER := 0;
    SIGNAL expected_read_index : INTEGER RANGE 0 TO N_REGS-1 := 0;
    SIGNAL saw_camera_reset_low : BOOLEAN := FALSE;

    FUNCTION test_read_data(i : INTEGER) RETURN STD_LOGIC_VECTOR IS
    BEGIN
        RETURN STD_LOGIC_VECTOR(TO_UNSIGNED((17*i + 83) MOD 256, 8));
    END FUNCTION;
BEGIN
    clk <= NOT clk AFTER CLK_PERIOD / 2;

    DUT : ENTITY work.ov7670_fsm(rtl)
        GENERIC MAP(
            -- Simulation ONLY: reduce long real-world delays to a few cycles.
            -- The generic defaults in the RTL retain 600ms/1ms/1us for hardware.
            G_CLK_CNT_600MS => 20,
            G_CLK_CNT_1MS   => 7,
            G_CLK_CNT_1US   => 3
        )
        PORT MAP(
            clk => clk,
            rst => rst,
            start => start,
            i2c_busy => i2c_busy,
            i2c_rdata => i2c_rdata,
            i2c_addr => i2c_addr,
            i2c_wdata => i2c_wdata,
            i2c_ena => i2c_ena,
            i2c_rw => i2c_rw,
            ov7670_reset => ov7670_reset,
            reg_value => reg_value,
            config_finished => config_finished,
            done => done
        );

    RESET_MONITOR : PROCESS(ov7670_reset)
    BEGIN
        IF ov7670_reset = '0' THEN
            saw_camera_reset_low <= TRUE;
        END IF;
    END PROCESS;

    CONFIG_MONITOR : PROCESS(config_finished)
    BEGIN
        IF rising_edge(config_finished) THEN
            config_rise_count <= config_rise_count + 1;
        END IF;
    END PROCESS;

    DONE_MONITOR : PROCESS(done)
    BEGIN
        IF rising_edge(done) THEN
            ASSERT config_finished = '1'
                REPORT "FSM FAIL: done rose before config_finished" SEVERITY FAILURE;
            ASSERT reg_value = test_read_data(expected_read_index)
                REPORT "FSM FAIL: wrong readback data at index " &
                       INTEGER'IMAGE(expected_read_index) SEVERITY FAILURE;
            done_count <= done_count + 1;
        END IF;
    END PROCESS;

    STIMULUS : PROCESS
        VARIABLE saw_com7, saw_com3, saw_rgb444 : BOOLEAN := FALSE;

        PROCEDURE wait_cycles(n : POSITIVE) IS
        BEGIN
            FOR k IN 1 TO n LOOP
                WAIT UNTIL rising_edge(clk);
            END LOOP;
            WAIT FOR 1 ns;
        END PROCEDURE;

        PROCEDURE wait_for_enable IS
            VARIABLE tries : INTEGER := 0;
        BEGIN
            WHILE i2c_ena /= '1' LOOP
                wait_cycles(1);
                tries := tries + 1;
                ASSERT tries < 10000
                    REPORT "FSM FAIL: timeout waiting for i2c_ena" SEVERITY FAILURE;
            END LOOP;
            WAIT FOR 1 ns;
        END PROCEDURE;

        PROCEDURE wait_for_config IS
            VARIABLE tries : INTEGER := 0;
        BEGIN
            WHILE config_finished /= '1' LOOP
                wait_cycles(1);
                tries := tries + 1;
                ASSERT tries < 10000
                    REPORT "FSM FAIL: timeout waiting for config_finished" SEVERITY FAILURE;
            END LOOP;
        END PROCEDURE;

        PROCEDURE busy_pulse IS
        BEGIN
            WAIT UNTIL falling_edge(clk);
            i2c_busy <= '1';
            wait_cycles(4);
            WAIT UNTIL falling_edge(clk);
            i2c_busy <= '0';
            wait_cycles(4);
        END PROCEDURE;
    BEGIN
        ASSERT N_REGS = 78
            REPORT "ROM SIZE FAIL: this test expects 78 configuration entries"
            SEVERITY FAILURE;

        -- Keep reset asserted for several system clocks, then release it.
        wait_cycles(6);
        WAIT UNTIL falling_edge(clk);
        rst <= '0';

        -- Write all 78 address/value pairs using the same busy sequencing as
        -- the I2C master: two busy assertions per register transaction.
        FOR i IN register_config_rom'RANGE LOOP
            wait_for_enable;
            ASSERT config_finished = '0'
                REPORT "FSM FAIL: config_finished asserted before last write" SEVERITY FAILURE;
            ASSERT i2c_addr = "0100001" AND i2c_rw = '0'
                REPORT "FSM FAIL: wrong camera address or write direction"
                SEVERITY FAILURE;
            ASSERT i2c_wdata = register_config_rom(i)(15 DOWNTO 8)
                REPORT "FSM WRITE FAIL: register address at ROM index " & INTEGER'IMAGE(i)
                SEVERITY FAILURE;

            IF register_config_rom(i) = x"1214" THEN saw_com7 := TRUE; END IF;
            IF register_config_rom(i) = x"0C08" THEN saw_com3 := TRUE; END IF;
            IF register_config_rom(i) = x"8C02" THEN saw_rgb444 := TRUE; END IF;

            busy_pulse;
            ASSERT i2c_ena = '1' AND i2c_rw = '0'
                REPORT "FSM WRITE FAIL: transaction stopped before value byte at " &
                       INTEGER'IMAGE(i) SEVERITY FAILURE;
            ASSERT i2c_wdata = register_config_rom(i)(7 DOWNTO 0)
                REPORT "FSM WRITE FAIL: register value at ROM index " & INTEGER'IMAGE(i)
                SEVERITY FAILURE;

            busy_pulse;
            ASSERT i2c_ena = '0'
                REPORT "FSM WRITE FAIL: enable stayed high after ROM index " &
                       INTEGER'IMAGE(i) SEVERITY FAILURE;
        END LOOP;

        wait_for_config;
        ASSERT saw_camera_reset_low
            REPORT "RESET FAIL: OV7670 active-low reset never asserted" SEVERITY FAILURE;
        ASSERT saw_com7 AND saw_com3 AND saw_rgb444
            REPORT "ROM CONTENT FAIL: COM7=0x14, COM3=0x08 or RGB444=0x02 absent"
            SEVERITY FAILURE;
        ASSERT config_rise_count = 1
            REPORT "FSM FAIL: config_finished did not rise exactly once" SEVERITY FAILURE;
        REPORT "WRITE PASS: all 78 register/value pairs transmitted in ROM order" SEVERITY NOTE;
        REPORT "ROM PASS: COM7=0x14, COM3=0x08 and RGB444=0x02 present" SEVERITY NOTE;
        REPORT "CONFIG PASS: config_finished asserted after the last write" SEVERITY NOTE;

        -- The original FSM subsequently reads 78 registers back. A fake I2C
        -- master supplies deterministic bytes and checks that done/reg_value
        -- are presented in the corresponding order. This is NOT a real camera.
        FOR i IN register_config_rom'RANGE LOOP
            -- Write the register index whose contents will be read.
            wait_for_enable;
            ASSERT i2c_rw = '0' AND i2c_wdata = register_config_rom(i)(15 DOWNTO 8)
                REPORT "FSM READ FAIL: read-address setup at index " & INTEGER'IMAGE(i)
                SEVERITY FAILURE;
            busy_pulse;
            ASSERT i2c_ena = '0'
                REPORT "FSM READ FAIL: read-address command not released" SEVERITY FAILURE;

            -- Perform the read, and make a synthetic byte available before busy falls.
            wait_for_enable;
            ASSERT i2c_rw = '1' AND i2c_addr = "0100001"
                REPORT "FSM READ FAIL: wrong read direction/address" SEVERITY FAILURE;
            expected_read_index <= i;
            i2c_rdata <= test_read_data(i);
            WAIT FOR 1 ns;
            busy_pulse;
            ASSERT i2c_ena = '0'
                REPORT "FSM READ FAIL: enable stayed high after read" SEVERITY FAILURE;
        END LOOP;

        wait_cycles(10);
        ASSERT done_count = N_REGS
            REPORT "FSM FAIL: expected " & INTEGER'IMAGE(N_REGS) &
                   " done pulses; received " & INTEGER'IMAGE(done_count)
            SEVERITY FAILURE;
        ASSERT config_finished = '1'
            REPORT "FSM FAIL: config_finished unexpectedly deasserted" SEVERITY FAILURE;
        REPORT "READ PASS: 78 read-address transactions and 78 done pulses checked" SEVERITY NOTE;
        REPORT "PASS: ov7670_fsm_tb for Arty A7-35T completed" SEVERITY NOTE;
        finish;
        WAIT;
    END PROCESS;

    WATCHDOG : PROCESS
    BEGIN
        WAIT FOR 2 ms;
        ASSERT FALSE REPORT "FSM FAIL: simulation timeout (2 ms)" SEVERITY FAILURE;
        WAIT;
    END PROCESS;
END ARCHITECTURE;
