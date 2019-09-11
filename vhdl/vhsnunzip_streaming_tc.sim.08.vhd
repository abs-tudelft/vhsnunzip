library std;
use std.textio.all;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

library work;
use work.vhsnunzip_pkg.all;
use work.vhsnunzip_int_pkg.all;

entity vhsnunzip_streaming_tc is
  generic (
    RAM_STYLE       : string := "URAM"
  );
end vhsnunzip_streaming_tc;

architecture testcase of vhsnunzip_streaming_tc is

  signal clk        : std_logic := '0';
  signal reset      : std_logic := '1';
  signal done       : boolean := false;

  signal co_valid   : std_logic := '0';
  signal co_ready   : std_logic := '0';
  signal co_data    : std_logic_vector(63 downto 0) := (others => '0');
  signal co_cnt     : std_logic_vector(2 downto 0) := (others => '0');
  signal co_last    : std_logic := '0';

  signal de_valid   : std_logic := '0';
  signal de_ready   : std_logic := '0';
  signal de_data    : std_logic_vector(63 downto 0) := (others => '0');
  signal de_cnt     : std_logic_vector(3 downto 0) := (others => '0');
  signal de_dvalid  : std_logic := '0';
  signal de_last    : std_logic := '0';

  signal de_exp     : decompressed_stream := DECOMPRESSED_STREAM_INIT;

begin

  uut: vhsnunzip_streaming
    generic map (
      RAM_STYLE     => RAM_STYLE
    )
    port map (
      clk           => clk,
      reset         => reset,
      co_valid      => co_valid,
      co_ready      => co_ready,
      co_data       => co_data,
      co_cnt        => co_cnt,
      co_last       => co_last,
      de_valid      => de_valid,
      de_ready      => de_ready,
      de_data       => de_data,
      de_cnt        => de_cnt,
      de_dvalid     => de_dvalid,
      de_last       => de_last
    );

  clk_proc: process is
  begin
    wait for 500 ps;
    clk <= '0';
    wait for 500 ps;
    clk <= '1';
    if done then
      wait;
    end if;
  end process;

  reset_proc: process is
  begin
    reset <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    reset <= '0';
    wait;
  end process;

  source_proc: process is
    file     fil  : text;
    variable lin  : line;
    variable s1   : positive := 1;
    variable s2   : positive := 1;
    variable rnd  : real;
    variable co_v : compressed_stream_single;
  begin
    file_open(fil, "cs.tv", read_mode);
    co_valid <= '0';

    wait until reset = '0';
    wait until rising_edge(clk);

    while not endfile(fil) loop

      loop
        uniform(s1, s2, rnd);
        exit when rnd < 0.5;
        wait until rising_edge(clk);
      end loop;

      readline(fil, lin);
      stream_des(lin, co_v, true);

      co_valid <= co_v.valid;
      for byte in 0 to 7 loop
        co_data(byte*8+7 downto byte*8) <= co_v.data(byte);
      end loop;
      co_cnt <= std_logic_vector(co_v.endi + 1);
      co_last <= co_v.last;
      loop
        wait until rising_edge(clk);
        exit when co_ready = '1';
      end loop;
      co_valid <= '0';

    end loop;
    file_close(fil);
    wait;
  end process;

  sink_proc: process is
    file     fil  : text;
    variable lin  : line;
    variable s1   : positive := 2;
    variable s2   : positive := 2;
    variable rnd  : real;
    variable de_v : decompressed_stream;
  begin
    done <= false;

    file_open(fil, "de.tv", read_mode);
    de_ready <= '0';

    wait until reset = '0';
    wait until rising_edge(clk);

    while not endfile(fil) loop

      loop
        uniform(s1, s2, rnd);
        exit when rnd < 0.3;
        wait until rising_edge(clk);
      end loop;

      readline(fil, lin);
      stream_des(lin, de_v, false);
      de_exp <= de_v;

      de_ready <= '1';
      loop
        wait until rising_edge(clk);
        exit when de_valid = '1';
      end loop;
      de_ready <= '0';

      for byte in 0 to 7 loop
        assert std_match(de_v.data(byte), de_data(byte*8+7 downto byte*8)) severity failure;
      end loop;
      assert std_match(de_v.last, de_last) severity failure;
      assert std_match(de_v.cnt, unsigned(de_cnt)) severity failure;
      if de_cnt = "0000" then
        assert de_dvalid = '0' severity failure;
      else
        assert de_dvalid = '1' severity failure;
      end if;

    end loop;
    file_close(fil);

    de_ready <= '1';
    for i in 0 to 100 loop
      wait until rising_edge(clk);
      exit when de_valid = '1';
    end loop;
    de_ready <= '0';

    assert de_valid = '0' report "spurious data!" severity failure;

    done <= true;
    wait;
  end process;

end testcase;
