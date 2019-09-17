library std;
use std.textio.all;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

library work;
use work.vhsnunzip_pkg.all;
use work.vhsnunzip_int_pkg.all;

entity vhsnunzip_tc is
  generic (
    COUNT       : positive := 5;
    B2U_MUL     : natural := 21;
    B2U_DIV     : positive := 10
  );
end vhsnunzip_tc;

architecture testcase of vhsnunzip_tc is

  signal clk          : std_logic := '0';
  signal reset        : std_logic := '1';
  signal done         : boolean := false;

  signal inp          : wide_io_stream := WIDE_IO_STREAM_INIT;
  signal inp_ready    : std_logic := '0';

  signal outp         : wide_io_stream := WIDE_IO_STREAM_INIT;
  signal outp_ready   : std_logic := '0';
  signal outp_exp     : wide_io_stream := WIDE_IO_STREAM_INIT;

  signal out_data_exp : std_logic_vector(255 downto 0) := (others => '0');
  signal out_cnt_exp  : std_logic_vector(4 downto 0) := (others => '0');
  signal out_last_exp : std_logic := '0';

begin

  uut: vhsnunzip
    generic map (
      COUNT         => COUNT,
      B2U_MUL       => B2U_MUL,
      B2U_DIV       => B2U_DIV
    )
    port map (
      clk           => clk,
      reset         => reset,
      in_valid      => inp.valid,
      in_ready      => inp_ready,
      in_data       => inp.data,
      in_cnt        => inp.cnt,
      in_last       => inp.last,
      out_valid     => outp.valid,
      out_dvalid    => outp.dvalid,
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
    variable t    : real := 0.0;
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
        exit when rnd < sin(t) * 0.7 + 0.5;
        t := t + 0.0001;
        wait until rising_edge(clk);
      end loop;

      readline(fil, lin);
      stream_des(lin, inp_v, true);

      inp <= inp_v;
      loop
        t := t + 0.0001;
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
    variable t    : real := 0.0;
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
        exit when rnd < cos(t) * 0.7 + 0.5;
        t := t + 0.00012;
        wait until rising_edge(clk);
      end loop;

      readline(fil, lin);
      stream_des(lin, outp_v, false);
      outp_exp <= outp_v;

      outp_ready <= '1';
      loop
        t := t + 0.00012;
        wait until rising_edge(clk);
        exit when outp.valid = '1';
      end loop;
      outp_ready <= '0';

      assert std_match(outp_v.dvalid, outp.dvalid) severity failure;
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

end testcase;
