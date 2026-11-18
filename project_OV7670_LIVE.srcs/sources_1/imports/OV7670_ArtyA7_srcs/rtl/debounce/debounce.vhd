LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

-- 4 independent debounced pushbuttons, active-high Arty A7 BTN[3:0].
-- At 100MHz, 1_000_000 samples = 10ms. One-cycle pulse on PRESS.
ENTITY debounce IS
    PORT (
        clk  : IN STD_LOGIC;
        btn  : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
        edge : OUT STD_LOGIC_VECTOR(3 DOWNTO 0)
    );
END debounce;

ARCHITECTURE Behavioral OF debounce IS
    CONSTANT C_STABLE_CYCLES : NATURAL := 1_000_000;
    TYPE counter_array IS ARRAY(0 TO 3) OF UNSIGNED(19 DOWNTO 0);
    SIGNAL counters : counter_array := (OTHERS => (OTHERS => '0'));
    SIGNAL btn_meta, btn_sync : STD_LOGIC_VECTOR(3 DOWNTO 0) := (OTHERS => '0');
    SIGNAL btn_stable : STD_LOGIC_VECTOR(3 DOWNTO 0) := (OTHERS => '0');
    SIGNAL edge_reg   : STD_LOGIC_VECTOR(3 DOWNTO 0) := (OTHERS => '0');
    ATTRIBUTE ASYNC_REG : STRING;
    ATTRIBUTE ASYNC_REG OF btn_meta : SIGNAL IS "TRUE";
    ATTRIBUTE ASYNC_REG OF btn_sync : SIGNAL IS "TRUE";
BEGIN
    edge <= edge_reg;
    PROCESS(clk)
    BEGIN
        IF rising_edge(clk) THEN
            btn_meta <= btn;
            btn_sync <= btn_meta;
            edge_reg <= (OTHERS => '0');
            FOR i IN 0 TO 3 LOOP
                IF btn_sync(i) = btn_stable(i) THEN
                    counters(i) <= (OTHERS => '0');
                ELSIF counters(i) = TO_UNSIGNED(C_STABLE_CYCLES - 1, 20) THEN
                    btn_stable(i) <= btn_sync(i);
                    counters(i) <= (OTHERS => '0');
                    IF btn_sync(i) = '1' THEN
                        edge_reg(i) <= '1';
                    END IF;
                ELSE
                    counters(i) <= counters(i) + 1;
                END IF;
            END LOOP;
        END IF;
    END PROCESS;
END Behavioral;
