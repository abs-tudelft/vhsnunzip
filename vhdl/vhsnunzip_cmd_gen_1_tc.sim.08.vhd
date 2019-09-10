library std;
use std.textio.all;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

library work;
use work.vhsnunzip_pkg.all;

entity vhsnunzip_cmd_gen_1_tc is
end vhsnunzip_cmd_gen_1_tc;

architecture testcase of vhsnunzip_cmd_gen_1_tc is

  signal clk        : std_logic := '0';
  signal reset      : std_logic := '1';
  signal done       : boolean := false;

  signal el         : element_stream := ELEMENT_STREAM_INIT;
  signal el_ready   : std_logic := '0';

  signal c1         : partial_command_stream := PARTIAL_COMMAND_STREAM_INIT;
  signal c1_ready   : std_logic := '0';

  signal c1_exp     : partial_command_stream := PARTIAL_COMMAND_STREAM_INIT;

begin

  uut: vhsnunzip_cmd_gen_1
    port map (
      clk           => clk,
      reset         => reset,
      el            => el,
      el_ready      => el_ready,
      c1            => c1,
      c1_ready      => c1_ready
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
    variable el_v : element_stream;
  begin
    file_open(fil, "el.tv", read_mode);
    el.valid <= '0';

    wait until reset = '0';
    wait until rising_edge(clk);

    while not endfile(fil) loop

      loop
        uniform(s1, s2, rnd);
        exit when rnd < 0.5;
        wait until rising_edge(clk);
      end loop;

      readline(fil, lin);
      stream_des(lin, el_v, true);

      el <= el_v;
      loop
        wait until rising_edge(clk);
        exit when el_ready = '1';
      end loop;
      el.valid <= '0';

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
    variable c1_v : partial_command_stream;
  begin
    wait until reset = '0';
    wait until rising_edge(clk);

    done <= false;

    file_open(fil, "c1.tv", read_mode);
    c1_ready <= '0';
    while not endfile(fil) loop

      loop
        uniform(s1, s2, rnd);
        exit when rnd < 0.3;
        wait until rising_edge(clk);
      end loop;

      readline(fil, lin);
      stream_des(lin, c1_v, false);
      c1_exp <= c1_v;

      c1_ready <= '1';
      loop
        wait until rising_edge(clk);
        exit when c1.valid = '1';
      end loop;
      c1_ready <= '0';

      assert std_match(c1_v.cp_off, c1.cp_off) severity failure;
      assert std_match(c1_v.cp_len, c1.cp_len) severity failure;
      assert std_match(c1_v.cp_rle, c1.cp_rle) severity failure;
      assert std_match(c1_v.li_val, c1.li_val) severity failure;
      assert std_match(c1_v.li_off, c1.li_off) severity failure;
      assert std_match(c1_v.li_len, c1.li_len) severity failure;
      assert std_match(c1_v.ld_pop, c1.ld_pop) severity failure;
      assert std_match(c1_v.last, c1.last) severity failure;

    end loop;
    file_close(fil);

    c1_ready <= '1';
    for i in 0 to 100 loop
      wait until rising_edge(clk);
      exit when c1.valid = '1';
    end loop;
    c1_ready <= '0';

    assert c1.valid = '0' report "spurious data!" severity failure;

    done <= true;
    wait;
  end process;

end testcase;
