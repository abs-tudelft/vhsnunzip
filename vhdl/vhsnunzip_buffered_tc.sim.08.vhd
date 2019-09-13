library std;
use std.textio.all;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

library work;
use work.vhsnunzip_int_pkg.all;

entity vhsnunzip_buffered_tc is
  generic (
    RAM_STYLE   : string := "URAM"
  );
end vhsnunzip_buffered_tc;

architecture testcase of vhsnunzip_buffered_tc is

  signal clk          : std_logic := '0';
  signal reset        : std_logic := '1';
  signal done         : boolean := false;

  signal inp          : wide_io_stream := WIDE_IO_STREAM_INIT;
  signal inp_ready    : std_logic := '0';

  signal dbg_co       : compressed_stream_single;
  signal dbg_co_exp   : compressed_stream_single;

  signal dbg_de       : decompressed_stream;
  signal dbg_de_exp   : decompressed_stream;

  signal outp         : wide_io_stream := WIDE_IO_STREAM_INIT;
  signal outp_ready   : std_logic := '0';
  signal outp_exp     : wide_io_stream := WIDE_IO_STREAM_INIT;

  signal out_data_exp : std_logic_vector(255 downto 0) := (others => '0');
  signal out_cnt_exp  : std_logic_vector(4 downto 0) := (others => '0');
  signal out_last_exp : std_logic := '0';

begin

  uut: vhsnunzip_buffered
    generic map (
      RAM_STYLE     => RAM_STYLE
    )
    port map (
      clk           => clk,
      reset         => reset,
      in_valid      => inp.valid,
      in_ready      => inp_ready,
      in_data       => inp.data,
      in_cnt        => inp.cnt,
      in_last       => inp.last,
      dbg_co        => dbg_co,
      dbg_de        => dbg_de,
      out_valid     => outp.valid,
      out_ready     => outp_ready,
      out_data      => outp.data,
      out_cnt       => outp.cnt,
      out_last      => outp.last
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
    variable inp_v : wide_io_stream;
  begin
    file_open(fil, "in.tv", read_mode);
    inp.valid <= '0';

    wait until reset = '0';
    wait until rising_edge(clk);

    while not endfile(fil) loop

      loop
        uniform(s1, s2, rnd);
        exit when rnd < 0.5;
        wait until rising_edge(clk);
      end loop;

      readline(fil, lin);
      stream_des(lin, inp_v, true);

      inp <= inp_v;
      loop
        wait until rising_edge(clk);
        exit when inp_ready = '1';
      end loop;
      inp.valid <= '0';

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
    variable outp_v : wide_io_stream;
  begin
    done <= false;

    file_open(fil, "out.tv", read_mode);
    outp_ready <= '0';

    wait until reset = '0';
    wait until rising_edge(clk);

    while not endfile(fil) loop

      loop
        uniform(s1, s2, rnd);
        exit when rnd < 0.3;
        wait until rising_edge(clk);
      end loop;

      readline(fil, lin);
      stream_des(lin, outp_v, false);
      outp_exp <= outp_v;

      outp_ready <= '1';
      loop
        wait until rising_edge(clk);
        exit when outp.valid = '1';
      end loop;
      outp_ready <= '0';

      assert std_match(outp_v.data, outp.data) severity failure;
      assert std_match(outp_v.last, outp.last) severity failure;
      assert std_match(outp_v.cnt, outp.cnt) severity failure;

    end loop;
    file_close(fil);

    outp_ready <= '1';
    for i in 0 to 100 loop
      wait until rising_edge(clk);
      exit when outp.valid = '1';
    end loop;
    outp_ready <= '0';

    assert outp.valid = '0' report "spurious data!" severity failure;

    done <= true;
    wait;
  end process;

  co_check_proc: process is
    file     fil  : text;
    variable lin  : line;
    variable co_v : compressed_stream_single;
  begin
    file_open(fil, "cs.tv", read_mode);

    wait until reset = '0';
    wait until rising_edge(clk);

    while not endfile(fil) loop

      readline(fil, lin);
      stream_des(lin, co_v, false);
      dbg_co_exp <= co_v;

      loop
        wait until rising_edge(clk);
        exit when dbg_co.valid = '1';
      end loop;

      for i in 0 to 7 loop
        assert std_match(co_v.data(i), dbg_co.data(i)) severity failure;
      end loop;
      assert std_match(co_v.last, dbg_co.last) severity failure;
      assert std_match(co_v.endi, dbg_co.endi) severity failure;

    end loop;
    file_close(fil);
    wait;
  end process;

  de_check_proc: process is
    file     fil  : text;
    variable lin  : line;
    variable de_v : decompressed_stream;
  begin
    file_open(fil, "de.tv", read_mode);

    wait until reset = '0';
    wait until rising_edge(clk);

    while not endfile(fil) loop

      readline(fil, lin);
      stream_des(lin, de_v, false);
      dbg_de_exp <= de_v;

      loop
        wait until rising_edge(clk);
        exit when dbg_de.valid = '1';
      end loop;

      for i in 0 to 7 loop
        assert std_match(de_v.data(i), dbg_de.data(i)) severity failure;
      end loop;
      assert std_match(de_v.last, dbg_de.last) severity failure;
      assert std_match(de_v.cnt, dbg_de.cnt) severity failure;

    end loop;
    file_close(fil);
    wait;
  end process;

end testcase;
