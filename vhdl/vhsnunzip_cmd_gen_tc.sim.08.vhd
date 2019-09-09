library std;
use std.textio.all;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

library work;
use work.vhsnunzip_pkg.all;

entity vhsnunzip_cmd_gen_tc is
end vhsnunzip_cmd_gen_tc;

architecture testcase of vhsnunzip_cmd_gen_tc is

  signal clk        : std_logic := '0';
  signal reset      : std_logic := '1';
  signal done       : boolean := false;

  signal el         : element_stream := ELEMENT_STREAM_INIT;
  signal el_ready   : std_logic := '0';

  signal cm         : command_stream := COMMAND_STREAM_INIT;
  signal cm_ready   : std_logic := '0';

  signal cm_exp     : command_stream := COMMAND_STREAM_INIT;

begin

  uut: vhsnunzip_cmd_gen
    port map (
      clk           => clk,
      reset         => reset,
      el            => el,
      el_ready      => el_ready,
      cm            => cm,
      cm_ready      => cm_ready
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
    variable cm_v : command_stream;
  begin
    done <= false;

    file_open(fil, "cm.tv", read_mode);
    cm_ready <= '0';
    while not endfile(fil) loop

      loop
        uniform(s1, s2, rnd);
        exit when rnd < 0.3;
        wait until rising_edge(clk);
      end loop;

      readline(fil, lin);
      stream_des(lin, cm_v, false);
      cm_exp <= cm_v;

      cm_ready <= '1';
      loop
        wait until rising_edge(clk);
        exit when cm.valid = '1';
      end loop;
      cm_ready <= '0';

      assert std_match(cm_v.lt_val, cm.lt_val) severity failure;
      assert std_match(cm_v.lt_adev, cm.lt_adev) severity failure;
      assert std_match(cm_v.lt_adod, cm.lt_adod) severity failure;
      assert std_match(cm_v.lt_swap, cm.lt_swap) severity failure;
      assert std_match(cm_v.st_addr, cm.st_addr) severity failure;
      assert std_match(cm_v.cp_rol, cm.cp_rol) severity failure;
      assert std_match(cm_v.cp_rle, cm.cp_rle) severity failure;
      assert std_match(cm_v.cp_end, cm.cp_end) severity failure;
      assert std_match(cm_v.li_rol, cm.li_rol) severity failure;
      assert std_match(cm_v.li_end, cm.li_end) severity failure;
      assert std_match(cm_v.ld_pop, cm.ld_pop) severity failure;
      assert std_match(cm_v.last, cm.last) severity failure;

    end loop;
    file_close(fil);

    cm_ready <= '1';
    for i in 0 to 100 loop
      wait until rising_edge(clk);
      exit when cm.valid = '1';
    end loop;
    cm_ready <= '0';

    assert cm.valid = '0' report "spurious data!" severity failure;

    done <= true;
    wait;
  end process;

end testcase;
