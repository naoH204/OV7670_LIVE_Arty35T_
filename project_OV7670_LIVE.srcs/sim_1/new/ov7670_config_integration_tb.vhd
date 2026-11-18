-- OV7670 camera configuration: full FSM + real I2C master, tested together.
-- No simulation-only RTL replacement. This testbench wires exactly the two
-- entities used by ov7670_configuration.vhd, with shorter FSM waits only.
-- This is a *behavioral* OV7670 slave (ACK + deterministic readback data).
-- Vivado 2022.2, VHDL-2008. Simulation top: ov7670_config_integration_tb.
-- Required design sources: common_pkg.vhd, OV7670_fsm.vhd (fixed), i2c_master.vhd.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.common_pkg.all;

entity ov7670_config_integration_tb is
end entity;

architecture sim of ov7670_config_integration_tb is
    constant CLK_PERIOD : time := 10 ns;
    constant N_REGS     : integer := register_config_rom'length;

    signal clk          : std_logic := '0';
    signal rst          : std_logic := '1';
    signal start_config : std_logic := '0';

    signal i2c_ena   : std_logic;
    signal i2c_addr  : std_logic_vector(6 downto 0);
    signal i2c_wdata : std_logic_vector(7 downto 0);
    signal i2c_rdata : std_logic_vector(7 downto 0);
    signal i2c_rw    : std_logic;
    signal i2c_busy  : std_logic;
    signal ack_error : std_logic;

    signal camera_reset   : std_logic;
    signal config_finished : std_logic;
    signal done            : std_logic;
    signal reg_value       : std_logic_vector(7 downto 0);

    signal scl       : std_logic := 'H';
    signal sda       : std_logic := 'H';
    signal slave_sda : std_logic := 'Z';

    signal writes_seen    : integer := 0;
    signal read_regs_seen : integer := 0;
    signal read_data_seen : integer := 0;
    signal done_count     : integer := 0;
    signal saw_reset_low  : boolean := false;
    signal cfg_rise_count : integer := 0;

    function hi(v : std_logic) return boolean is
    begin
        return to_x01(v) = '1';
    end function;

    function lo(v : std_logic) return boolean is
    begin
        return to_x01(v) = '0';
    end function;

    function read_pattern(i : integer) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned((17*i + 83) mod 256, 8));
    end function;
begin
    clk <= not clk after CLK_PERIOD / 2;

    -- Model external pull-ups and open-drain ACK/readback driver.
    scl <= 'H';
    sda <= 'H';
    sda <= slave_sda;

    -- Direct integration is logically identical to the two instances inside
    -- ov7670_configuration.vhd; do not add the full production 600 ms wait here.
    FSM_DUT : entity work.ov7670_fsm(rtl)
        generic map (
            -- The I2C master initializes busy='1', and only advertises
            -- ready (busy='0') after its first internal data_clk edge.
            -- A 20-cycle simulated power-up/reset can start the FSM too
            -- soon, so its first busy rising edge is missed. 500 cycles
            -- remain much shorter than real hardware wait, yet safely
            -- allow the I2C master to become ready.
            G_CLK_CNT_600MS => 500,
            G_CLK_CNT_1MS   => 7,
            G_CLK_CNT_1US   => 3
        )
        port map (
            clk => clk,
            rst => rst,
            start => start_config,
            i2c_busy => i2c_busy,
            i2c_rdata => i2c_rdata,
            i2c_addr => i2c_addr,
            i2c_wdata => i2c_wdata,
            i2c_ena => i2c_ena,
            i2c_rw => i2c_rw,
            ov7670_reset => camera_reset,
            reg_value => reg_value,
            config_finished => config_finished,
            done => done
        );

    I2C_DUT : entity work.i2c_master(logic)
        generic map (
            input_clk => C_ARTY_A7_CLK_FREQ,
            bus_clk => 400_000
        )
        port map (
            clk => clk,
            reset_n => rst, -- Source master actually resets for rst='1'.
            ena => i2c_ena,
            addr => i2c_addr,
            rw => i2c_rw,
            data_wr => i2c_wdata,
            busy => i2c_busy,
            data_rd => i2c_rdata,
            ack_error => ack_error,
            sda => sda,
            scl => scl
        );

    -- Do not send the first configuration command until the master has
    -- left its reset-time busy='1' condition. This guards the testbench
    -- against a false FAIL caused by overly short simulated power-up.
    FIRST_REQUEST_CHECK : process
    begin
        wait until rst = '0';
        wait until i2c_ena = '1';
        assert i2c_busy = '0'
            report "STARTUP FAIL: I2C master still busy before the first FSM request"
            severity failure;
        report "STARTUP PASS: I2C master was ready before first FSM request"
            severity note;
        wait;
    end process;

    RESET_MONITOR : process(camera_reset)
    begin
        if camera_reset = '0' then
            saw_reset_low <= true;
        end if;
    end process;

    CONFIG_MONITOR : process(config_finished)
    begin
        if rising_edge(config_finished) then
            cfg_rise_count <= cfg_rise_count + 1;
        end if;
    end process;

    -- Keep the readback scoreboard in the DONE clock domain, not the
    -- behavioral SLAVE loop. Physical STOP can precede the corresponding
    -- FSM done pulse; indexing from the SLAVE loop checks the previous data
    -- against the next ROM index (an artificial off-by-one failure).
    DONE_MONITOR : process
        variable completed_reads : natural := 0;
    begin
        wait until rst = '0';
        loop
            wait until rising_edge(done);
            wait for 1 ns;  -- settle reg_value after the registered done pulse
            assert config_finished = '1'
                report "INTEGRATION FAIL: done before config_finished"
                severity failure;
            assert completed_reads < N_REGS
                report "INTEGRATION FAIL: extra done pulse after 78 readbacks"
                severity failure;
            -- A weak pull-up may yield 'H' for logic 1; normalize it to '1'.
            assert to_x01(reg_value) = read_pattern(completed_reads)
                report "INTEGRATION FAIL: readback mismatch at done index " &
                       integer'image(completed_reads) &
                       ", expected=0x" & to_hstring(read_pattern(completed_reads)) &
                       ", reg_value=0x" & to_hstring(to_x01(reg_value)) &
                       ", i2c_rdata=0x" & to_hstring(to_x01(i2c_rdata))
                severity failure;
            if completed_reads = 0 then
                report "READBACK ALIGNMENT PASS: first done matched first read byte"
                    severity note;
            end if;
            completed_reads := completed_reads + 1;
            done_count <= completed_reads;
        end loop;
    end process;

    ACK_MONITOR : process(ack_error)
    begin
        if ack_error = '1' then
            assert false
                report "INTEGRATION FAIL: master ACK error at " & time'image(now) &
                       ", SDA=" & std_logic'image(sda) &
                       ", SCL=" & std_logic'image(scl)
                severity failure;
        end if;
    end process;

    -- Real SCL/SDA-level slave. Verifies every ROM entry on the wire,
    -- acknowledges each byte, returns synthetic data on read operations.
    SLAVE : process
        variable got : std_logic_vector(7 downto 0);
        variable expected : std_logic_vector(7 downto 0);

        procedure wait_start is
        begin
            loop
                wait on sda;
                exit when lo(sda) and hi(scl);
            end loop;
        end procedure;

        procedure wait_stop is
        begin
            loop
                wait on sda;
                exit when hi(sda) and hi(scl);
            end loop;
        end procedure;

        procedure recv_byte(variable value : out std_logic_vector(7 downto 0)) is
        begin
            value := (others => '0');
            for bit_index in 7 downto 0 loop
                loop
                    wait on scl;
                    exit when hi(scl);
                end loop;
                assert lo(sda) or hi(sda)
                    report "INTEGRATION FAIL: undefined SDA while receiving byte"
                    severity failure;
                if hi(sda) then
                    value(bit_index) := '1';
                end if;
            end loop;
        end procedure;

        procedure check_byte(constant target : in std_logic_vector(7 downto 0);
                             constant phase : in string;
                             constant index : in integer) is
        begin
            recv_byte(got);
            assert got = target
                report "INTEGRATION FAIL: " & phase & " at index " &
                       integer'image(index) & ", expected=" &
                       integer'image(to_integer(unsigned(target))) &
                       ", received=" & integer'image(to_integer(unsigned(got)))
                severity failure;
        end procedure;

        procedure slave_ack is
        begin
            -- Drive ACK low beginning in the ninth bit's SCL-low interval.
            loop
                wait on scl;
                exit when lo(scl);
            end loop;
            slave_sda <= '0';
            wait for 1 ns;
            assert lo(sda)
                report "INTEGRATION FAIL: slave could not pull SDA low for ACK"
                severity failure;
            loop
                wait on scl;
                exit when hi(scl);
            end loop;
            loop
                wait on scl;
                exit when lo(scl);
            end loop;
            slave_sda <= 'Z';
        end procedure;

        procedure slave_send_byte(constant value : in std_logic_vector(7 downto 0)) is
        begin
            -- Called immediately after address ACK (SCL low). Send MSB first.
            for bit_index in 7 downto 0 loop
                if value(bit_index) = '0' then
                    slave_sda <= '0';
                else
                    slave_sda <= 'Z';
                end if;
                loop
                    wait on scl;
                    exit when hi(scl);
                end loop;
                wait for 1 ns;
                assert to_x01(sda) = value(bit_index)
                    report "INTEGRATION FAIL: read byte could not drive bit " &
                           integer'image(bit_index) severity failure;
                loop
                    wait on scl;
                    exit when lo(scl);
                end loop;
            end loop;
            slave_sda <= 'Z';
            -- Master NACKs this last read byte before sending STOP.
            loop
                wait on scl;
                exit when hi(scl);
            end loop;
            assert hi(sda)
                report "INTEGRATION FAIL: master did not NACK final read byte"
                severity failure;
            loop
                wait on scl;
                exit when lo(scl);
            end loop;
        end procedure;
    begin
        wait until rst = '0';
        assert N_REGS = 78
            report "INTEGRATION FAIL: this test expects a 78-entry ROM"
            severity failure;

        -- Phase A: full three-byte register writes, with one START/STOP each.
        for i in register_config_rom'range loop
            wait_start;
            check_byte(x"42", "write slave address", i);
            slave_ack;
            check_byte(register_config_rom(i)(15 downto 8), "write register", i);
            slave_ack;
            check_byte(register_config_rom(i)(7 downto 0), "write value", i);
            slave_ack;
            wait_stop;
            writes_seen <= writes_seen + 1;
            if i < register_config_rom'high then
                assert config_finished = '0'
                    report "INTEGRATION FAIL: config_finished early at ROM index " &
                           integer'image(i) severity failure;
            end if;
            if (i + 1) mod 13 = 0 then
                report "INTEGRATION: " & integer'image(i + 1) &
                       "/78 physical SCCB writes verified" severity note;
            end if;
        end loop;

        -- The FSM may assert finished before the final physical STOP edge.
        if config_finished /= '1' then
            wait until config_finished = '1' for 20 us;
        end if;
        wait for 1 ns; -- allow config counter monitor to update
        assert config_finished = '1'
            report "INTEGRATION FAIL: config_finished not asserted after final write"
            severity failure;
        assert saw_reset_low
            report "INTEGRATION FAIL: camera reset never asserted low"
            severity failure;
        assert cfg_rise_count = 1
            report "INTEGRATION FAIL: config_finished should rise once"
            severity failure;
        report "WRITE PASS: all 78 ROM register/value pairs transmitted over SDA/SCL" severity note;
        report "CONFIG PASS: config_finished asserted after final physical write" severity note;

        -- Phase B: the FSM reads back each register via two transactions:
        --   START 0x42 reg ACK STOP; START 0x43 ACK data NACK STOP.
        for i in register_config_rom'range loop
            -- Select register address. DONE_MONITOR tracks its own index.
            wait_start;
            check_byte(x"42", "read-setup slave address", i);
            slave_ack;
            check_byte(register_config_rom(i)(15 downto 8), "read-setup register", i);
            slave_ack;
            wait_stop;
            read_regs_seen <= read_regs_seen + 1;

            -- Read its value. The FPGA should send (7-bit address << 1) | 1.
            wait_start;
            check_byte(x"43", "read slave address", i);
            slave_ack;
            slave_send_byte(read_pattern(i));
            wait_stop;
            read_data_seen <= read_data_seen + 1;
            if (i + 1) mod 13 = 0 then
                report "INTEGRATION: " & integer'image(i + 1) &
                       "/78 physical SCCB readbacks verified" severity note;
            end if;
        end loop;

        -- The physical STOP of the final read can precede the FSM's DONE.
        -- The I2C master must first finish its STOP/ready transition and
        -- drive busy low, then the FSM can capture data and assert done.
        -- Wait for the *observed* 78th DONE, with a finite timeout, instead
        -- of using a fixed 1-us delay that may check too early.
        if done_count < N_REGS then
            wait until done_count = N_REGS for 30 us;
        end if;
        assert done_count = N_REGS
            report "INTEGRATION FAIL: final done pulse missing after 30 us timeout (got " &
                   integer'image(done_count) & "/" & integer'image(N_REGS) & ")"
            severity failure;
        -- Give DONE time to return low and the FSM to enter its final idle state.
        wait for 250 ns;
        assert done = '0'
            report "INTEGRATION FAIL: done did not return low after the final read"
            severity failure;
        assert i2c_ena = '0' and i2c_busy = '0'
            report "INTEGRATION FAIL: I2C master/FSM did not return to idle"
            severity failure;
        assert writes_seen = N_REGS
            report "INTEGRATION FAIL: wrong number of writes" severity failure;
        assert read_regs_seen = N_REGS and read_data_seen = N_REGS
            report "INTEGRATION FAIL: wrong number of read transactions" severity failure;
        assert done_count = N_REGS
            report "INTEGRATION FAIL: wrong number of done pulses (got " &
                   integer'image(done_count) & ")" severity failure;
        assert config_finished = '1'
            report "INTEGRATION FAIL: config_finished dropped" severity failure;

        report "READ PASS: 78 register-address writes and 78 SCCB readbacks" severity note;
        report "DONE PASS: all 78 done pulses matched synthetic read data" severity note;
        report "PASS: OV7670 FSM + I2C Master integration completed for Arty A7-35T"
            severity note;
        finish;
        wait;
    end process;

    STIMULUS : process
    begin
        wait for 200 ns;
        rst <= '0';
        wait;
    end process;

    WATCHDOG : process
    begin
        wait for 50 ms;
        assert false report "INTEGRATION FAIL: 50 ms watchdog timeout" severity failure;
        finish;
        wait;
    end process;
end architecture;
