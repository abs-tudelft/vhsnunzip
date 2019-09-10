library std;
use std.textio.all;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

library work;
use work.vhsnunzip_pkg.all;

entity vhsnunzip_decoder_tc is
end vhsnunzip_decoder_tc;

architecture testcase of vhsnunzip_decoder_tc is

  signal clk        : std_logic := '0';
  signal reset      : std_logic := '1';
  signal done       : boolean := false;

  signal cd         : compressed_stream_double := COMPRESSED_STREAM_DOUBLE_INIT;
  signal cd_ready   : std_logic := '0';

  signal el         : element_stream := ELEMENT_STREAM_INIT;
  signal el_ready   : std_logic := '0';

  signal el_exp     : element_stream := ELEMENT_STREAM_INIT;

begin

  uut: vhsnunzip_decoder
    port map (
      clk           => clk,
      reset         => reset,
      cd            => cd,
      cd_ready      => cd_ready,
      el            => el,
      el_ready      => el_ready
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
    variable cd_v : compressed_stream_double;
  begin
    file_open(fil, "cd.tv", read_mode);
    cd.valid <= '0';

    wait until reset = '0';
    wait until rising_edge(clk);

    while not endfile(fil) loop

      loop
        uniform(s1, s2, rnd);
        exit when rnd < 0.5;
        wait until rising_edge(clk);
      end loop;

      readline(fil, lin);
      stream_des(lin, cd_v, true);

      cd <= cd_v;
      loop
        wait until rising_edge(clk);
        exit when cd_ready = '1';
      end loop;
      cd.valid <= '0';

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
    variable el_v : element_stream;
  begin
    done <= false;

    file_open(fil, "el.tv", read_mode);
    el_ready <= '0';

    wait until reset = '0';
    wait until rising_edge(clk);

    while not endfile(fil) loop

      loop
        uniform(s1, s2, rnd);
        exit when rnd < 0.3;
        wait until rising_edge(clk);
      end loop;

      readline(fil, lin);
      stream_des(lin, el_v, false);
      el_exp <= el_v;

      el_ready <= '1';
      loop
        wait until rising_edge(clk);
        exit when el.valid = '1';
      end loop;
      el_ready <= '0';

      assert std_match(el_v.cp_val, el.cp_val) severity failure;
      assert std_match(el_v.cp_off, el.cp_off) severity failure;
      assert std_match(el_v.cp_len, el.cp_len) severity failure;
      assert std_match(el_v.li_val, el.li_val) severity failure;
      assert std_match(el_v.li_off, el.li_off) severity failure;
      assert std_match(el_v.li_len, el.li_len) severity failure;
      assert std_match(el_v.ld_pop, el.ld_pop) severity failure;
      assert std_match(el_v.last, el.last) severity failure;

    end loop;
    file_close(fil);

    el_ready <= '1';
    for i in 0 to 100 loop
      wait until rising_edge(clk);
      exit when el.valid = '1';
    end loop;
    el_ready <= '0';

    assert el.valid = '0' report "spurious data!" severity failure;

    done <= true;
    wait;
  end process;

end testcase;
