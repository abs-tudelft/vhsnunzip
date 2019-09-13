library std;
use std.textio.all;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

library work;
use work.vhsnunzip_int_pkg.all;

entity vhsnunzip_pipeline_tc is
end vhsnunzip_pipeline_tc;

architecture testcase of vhsnunzip_pipeline_tc is

  signal clk        : std_logic := '0';
  signal reset      : std_logic := '1';
  signal done       : boolean := false;

  signal co         : compressed_stream_single := COMPRESSED_STREAM_SINGLE_INIT;
  signal co_ready   : std_logic := '0';

  signal dbg_cs     : compressed_stream_single;
  signal dbg_cs_exp : compressed_stream_single;
  signal dbg_cd     : compressed_stream_double;
  signal dbg_cd_exp : compressed_stream_double;
  signal dbg_el     : element_stream;
  signal dbg_el_exp : element_stream;
  signal dbg_c1     : partial_command_stream;
  signal dbg_c1_exp : partial_command_stream;
  signal dbg_cm     : command_stream;
  signal dbg_cm_exp : command_stream;
  signal dbg_s1     : command_stream;
  signal dbg_s1_exp : command_stream;

  signal de         : decompressed_stream := DECOMPRESSED_STREAM_INIT;
  signal de_ready   : std_logic := '0';

  signal de_exp     : decompressed_stream := DECOMPRESSED_STREAM_INIT;

  signal lt_valid   : std_logic;
  signal lt_ready   : std_logic;
  signal lt_adev    : unsigned(11 downto 0);
  signal lt_adod    : unsigned(11 downto 0);
  signal lt_next    : std_logic;
  signal lt_even    : byte_array(0 to 7);
  signal lt_odd     : byte_array(0 to 7);

  type lt_stage is record
    valid           : std_logic;
    even            : byte_array(0 to 7);
    odd             : byte_array(0 to 7);
  end record;
  type lt_pipeline is array (natural range <>) of lt_stage;
  signal lt_stages  : lt_pipeline(0 to 5);

  type lt_mem_array is array (natural range <>) of byte_array(0 to 7);
  signal lt_mem_ev  : lt_mem_array(0 to 4095);
  signal lt_mem_od  : lt_mem_array(0 to 4095);
  signal lt_ptr     : unsigned(12 downto 0) := (others => '0');

begin

  uut: vhsnunzip_pipeline
    port map (
      clk           => clk,
      reset         => reset,
      co            => co,
      co_ready      => co_ready,
      lt_rd_valid   => lt_valid,
      lt_rd_ready   => lt_ready,
      lt_rd_adev    => lt_adev,
      lt_rd_adod    => lt_adod,
      lt_rd_next    => lt_next,
      lt_rd_even    => lt_even,
      lt_rd_odd     => lt_odd,
      dbg_cs        => dbg_cs,
      dbg_cd        => dbg_cd,
      dbg_el        => dbg_el,
      dbg_c1        => dbg_c1,
      dbg_cm        => dbg_cm,
      dbg_s1        => dbg_s1,
      de            => de,
      de_ready      => de_ready
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
    co.valid <= '0';

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

      co <= co_v;
      loop
        wait until rising_edge(clk);
        exit when co_ready = '1';
      end loop;
      co.valid <= '0';

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
        exit when de.valid = '1';
      end loop;
      de_ready <= '0';

      for i in 0 to 7 loop
        assert std_match(de_v.data(i), de.data(i)) severity failure;
      end loop;
      assert std_match(de_v.last, de.last) severity failure;
      assert std_match(de_v.cnt, de.cnt) severity failure;

    end loop;
    file_close(fil);

    de_ready <= '1';
    for i in 0 to 100 loop
      wait until rising_edge(clk);
      exit when de.valid = '1';
    end loop;
    de_ready <= '0';

    assert de.valid = '0' report "spurious data!" severity failure;

    done <= true;
    wait;
  end process;

  lt_arb_mock_proc: process is
    variable s1   : positive := 3;
    variable s2   : positive := 3;
    variable rnd  : real;
  begin

    lt_ready <= '0';

    loop
      uniform(s1, s2, rnd);
      exit when rnd < 0.3;
      wait until rising_edge(clk);
    end loop;

    lt_ready <= '1';

    loop
      uniform(s1, s2, rnd);
      exit when rnd < 0.3;
      wait until rising_edge(clk);
    end loop;

  end process;

  lt_mem_mock_proc: process (clk) is
  begin
    if rising_edge(clk) then

      -- Handle decompressed data writes.
      if de.valid = '1' and de_ready = '1' then
        if de.last = '1' then
          lt_ptr <= (others => '0');
        else
          if lt_ptr(0) = '0' then
            lt_mem_ev(to_integer(lt_ptr(12 downto 1))) <= de.data;
          else
            lt_mem_od(to_integer(lt_ptr(12 downto 1))) <= de.data;
          end if;
          lt_ptr <= lt_ptr + 1;
        end if;
      end if;

      -- Model a read pipeline that meets the requirements.
      lt_stages(1 to 5) <= lt_stages(0 to 4);
      lt_stages(0).valid <= lt_valid and lt_ready;
      lt_stages(0).even <= lt_mem_ev(to_integer(lt_adev));
      lt_stages(0).odd <= lt_mem_od(to_integer(lt_adod));

      lt_next <= lt_stages(4).valid;
      lt_even <= lt_stages(5).even;
      lt_odd  <= lt_stages(5).odd;

      if reset = '1' then
        lt_ptr <= (others => '0');
      end if;
    end if;
  end process;

  cs_check_proc: process is
    file     fil  : text;
    variable lin  : line;
    variable cs_v : compressed_stream_single;
  begin
    file_open(fil, "cs.tv", read_mode);

    wait until reset = '0';
    wait until rising_edge(clk);

    while not endfile(fil) loop

      readline(fil, lin);
      stream_des(lin, cs_v, false);
      dbg_cs_exp <= cs_v;

      loop
        wait until rising_edge(clk);
        exit when dbg_cs.valid = '1';
      end loop;

      for i in 0 to 7 loop
        assert std_match(cs_v.data(i), dbg_cs.data(i)) severity failure;
      end loop;
      assert std_match(cs_v.last, dbg_cs.last) severity failure;
      assert std_match(cs_v.endi, dbg_cs.endi) severity failure;

    end loop;
    file_close(fil);
    wait;
  end process;

  cd_check_proc: process is
    file     fil  : text;
    variable lin  : line;
    variable cd_v : compressed_stream_double;
  begin
    file_open(fil, "cd.tv", read_mode);

    wait until reset = '0';
    wait until rising_edge(clk);

    while not endfile(fil) loop

      readline(fil, lin);
      stream_des(lin, cd_v, false);
      dbg_cd_exp <= cd_v;

      loop
        wait until rising_edge(clk);
        exit when dbg_cd.valid = '1';
      end loop;

      for i in 0 to 15 loop
        assert std_match(cd_v.data(i), dbg_cd.data(i)) severity failure;
      end loop;
      assert std_match(cd_v.first, dbg_cd.first) severity failure;
      assert std_match(cd_v.start, dbg_cd.start) severity failure;
      assert std_match(cd_v.last, dbg_cd.last) severity failure;
      assert std_match(cd_v.endi, dbg_cd.endi) severity failure;

    end loop;
    file_close(fil);
    wait;
  end process;

  el_check_proc: process is
    file     fil  : text;
    variable lin  : line;
    variable el_v : element_stream;
  begin
    file_open(fil, "el.tv", read_mode);

    wait until reset = '0';
    wait until rising_edge(clk);

    while not endfile(fil) loop

      readline(fil, lin);
      stream_des(lin, el_v, false);
      dbg_el_exp <= el_v;

      loop
        wait until rising_edge(clk);
        exit when dbg_el.valid = '1';
      end loop;

      assert std_match(el_v.cp_val, dbg_el.cp_val) severity failure;
      assert std_match(el_v.cp_off, dbg_el.cp_off) severity failure;
      assert std_match(el_v.cp_len, dbg_el.cp_len) severity failure;
      assert std_match(el_v.li_val, dbg_el.li_val) severity failure;
      assert std_match(el_v.li_off, dbg_el.li_off) severity failure;
      assert std_match(el_v.li_len, dbg_el.li_len) severity failure;
      assert std_match(el_v.ld_pop, dbg_el.ld_pop) severity failure;
      assert std_match(el_v.last, dbg_el.last) severity failure;

    end loop;
    file_close(fil);
    wait;
  end process;

  c1_check_proc: process is
    file     fil  : text;
    variable lin  : line;
    variable c1_v : partial_command_stream;
  begin
    file_open(fil, "c1.tv", read_mode);

    wait until reset = '0';
    wait until rising_edge(clk);

    while not endfile(fil) loop

      readline(fil, lin);
      stream_des(lin, c1_v, false);
      dbg_c1_exp <= c1_v;

      loop
        wait until rising_edge(clk);
        exit when dbg_c1.valid = '1';
      end loop;

      assert std_match(c1_v.cp_off, dbg_c1.cp_off) severity failure;
      assert std_match(c1_v.cp_len, dbg_c1.cp_len) severity failure;
      assert std_match(c1_v.cp_rle, dbg_c1.cp_rle) severity failure;
      assert std_match(c1_v.li_val, dbg_c1.li_val) severity failure;
      assert std_match(c1_v.li_off, dbg_c1.li_off) severity failure;
      assert std_match(c1_v.li_len, dbg_c1.li_len) severity failure;
      assert std_match(c1_v.ld_pop, dbg_c1.ld_pop) severity failure;
      assert std_match(c1_v.last, dbg_c1.last) severity failure;

    end loop;
    file_close(fil);
    wait;
  end process;

  cm_check_proc: process is
    file     fil  : text;
    variable lin  : line;
    variable cm_v : command_stream;
  begin
    file_open(fil, "cm.tv", read_mode);

    wait until reset = '0';
    wait until rising_edge(clk);

    while not endfile(fil) loop

      readline(fil, lin);
      stream_des(lin, cm_v, false);
      dbg_cm_exp <= cm_v;

      loop
        wait until rising_edge(clk);
        exit when dbg_cm.valid = '1';
      end loop;

      assert std_match(cm_v.lt_val, dbg_cm.lt_val) severity failure;
      assert std_match(cm_v.lt_adev, dbg_cm.lt_adev) severity failure;
      assert std_match(cm_v.lt_adod, dbg_cm.lt_adod) severity failure;
      assert std_match(cm_v.lt_swap, dbg_cm.lt_swap) severity failure;
      assert std_match(cm_v.st_addr, dbg_cm.st_addr) severity failure;
      assert std_match(cm_v.cp_rol, dbg_cm.cp_rol) severity failure;
      assert std_match(cm_v.cp_rle, dbg_cm.cp_rle) severity failure;
      assert std_match(cm_v.cp_end, dbg_cm.cp_end) severity failure;
      assert std_match(cm_v.li_rol, dbg_cm.li_rol) severity failure;
      assert std_match(cm_v.li_end, dbg_cm.li_end) severity failure;
      assert std_match(cm_v.ld_pop, dbg_cm.ld_pop) severity failure;
      assert std_match(cm_v.last, dbg_cm.last) severity failure;

    end loop;
    file_close(fil);
    wait;
  end process;

  s1_check_proc: process is
    file     fil  : text;
    variable lin  : line;
    variable s1_v : command_stream;
  begin
    file_open(fil, "cm.tv", read_mode);

    wait until reset = '0';
    wait until rising_edge(clk);

    while not endfile(fil) loop

      readline(fil, lin);
      stream_des(lin, s1_v, false);
      dbg_s1_exp <= s1_v;

      loop
        wait until rising_edge(clk);
        exit when dbg_s1.valid = '1';
      end loop;

      assert std_match(s1_v.lt_val, dbg_s1.lt_val) severity failure;
      assert std_match(s1_v.lt_swap, dbg_s1.lt_swap) severity failure;
      assert std_match(s1_v.st_addr, dbg_s1.st_addr) severity failure;
      assert std_match(s1_v.cp_rol, dbg_s1.cp_rol) severity failure;
      assert std_match(s1_v.cp_rle, dbg_s1.cp_rle) severity failure;
      assert std_match(s1_v.cp_end, dbg_s1.cp_end) severity failure;
      assert std_match(s1_v.li_rol, dbg_s1.li_rol) severity failure;
      assert std_match(s1_v.li_end, dbg_s1.li_end) severity failure;
      assert std_match(s1_v.ld_pop, dbg_s1.ld_pop) severity failure;
      assert std_match(s1_v.last, dbg_s1.last) severity failure;

    end loop;
    file_close(fil);
    wait;
  end process;

end testcase;
