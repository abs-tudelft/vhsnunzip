library std;
use std.textio.all;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

library work;
use work.vhsnunzip_int_pkg.all;
use work.vhsnunzip_pkg.all;

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

  signal co_valid     : std_logic := '0';
  signal co_ready     : std_logic := '0';
  signal co_data      : std_logic_vector(255 downto 0) := (others => '0');
  signal co_cnt       : std_logic_vector(4 downto 0) := (others => '0');
  signal co_last      : std_logic := '0';

  signal de_valid     : std_logic := '0';
  signal de_ready     : std_logic := '0';
  signal de_data      : std_logic_vector(255 downto 0) := (others => '0');
  signal de_cnt       : std_logic_vector(4 downto 0) := (others => '0');
  signal de_last      : std_logic := '0';

  signal de_data_exp  : std_logic_vector(255 downto 0) := (others => '0');
  signal de_cnt_exp   : std_logic_vector(4 downto 0) := (others => '0');
  signal de_last_exp  : std_logic := '0';

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
      in_valid      => co_valid,
      in_ready      => co_ready,
      in_data       => co_data,
      in_cnt        => co_cnt,
      in_last       => co_last,
      out_valid     => de_valid,
      out_ready     => de_ready,
      out_data      => de_data,
      out_cnt       => de_cnt,
      out_last      => de_last
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

      co_data <= (others => 'U');
      co_cnt  <= (others => '0');
      co_last <= '0';
      for idx in 0 to 3 loop
        readline(fil, lin);
        stream_des(lin, co_v, true);
        for byte in 0 to 7 loop
          co_data(idx*64+byte*8+7 downto idx*64+byte*8) <= co_v.data(byte);
        end loop;
        if co_v.last = '1' then
          co_cnt <= std_logic_vector(resize(co_v.endi, 5) + 1 + idx*8);
          co_last <= '1';
          exit;
        end if;
      end loop;

      co_valid <= '1';
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

    readline(fil, lin);
    stream_des(lin, de_v, true);

    while not endfile(fil) loop

      loop
        uniform(s1, s2, rnd);
        exit when rnd < 0.3;
        wait until rising_edge(clk);
      end loop;

      de_data_exp <= (others => '-');
      de_cnt_exp  <= (others => '0');
      de_last_exp <= '0';
      for idx in 0 to 3 loop
        for byte in 0 to 7 loop
          de_data_exp(idx*64+byte*8+7 downto idx*64+byte*8) <= de_v.data(byte);
        end loop;
        if de_v.last = '1' then
          de_cnt_exp <= std_logic_vector(resize(de_v.cnt, 5) + idx*8);
          de_last_exp <= '1';
          exit;
        end if;
        readline(fil, lin);
        stream_des(lin, de_v, true);
      end loop;
      if de_v.last = '1' and de_v.cnt = "0000" then
        de_last_exp <= '1';
        readline(fil, lin);
        stream_des(lin, de_v, true);
      end if;

      de_ready <= '1';
      loop
        wait until rising_edge(clk);
        exit when de_valid = '1';
      end loop;
      de_ready <= '0';

      assert std_match(de_data_exp, de_data) severity failure;
      assert std_match(de_last_exp, de_last) severity failure;
      assert std_match(de_cnt_exp, de_cnt) severity failure;

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
