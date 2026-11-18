---- SCCB/I2C write-byte functional test for the existing i2c_master(logic).
---- Vivado 2022.2: set File Type to VHDL 2008.
--library ieee;
--use ieee.std_logic_1164.all;
--use ieee.numeric_std.all;
--use std.env.all;

--entity i2c_master_tb is
--end entity;

--architecture sim of i2c_master_tb is
--    constant CLK_PERIOD : time := 10 ns;
--    signal clk       : std_logic := '0';
--    signal reset_n   : std_logic := '1'; -- IMPORTANT: this source RTL resets when reset_n='1'
--    signal ena       : std_logic := '0';
--    signal addr      : std_logic_vector(6 downto 0) := "0100001"; -- OV7670 SCCB ID 0x42 for write
--    signal rw        : std_logic := '0';
--    signal data_wr   : std_logic_vector(7 downto 0) := x"00";
--    signal busy      : std_logic;
--    signal data_rd   : std_logic_vector(7 downto 0);
--    signal ack_error : std_logic;
--    signal sda       : std_logic := 'H';
--    signal scl       : std_logic := 'H';
--    signal slave_sda : std_logic := 'Z';
--    signal tx_count  : natural := 0;
--    signal stop_seen : natural := 0;

--    function hi(v : std_logic) return boolean is
--    begin
--        return to_x01(v) = '1';
--    end function;
--    function lo(v : std_logic) return boolean is
--    begin
--        return to_x01(v) = '0';
--    end function;
--begin
--    clk <= not clk after CLK_PERIOD/2;
--    sda <= 'H';  -- simulate bus pull-up
--    scl <= 'H';
--    sda <= slave_sda; -- open-drain slave ACK

--    DUT: entity work.i2c_master(logic)
--        generic map(input_clk => 100_000_000, bus_clk => 400_000)
--        port map(clk=>clk,reset_n=>reset_n,ena=>ena,addr=>addr,rw=>rw,
--                 data_wr=>data_wr,busy=>busy,data_rd=>data_rd,
--                 ack_error=>ack_error,sda=>sda,scl=>scl);

--    -- Minimal OV7670-like slave: check address + data, ACK both bytes.
--    SLAVE: process
--        variable observed : std_logic_vector(7 downto 0);
--        variable target   : std_logic_vector(7 downto 0);
--    begin
--        for transaction in 0 to 1 loop
--            -- START: SDA falls while SCL is high
--            loop
--                wait on sda;
--                exit when lo(sda) and hi(scl);
--            end loop;
--            for byte_index in 0 to 1 loop
--                observed := (others=>'0');
--                for bit_index in 7 downto 0 loop
--                    loop
--                        wait on scl;
--                        exit when hi(scl);
--                    end loop;
--                    assert lo(sda) or hi(sda)
--                        report "SDA unknown while receiving byte" severity failure;
--                    if hi(sda) then
--                        observed(bit_index) := '1';
--                    end if;
--                end loop;
--                if byte_index = 0 then
--                    target := x"42";
--                elsif transaction = 0 then
--                    target := x"12";
--                else
--                    target := x"14";
--                end if;
--                assert observed = target
--                    report "SCCB byte mismatch at transaction " & integer'image(transaction) &
--                           ", byte " & integer'image(byte_index) &
--                           ": expected " & integer'image(to_integer(unsigned(target))) &
--                           ", got " & integer'image(to_integer(unsigned(observed)))
--                    severity failure;
--                -- ACK low throughout the ninth SCL high phase.
--                loop
--                    wait on scl;
--                    exit when lo(scl);
--                end loop;
--                slave_sda <= '0';
--                loop
--                    wait on scl;
--                    exit when hi(scl);
--                end loop;
--                loop
--                    wait on scl;
--                    exit when lo(scl);
--                end loop;
--                slave_sda <= 'Z';
--            end loop;
--            -- STOP: SDA rises while SCL high
--            loop
--                wait on sda;
--                exit when hi(sda) and hi(scl);
--            end loop;
--            stop_seen <= stop_seen + 1;
--            tx_count <= tx_count + 1;
--        end loop;
--        wait;
--    end process;

--    STIMULUS: process
--    begin
--        wait for 200 ns;
--        reset_n <= '0';
--        wait for 200 ns;
--        -- single-byte write to OV7670 register-address stage
--        data_wr <= x"12";
--        ena <= '1';
--        wait until busy = '1' for 100 us;
--        assert busy = '1' report "First transaction never started" severity failure;
--        ena <= '0';
--        wait until busy = '0' for 100 us;
--        assert busy = '0' report "First transaction timed out" severity failure;
--        wait for 8 us;
--        assert ack_error = '0' report "First transaction ACK error" severity failure;

--        -- second transaction: value 0x14 (COM7 QVGA RGB)
--        data_wr <= x"14";
--        ena <= '1';
--        wait until busy = '1' for 100 us;
--        assert busy = '1' report "Second transaction never started" severity failure;
--        ena <= '0';
--        wait until busy = '0' for 100 us;
--        assert busy = '0' report "Second transaction timed out" severity failure;
--        wait for 8 us;
--        assert ack_error = '0' report "Second transaction ACK error" severity failure;
--        assert tx_count = 2 and stop_seen = 2
--            report "Expected two complete SCCB write transactions" severity failure;
--        report "SCCB BYTE PASS: address 0x42, register 0x12, value 0x14" severity note;
--        report "ACK PASS: slave acknowledged address and data bytes" severity note;
--        report "PASS: i2c_master_tb for OV7670 on Arty A7-35T completed" severity note;
--        finish;
--    end process;

--    WATCHDOG: process
--    begin
--        wait for 1 ms;
--        assert false report "TIMEOUT: SCCB/I2C testbench did not finish" severity failure;
--        finish;
--    end process;
--end architecture;


-- OV7670 SCCB write-register testbench for existing i2c_master(logic).
-- Check a SINGLE transaction: START, 0x42, ACK, 0x12, ACK, 0x14, ACK, STOP.
-- IMPORTANT: this RTL drives busy='1' during reset; wait for busy='0' BEFORE ena.
-- Vivado 2022.2: set File Type = VHDL 2008.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity i2c_master_tb is
end entity;

architecture sim of i2c_master_tb is
    constant CLK_PERIOD : time := 10 ns;
    signal clk       : std_logic := '0';
    signal reset_n   : std_logic := '1'; -- Source RTL: '1' asserts reset (despite name)
    signal ena       : std_logic := '0';
    signal addr      : std_logic_vector(6 downto 0) := "0100001"; -- 7-bit 0x21
    signal rw        : std_logic := '0';
    signal data_wr   : std_logic_vector(7 downto 0) := x"00";
    signal busy      : std_logic;
    signal data_rd   : std_logic_vector(7 downto 0);
    signal ack_error : std_logic;
    signal sda       : std_logic := 'H';
    signal scl       : std_logic := 'H';
    signal slave_sda : std_logic := 'Z';
    signal stop_seen : natural := 0;
    signal ack_seen  : natural := 0;

    function hi(v : std_logic) return boolean is
    begin
        return to_x01(v) = '1';
    end function;
    function lo(v : std_logic) return boolean is
    begin
        return to_x01(v) = '0';
    end function;
begin
    clk <= not clk after CLK_PERIOD / 2;
    sda <= 'H'; -- weak pull-up
    scl <= 'H';
    sda <= slave_sda; -- slave only drives low during ACK

    DUT: entity work.i2c_master(logic)
        generic map (input_clk => 100_000_000, bus_clk => 400_000)
        port map (
            clk => clk, reset_n => reset_n, ena => ena,
            addr => addr, rw => rw, data_wr => data_wr,
            busy => busy, data_rd => data_rd, ack_error => ack_error,
            sda => sda, scl => scl
        );

    -- OV7670-like slave checks all three bytes in one SCCB write.
    SLAVE: process
        variable observed : std_logic_vector(7 downto 0);
        variable target   : std_logic_vector(7 downto 0);
    begin
        -- START condition
        loop
            wait on sda;
            exit when lo(sda) and hi(scl);
        end loop;
        report "SLAVE: START detected" severity note;

        for byte_index in 0 to 2 loop
            observed := (others => '0');
            for bit_index in 7 downto 0 loop
                loop
                    wait on scl;
                    exit when hi(scl);
                end loop;
                assert lo(sda) or hi(sda)
                    report "SDA is not 0/1 while receiving data" severity failure;
                if hi(sda) then
                    observed(bit_index) := '1';
                end if;
            end loop;

            case byte_index is
                when 0 => target := x"42"; -- slave address + write bit
                when 1 => target := x"12"; -- COM7 register address
                when others => target := x"14"; -- COM7 QVGA configuration
            end case;
            assert observed = target
                report "SCCB byte mismatch, index=" & integer'image(byte_index) &
                       ", expected=" & integer'image(to_integer(unsigned(target))) &
                       ", received=" & integer'image(to_integer(unsigned(observed)))
                severity failure;
            report "SLAVE: byte " & integer'image(byte_index) &
                   " PASS (" & integer'image(to_integer(unsigned(target))) & ")"
                severity note;

            -- Release data phase, ACK low throughout ninth SCL pulse.
            loop
                wait on scl;
                exit when lo(scl);
            end loop;
            slave_sda <= '0';
            wait for 1 ns;
            assert lo(sda) report "SLAVE: ACK SDA did not resolve low" severity failure;
            loop
                wait on scl;
                exit when hi(scl);
            end loop;
            loop
                wait on scl;
                exit when lo(scl);
            end loop;
            slave_sda <= 'Z';
            ack_seen <= ack_seen + 1;
            report "SLAVE: ACK for byte " & integer'image(byte_index) severity note;
        end loop;

        -- STOP condition (rising SDA while SCL high)
        loop
            wait on sda;
            exit when hi(sda) and hi(scl);
        end loop;
        stop_seen <= stop_seen + 1;
        report "SLAVE: STOP detected" severity note;
        wait;
    end process;

    STIMULUS: process
    begin
        wait for 200 ns;
        reset_n <= '0'; -- release reset

        -- Critical fix: allow master to become READY (busy=0) first.
        wait until busy = '0' for 20 us;
        assert busy = '0'
            report "Master never became ready after reset" severity failure;
        report "MASTER: ready (busy=0)" severity note;

        -- Request first data byte (register address); address byte is automatic.
        data_wr <= x"12";
        ena <= '1';
        wait until busy = '1' for 20 us;
        assert busy = '1' report "Master did not start transaction" severity failure;

        -- Prepare next byte well before slv_ack2 latches it.
        -- Keep ena=1 so this master continues WITHOUT a repeated START.
        data_wr <= x"14";
        wait until busy = '0' for 120 us;
        assert busy = '0'
            report "Master did not request the continuation byte" severity failure;
        report "MASTER: continuation accepted" severity note;
        ena <= '0'; -- Stop after second data byte (0x14)

        wait until busy = '1' for 20 us;
        assert busy = '1' report "Second data byte was not started" severity failure;
        wait until busy = '0' for 120 us;
        assert busy = '0' report "Master did not complete transaction" severity failure;
        wait for 4 us; -- allow slave STOP detector and monitors to settle

        assert ack_error = '0' report "Master reports ACK error" severity failure;
        assert ack_seen = 3 report "Expected ACK for all three bytes" severity failure;
        assert stop_seen = 1 report "Expected exactly one STOP" severity failure;

        report "SCCB BYTE PASS: 0x42 -> 0x12 -> 0x14 in one transaction" severity note;
        report "ACK PASS: all 3 bytes acknowledged" severity note;
        report "PASS: i2c_master_tb for OV7670 on Arty A7-35T completed" severity note;
        finish;
    end process;

    ACK_ERROR_MONITOR: process(ack_error)
    begin
        if ack_error = '1' then
            report "DEBUG ACK_ERROR at " & time'image(now) &
                   "; SDA=" & std_logic'image(sda) &
                   "; SCL=" & std_logic'image(scl) &
                   "; slave_sda=" & std_logic'image(slave_sda)
                severity warning;
        end if;
    end process;

    WATCHDOG: process
    begin
        wait for 500 us;
        assert false report "TIMEOUT: SCCB testbench did not finish" severity failure;
        finish;
    end process;
end architecture;

