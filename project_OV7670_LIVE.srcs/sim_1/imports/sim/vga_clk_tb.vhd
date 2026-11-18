--LIBRARY ieee;
--USE ieee.std_logic_1164.ALL;
--USE ieee.numeric_std.ALL;

--USE std.textio.ALL;
--USE std.env.finish;

--ENTITY vga_clk_tb IS
--END vga_clk_tb;

--ARCHITECTURE sim OF vga_clk_tb IS

--    CONSTANT clk_hz : INTEGER := 100e6;
--    CONSTANT clk_period : TIME := 1 sec / clk_hz;

--    SIGNAL clk : STD_LOGIC := '1';
--    SIGNAL rst : STD_LOGIC := '1';

--    SIGNAL locked : STD_LOGIC := '0';

--    COMPONENT vga_clk_gen IS
--        PORT (
--            clk_in1 : IN STD_LOGIC;
--            reset : IN STD_LOGIC;
--            clk_out1 : OUT STD_LOGIC;
--            locked : OUT STD_LOGIC
--        );
--    END COMPONENT;

--    SIGNAL vga_clk : STD_LOGIC := '0';
--    SIGNAL vga_cnt, vga_next : INTEGER RANGE 0 TO 100 := 0;

--BEGIN

--    clk <= NOT clk AFTER clk_period / 2;

--    DUT : vga_clk_gen
--    PORT MAP(
--        clk_in1 => clk,
--        reset => '1',
--        clk_out1 => vga_clk,
--        locked => locked
--    );

--    SEQUENCER_PROC : PROCESS
--    BEGIN
--        WAIT FOR clk_period * 2;

--        rst <= '0';

--        WAIT FOR clk_period * 500;
--    END PROCESS;

--END ARCHITECTURE;


-- Testbench VGA Clock Wizard: Arty A7-35T / Vivado 2022.2
-- vga_clk_gen.xci: 100 MHz input; requested 25.175 MHz,
-- generated frequency 25.17301 MHz (period about 39.725 ns).
-- Compile as VHDL 2008; use the generated vga_clk_gen simulation model.
LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE std.env.ALL;

ENTITY vga_clk_tb IS
END ENTITY;

ARCHITECTURE sim OF vga_clk_tb IS
    CONSTANT SYS_PERIOD : TIME := 10 ns;
    CONSTANT VGA_PERIOD_MIN : TIME := 39 ns;
    CONSTANT VGA_PERIOD_MAX : TIME := 41 ns;
    CONSTANT LOCK_TIMEOUT : TIME := 1 ms;
    CONSTANT EDGE_TIMEOUT : TIME := 200 ns;
    CONSTANT SAMPLE_EDGES : POSITIVE := 64;

    COMPONENT vga_clk_gen IS
        PORT (
            clk_in1 : IN STD_LOGIC;
            reset : IN STD_LOGIC;
            clk_out1 : OUT STD_LOGIC;
            locked : OUT STD_LOGIC
        );
    END COMPONENT;

    SIGNAL clk : STD_LOGIC := '0';
    SIGNAL rst : STD_LOGIC := '1';
    SIGNAL locked : STD_LOGIC := '0';
    SIGNAL vga_clk : STD_LOGIC := '0';
BEGIN
    clk <= NOT clk AFTER SYS_PERIOD / 2;

    DUT : vga_clk_gen
        PORT MAP (
            clk_in1 => clk,
            reset   => rst,    -- Important: NOT a constant '1'!
            clk_out1 => vga_clk,
            locked  => locked
        );

    STIMULUS : PROCESS
        VARIABLE t0, t1 : TIME;
        VARIABLE period_meas : TIME;
    BEGIN
        WAIT FOR 200 ns;
        rst <= '0';

        WAIT UNTIL locked = '1' FOR LOCK_TIMEOUT;
        ASSERT locked = '1'
            REPORT "LOCK FAIL: vga_clk_gen did not assert locked after reset release"
            SEVERITY FAILURE;
        REPORT "LOCK PASS: VGA Clock Wizard asserted locked" SEVERITY NOTE;

        -- Wait for a clean rising edge after lock and verify each period.
        WAIT UNTIL rising_edge(vga_clk) FOR EDGE_TIMEOUT;
        ASSERT vga_clk = '1'
            REPORT "CLOCK FAIL: no rising edge on VGA clock after lock"
            SEVERITY FAILURE;
        t0 := NOW;

        FOR i IN 1 TO SAMPLE_EDGES LOOP
            WAIT UNTIL rising_edge(vga_clk) FOR EDGE_TIMEOUT;
            ASSERT vga_clk = '1'
                REPORT "CLOCK FAIL: VGA clock stopped at sample " & INTEGER'IMAGE(i)
                SEVERITY FAILURE;
            t1 := NOW;
            period_meas := t1 - t0;
            ASSERT period_meas >= VGA_PERIOD_MIN AND period_meas <= VGA_PERIOD_MAX
                REPORT "CLOCK FAIL: unexpected VGA period at sample " & INTEGER'IMAGE(i) &
                       "; measured " & TIME'IMAGE(period_meas)
                SEVERITY FAILURE;
            t0 := t1;
        END LOOP;
        REPORT "CLOCK PASS: 64 VGA periods in 39..41 ns range (approximately 25.173 MHz)"
            SEVERITY NOTE;

        -- Reassert reset and check that lock drops.
        rst <= '1';
        WAIT UNTIL locked = '0' FOR 200 ns;
        ASSERT locked = '0'
            REPORT "RESET FAIL: locked did not deassert when reset was asserted"
            SEVERITY FAILURE;
        REPORT "RESET PASS: locked deasserted" SEVERITY NOTE;

        WAIT FOR 200 ns;
        rst <= '0';
        WAIT UNTIL locked = '1' FOR LOCK_TIMEOUT;
        ASSERT locked = '1'
            REPORT "RELOCK FAIL: locked did not reassert after second reset"
            SEVERITY FAILURE;
        REPORT "RELOCK PASS: VGA Clock Wizard locked again" SEVERITY NOTE;

        REPORT "PASS: vga_clk_tb for Arty A7-35T completed" SEVERITY NOTE;
        FINISH;
    END PROCESS;
END ARCHITECTURE;
