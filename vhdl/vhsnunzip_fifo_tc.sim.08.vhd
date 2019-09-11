library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.TestCase_pkg.all;
use work.ClockGen_pkg.all;
use work.StreamSource_pkg.all;
use work.StreamSink_pkg.all;
use work.vhsnunzip_int_pkg.all;

entity vhsnunzip_fifo_tc is
end vhsnunzip_fifo_tc;

architecture testcase of vhsnunzip_fifo_tc is

  signal clk                    : std_logic;
  signal reset                  : std_logic;

  signal a_valid                : std_logic;
  signal a_ready                : std_logic;
  signal a_data                 : std_logic_vector(7 downto 0);

  signal b_valid                : std_logic;
  signal b_ready                : std_logic;
  signal b_data                 : std_logic_vector(7 downto 0);

begin

  clkgen: ClockGen_mdl
    port map (
      clk                       => clk,
      reset                     => reset
    );

  a_source: StreamSource_mdl
    generic map (
      NAME                      => "a",
      ELEMENT_WIDTH             => 8
    )
    port map (
      clk                       => clk,
      reset                     => reset,
      valid                     => a_valid,
      ready                     => a_ready,
      data                      => a_data
    );

  uut: vhsnunzip_fifo
    generic map (
      DATA_WIDTH                => 1
    )
    port map (
      clk                       => clk,
      reset                     => reset,
      wr_valid                  => a_valid,
      wr_ready                  => a_ready,
      wr_data(0)                => a_data,
      rd_valid                  => b_valid,
      rd_ready                  => b_ready,
      rd_data(0)                => b_data
    );

  b_sink: StreamSink_mdl
    generic map (
      NAME                      => "b",
      ELEMENT_WIDTH             => 8
    )
    port map (
      clk                       => clk,
      reset                     => reset,
      valid                     => b_valid,
      ready                     => b_ready,
      data                      => b_data
    );

  speed_tc: process is
    constant TEST_STR : string := "The quick brown fox jumps over the lazy dog. Quick zephyrs blow, vexing daft Jim.";
    variable a : streamsource_type;
    variable b : streamsink_type;
  begin
    tc_open("vhsnunzip-fifo-speed", "tests that vhsnunzip-fifo reaches 1 transfer/cycle.");
    a.initialize("a");
    b.initialize("b");

    a.push_str(TEST_STR);
    a.transmit;
    b.unblock;

    tc_wait_for(2 us);

    for i in TEST_STR'range loop
      tc_check(a.cq_ready, "missing data on input stream");
      tc_check(b.cq_ready, "missing data on output stream");
      tc_check(b.cq_get_d_nat mod 256, character'pos(TEST_STR(i)), "incorrect data on output stream");
      if i > TEST_STR'low then
        tc_check(a.cq_cyc_total, 1, "input stream < 1 xfer/cycle");
        tc_check(b.cq_cyc_total, 1, "output stream < 1 xfer/cycle");
      end if;
      a.cq_next;
      b.cq_next;
    end loop;
    tc_check(not a.cq_ready, "unexpected data on input stream");
    tc_check(not b.cq_ready, "unexpected data on output stream");

    tc_pass;
    wait;
  end process;

  backpressure_tc: process is
    constant TEST_STR : string := "The quick brown fox jumps over the lazy dog. Quick zephyrs blow, vexing daft Jim.";
    variable a : streamsource_type;
    variable b : streamsink_type;
  begin
    tc_open("vhsnunzip-fifo-backpressure", "tests that vhsnunzip-fifo's backpressure handling is correct.");
    a.initialize("a");
    b.initialize("b");

    a.push_str(TEST_STR);
    a.transmit;
    b.unblock;
    tc_wait_for(100 ns);
    b.reblock;
    tc_wait_for(2 us);
    b.unblock;
    tc_wait_for(2 us);

    for i in TEST_STR'range loop
      tc_check(a.cq_ready, "missing data on input stream");
      tc_check(b.cq_ready, "missing data on output stream");
      tc_check(b.cq_get_d_nat mod 256, character'pos(TEST_STR(i)), "incorrect data on output stream");
      a.cq_next;
      b.cq_next;
    end loop;
    tc_check(not a.cq_ready, "unexpected data on input stream");
    tc_check(not b.cq_ready, "unexpected data on output stream");

    tc_pass;
    wait;
  end process;

  random_tc: process is
    constant TEST_STR_X : string := "The quick brown fox jumps over the lazy dog. Quick zephyrs blow, vexing daft Jim.";
    constant TEST_STR : string := TEST_STR_X & TEST_STR_X & TEST_STR_X & TEST_STR_X;
    variable a : streamsource_type;
    variable b : streamsink_type;
  begin
    tc_open("vhsnunzip-fifo-random", "tests randomized handshaking with vhsnunzip-fifo.");
    a.initialize("a");
    b.initialize("b");

    a.set_total_cyc(-5, 5);
    b.set_total_cyc(-5, 5);

    a.push_str(TEST_STR);
    a.transmit;
    b.unblock;
    tc_wait_for(10 us);

    for i in TEST_STR'range loop
      tc_check(a.cq_ready, "missing data on input stream");
      tc_check(b.cq_ready, "missing data on output stream");
      tc_check(b.cq_get_d_nat mod 256, character'pos(TEST_STR(i)), "incorrect data on output stream");
      a.cq_next;
      b.cq_next;
    end loop;
    tc_check(not a.cq_ready, "unexpected data on input stream");
    tc_check(not b.cq_ready, "unexpected data on output stream");

    tc_pass;
    wait;
  end process;

end TestCase;

