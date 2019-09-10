library std;
use std.textio.all;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

library work;
use work.vhsnunzip_pkg.all;

entity vhsnunzip_pipeline_tc is
end vhsnunzip_pipeline_tc;

architecture testcase of vhsnunzip_pipeline_tc is

  signal clk        : std_logic := '0';
  signal reset      : std_logic := '1';
  signal done       : boolean := false;

  signal co         : compressed_stream_single := COMPRESSED_STREAM_SINGLE_INIT;
  signal co_ready   : std_logic := '0';

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

--       loop
--         uniform(s1, s2, rnd);
--         exit when rnd < 0.5;
--         wait until rising_edge(clk);
--       end loop;

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

--       loop
--         uniform(s1, s2, rnd);
--         exit when rnd < 0.3;
--         wait until rising_edge(clk);
--       end loop;

      readline(fil, lin);
      stream_des(lin, de_v, false);
      de_exp <= de_v;

      de_ready <= '1';
      loop
        wait until rising_edge(clk);
        exit when de.valid = '1';
      end loop;
      de_ready <= '0';

--       for i in 0 to 15 loop
--         assert std_match(de_v.data(i), de.data(i)) severity failure;
--       end loop;
--       assert std_match(de_v.first, de.first) severity failure;
--       assert std_match(de_v.start, de.start) severity failure;
--       assert std_match(de_v.last, de.last) severity failure;
--       assert std_match(de_v.endi, de.endi) severity failure;

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

--     lt_ready <= '0';
-- 
--     loop
--       uniform(s1, s2, rnd);
--       exit when rnd < 0.3;
--       wait until rising_edge(clk);
--     end loop;

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

end testcase;
