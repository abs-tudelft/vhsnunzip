library std;
use std.textio.all;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

library work;
use work.vhsnunzip_int_pkg.all;

entity vhsnunzip_pre_decoder_tc is
end vhsnunzip_pre_decoder_tc;

architecture testcase of vhsnunzip_pre_decoder_tc is

  signal clk        : std_logic := '0';
  signal reset      : std_logic := '1';
  signal done       : boolean := false;

  signal cs         : compressed_stream_single := COMPRESSED_STREAM_SINGLE_INIT;
  signal cs_ready   : std_logic := '0';

  signal cd         : compressed_stream_double := COMPRESSED_STREAM_DOUBLE_INIT;
  signal cd_ready   : std_logic := '0';

  signal cd_exp     : compressed_stream_double := COMPRESSED_STREAM_DOUBLE_INIT;

begin

  uut: vhsnunzip_pre_decoder
    port map (
      clk           => clk,
      reset         => reset,
      cs            => cs,
      cs_ready      => cs_ready,
      cd            => cd,
      cd_ready      => cd_ready
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
    variable cs_v : compressed_stream_single;
  begin
    file_open(fil, "cs.tv", read_mode);
    cs.valid <= '0';

    wait until reset = '0';
    wait until rising_edge(clk);

    while not endfile(fil) loop

      loop
        uniform(s1, s2, rnd);
        exit when rnd < 0.5;
        wait until rising_edge(clk);
      end loop;

      readline(fil, lin);
      stream_des(lin, cs_v, true);

      cs <= cs_v;
      loop
        wait until rising_edge(clk);
        exit when cs_ready = '1';
      end loop;
      cs.valid <= '0';

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
    variable cd_v : compressed_stream_double;
  begin
    done <= false;

    file_open(fil, "cd.tv", read_mode);
    cd_ready <= '0';

    wait until reset = '0';
    wait until rising_edge(clk);

    while not endfile(fil) loop

      loop
        uniform(s1, s2, rnd);
        exit when rnd < 0.3;
        wait until rising_edge(clk);
      end loop;

      readline(fil, lin);
      stream_des(lin, cd_v, false);
      cd_exp <= cd_v;

      cd_ready <= '1';
      loop
        wait until rising_edge(clk);
        exit when cd.valid = '1';
      end loop;
      cd_ready <= '0';

      for i in 0 to 15 loop
        assert std_match(cd_v.data(i), cd.data(i)) severity failure;
      end loop;
      assert std_match(cd_v.first, cd.first) severity failure;
      assert std_match(cd_v.start, cd.start) severity failure;
      assert std_match(cd_v.last, cd.last) severity failure;
      assert std_match(cd_v.endi, cd.endi) severity failure;

    end loop;
    file_close(fil);

    cd_ready <= '1';
    for i in 0 to 100 loop
      wait until rising_edge(clk);
      exit when cd.valid = '1';
    end loop;
    cd_ready <= '0';

    assert cd.valid = '0' report "spurious data!" severity failure;

    done <= true;
    wait;
  end process;

end testcase;
