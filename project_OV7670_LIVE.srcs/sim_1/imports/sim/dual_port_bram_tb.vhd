--LIBRARY ieee;
--USE ieee.std_logic_1164.ALL;
--USE ieee.numeric_std.ALL;

--USE std.textio.ALL;
--USE std.env.finish;

--ENTITY dual_port_bram_tb IS
--END dual_port_bram_tb;

--ARCHITECTURE sim OF dual_port_bram_tb IS

--    CONSTANT clk_hz : INTEGER := 100e6;
--    CONSTANT clk_period : TIME := 1 sec / clk_hz;

--    SIGNAL clk, clkb : STD_LOGIC := '1';
--    SIGNAL rst : STD_LOGIC := '1';

--    COMPONENT blk_mem_gen_1 IS
--        PORT (
--            clka : IN STD_LOGIC;
--            ena : IN STD_LOGIC;
--            wea : IN STD_LOGIC_VECTOR(0 DOWNTO 0);
--            addra : IN STD_LOGIC_VECTOR(16 DOWNTO 0);
--            dina : IN STD_LOGIC_VECTOR(11 DOWNTO 0);
--            clkb : IN STD_LOGIC;
--            enb : IN STD_LOGIC;
--            addrb : IN STD_LOGIC_VECTOR(16 DOWNTO 0);
--            doutb : OUT STD_LOGIC_VECTOR(11 DOWNTO 0)
--        );
--    END COMPONENT;

--    SIGNAL ena : STD_LOGIC := '0';
--    SIGNAL wea : STD_LOGIC_VECTOR(0 DOWNTO 0) := (OTHERS => '0');
--    SIGNAL addra : STD_LOGIC_VECTOR(16 DOWNTO 0) := (OTHERS => '0');
--    SIGNAL dina : STD_LOGIC_VECTOR(11 DOWNTO 0) := (OTHERS => '0');
--    SIGNAL enb : STD_LOGIC := '0';
--    SIGNAL addrb : STD_LOGIC_VECTOR(16 DOWNTO 0) := (OTHERS => '0');
--    SIGNAL doutb : STD_LOGIC_VECTOR(11 DOWNTO 0) := (OTHERS => '0');

--BEGIN

--    clk <= NOT clk AFTER clk_period / 2;
--    clkb <= NOT clkb AFTER clk_period;

--    DUT : blk_mem_gen_1
--    PORT MAP(
--        clka => clk,
--        wea => wea,
--        ena => '1',
--        addra => addra,
--        dina => dina,
--        clkb => clkb,
--        enb => enb,
--        addrb => addrb,
--        doutb => doutb
--    );

--    SEQUENCER_PROC : PROCESS
--    BEGIN
--        WAIT FOR clk_period * 2;

--        rst <= '0';

--        WAIT FOR clk_period * 10;
--        wea <= "1";
--        addra <= "0000000000000000000";
--        dina <= "111100001010";
--        WAIT FOR clk_period * 2;

--        addra <= "0000000000000000001";
--        dina <= "000111010111";
--        WAIT FOR clk_period * 2;

--        addra <= "0000000000000000010";
--        dina <= "100001011110";
--        WAIT FOR clk_period * 2;

--        addra <= "0000000000000000011";
--        dina <= "111100001010";

--        WAIT UNTIL rising_edge(clkb);-- clk_period * 2; --change to read   
--        addra <= "0000000000000000000";
--        dina <= (OTHERS => '0');
--        wea <= NOT wea;
--        addrb <= "00000000000000000";--17
--        enb <= NOT enb;

--        WAIT UNTIL rising_edge(clkb);-- clk_period * 2; --change to read   
--        addrb <= "00000000000000001";--17

--        WAIT UNTIL rising_edge(clkb);-- clk_period * 2; --change to read   
--        addrb <= "00000000000000010";--17
--        WAIT UNTIL rising_edge(clkb);-- clk_period * 2; --change to read   
--        addrb <= "00000000000000011";--17

--        WAIT FOR clk_period * 100;
--        finish;
--    END PROCESS;

--END ARCHITECTURE;
LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE std.env.finish;

-- Arty A7-35T: test the regenerated blk_mem_gen_1 IP
-- Simple Dual Port RAM: A = write at 100 MHz, B = read at ~25.175 MHz
-- 320 x 240 pixels, 12-bit RGB444, 17-bit address, read latency B = 1
ENTITY dual_port_bram_tb IS
END ENTITY;

ARCHITECTURE sim OF dual_port_bram_tb IS
    CONSTANT IMG_WIDTH  : NATURAL := 320;
    CONSTANT IMG_HEIGHT : NATURAL := 240;
    CONSTANT PIXEL_COUNT : NATURAL := IMG_WIDTH * IMG_HEIGHT; -- 76800
    CONSTANT ADDR_WIDTH : NATURAL := 17;
    CONSTANT DATA_WIDTH : NATURAL := 12;

    CONSTANT WRITE_CLK_PERIOD : TIME := 10 ns;      -- 100 MHz
    CONSTANT READ_CLK_PERIOD  : TIME := 39722 ps;   -- about 25.175 MHz

    SIGNAL clka : STD_LOGIC := '0';
    SIGNAL clkb : STD_LOGIC := '0';

    SIGNAL wea   : STD_LOGIC_VECTOR(0 DOWNTO 0) := "0";
    SIGNAL addra : STD_LOGIC_VECTOR(ADDR_WIDTH-1 DOWNTO 0) := (OTHERS => '0');
    SIGNAL dina  : STD_LOGIC_VECTOR(DATA_WIDTH-1 DOWNTO 0) := (OTHERS => '0');
    SIGNAL enb   : STD_LOGIC := '0';
    SIGNAL addrb : STD_LOGIC_VECTOR(ADDR_WIDTH-1 DOWNTO 0) := (OTHERS => '0');
    SIGNAL doutb : STD_LOGIC_VECTOR(DATA_WIDTH-1 DOWNTO 0);

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

    SIGNAL write_count : NATURAL RANGE 0 TO PIXEL_COUNT := 0;

    -- Deterministic test pattern with explicit frame/line boundary values.
    FUNCTION pixel_word(addr : NATURAL) RETURN STD_LOGIC_VECTOR IS
    BEGIN
        CASE addr IS
            WHEN 0 => RETURN x"001";                 -- frame start
            WHEN IMG_WIDTH - 1 => RETURN x"F00";     -- last pixel on line 0
            WHEN IMG_WIDTH => RETURN x"0F0";         -- first pixel on line 1
            WHEN PIXEL_COUNT - 1 => RETURN x"00F";   -- frame end
            WHEN OTHERS =>
                RETURN STD_LOGIC_VECTOR(to_unsigned(
                    (addr * 37 + (addr / IMG_WIDTH) * 113 + 16#35A#) MOD 4096,
                    DATA_WIDTH));
        END CASE;
    END FUNCTION;

BEGIN
    clka <= NOT clka AFTER WRITE_CLK_PERIOD / 2;
    clkb <= NOT clkb AFTER READ_CLK_PERIOD / 2;

    -- Uses the actual Block Memory Generator IP in the Vivado project.
    DUT : blk_mem_gen_1
        PORT MAP (
            clka  => clka,
            ena   => '1',
            wea   => wea,
            addra => addra,
            dina  => dina,
            clkb  => clkb,
            enb   => enb,
            addrb => addrb,
            doutb => doutb
        );

    -- Count actual writes captured at the BRAM write clock edge.
    WRITE_MONITOR : PROCESS(clka)
    BEGIN
        IF rising_edge(clka) THEN
            IF wea(0) = '1' THEN
                ASSERT to_integer(unsigned(addra)) < PIXEL_COUNT
                    REPORT "WRITE ERROR: address outside 0..76799"
                    SEVERITY failure;
                ASSERT write_count < PIXEL_COUNT
                    REPORT "WRITE ERROR: more than 76800 writes"
                    SEVERITY failure;
                write_count <= write_count + 1;
            END IF;
        END IF;
    END PROCESS;

    SEQUENCER_PROC : PROCESS
    BEGIN
        WAIT FOR 100 ns;

        -- Fill all 76800 addresses. Drive inputs at the falling edge of
        -- clka so each write is sampled cleanly at the following rising edge.
        FOR i IN 0 TO PIXEL_COUNT - 1 LOOP
            WAIT UNTIL falling_edge(clka);
            wea   <= "1";
            addra <= STD_LOGIC_VECTOR(to_unsigned(i, ADDR_WIDTH));
            dina  <= pixel_word(i);
        END LOOP;

        WAIT UNTIL falling_edge(clka);
        wea <= "0";
        WAIT FOR 1 ns;

        ASSERT write_count = PIXEL_COUNT
            REPORT "WRITE ERROR: write count = " & INTEGER'image(write_count) &
                   ", expected " & INTEGER'image(PIXEL_COUNT)
            SEVERITY failure;
        REPORT "WRITE PASS: 76800 pixels written to addresses 0..76799"
            SEVERITY note;

        -- Read every address through Port B and verify the same RGB444 data.
        -- READ_LATENCY_B = 1: check shortly after the rising edge of clkb.
        FOR i IN 0 TO PIXEL_COUNT - 1 LOOP
            WAIT UNTIL falling_edge(clkb);
            enb   <= '1';
            addrb <= STD_LOGIC_VECTOR(to_unsigned(i, ADDR_WIDTH));
           -- Cho BRAM them mot chu ky clock de cap nhat du lieu
WAIT UNTIL rising_edge(clkb);
WAIT UNTIL rising_edge(clkb);
WAIT FOR 1 ns;

ASSERT doutb = pixel_word(i)
                REPORT "READ ERROR at address " & INTEGER'image(i) &
                       ": expected 0x" & to_hstring(pixel_word(i)) &
                       ", received 0x" & to_hstring(doutb)
                SEVERITY failure;
        END LOOP;

        WAIT UNTIL falling_edge(clkb);
        enb <= '0';
        REPORT "READ PASS: all 76800 RGB444 pixels match" SEVERITY note;
        REPORT "PASS: dual_port_bram_tb for Arty A7-35T completed" SEVERITY note;
        finish;
        WAIT;
    END PROCESS;

END ARCHITECTURE;
