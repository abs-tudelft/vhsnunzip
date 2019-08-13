-- Copyright 2019 Delft University of Technology
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

library std;
use std.textio.all;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;

library work;
use work.Stream_pkg.all;
use work.UtilInt_pkg.all;
use work.ClockGen_pkg.all;
use work.StreamSource_pkg.all;
use work.StreamMonitor_pkg.all;
use work.StreamSink_pkg.all;

entity vhsnunzip_tb is
  generic (

    -- The maximum number of bytes transferred per cycle.
    BYTES_PER_CYCLE         : natural := 4;

    -- Decoder configuration, see vhsnunzip.
    DECODER_CFG             : string := "C";

    -- Depth of the history buffer. The maximum supported offset in copy
    -- elements is 2**HISTORY_DEPTH_LOG2.
    HISTORY_DEPTH_LOG2      : natural := 16

  );
end vhsnunzip_tb;

architecture testbench of vhsnunzip_tb is

  constant COUNT_MAX            : natural := BYTES_PER_CYCLE;
  constant COUNT_WIDTH          : natural := log2ceil(BYTES_PER_CYCLE);
  constant INSERT_RESHAPER      : boolean := true;
  constant RESHAPER_SPS         : natural := 3;
  constant RAM_CONFIG           : string := "";

  signal done                   : boolean := false;

  signal clk                    : std_logic;
  signal reset                  : std_logic;

  signal in_valid               : std_logic;
  signal in_ready               : std_logic;
  signal in_dvalid              : std_logic;
  signal in_data                : std_logic_vector(COUNT_MAX*8-1 downto 0);
  signal in_count               : std_logic_vector(COUNT_WIDTH-1 downto 0);
  signal in_last                : std_logic;

  signal out_valid              : std_logic;
  signal out_ready              : std_logic;
  signal out_dvalid             : std_logic;
  signal out_data               : std_logic_vector(COUNT_MAX*8-1 downto 0);
  signal out_count              : std_logic_vector(COUNT_WIDTH-1 downto 0);
  signal out_last               : std_logic;
  signal out_error              : std_logic;

begin

  clk_proc: process is
  begin
    while not done loop
      wait for 5 ns;
      clk <= '0';
      wait for 5 ns;
      clk <= '1';
    end loop;
    wait;
  end process;

  reset_proc: process is
  begin
    reset <= '1';
    for i in 0 to 9 loop
      wait until rising_edge(clk);
    end loop;
    reset <= '0';
    wait;
  end process;

  input_proc: process is
    constant COUNT_MAX_SLV  : std_logic_vector(COUNT_WIDTH-1 downto 0)
                            := std_logic_vector(to_unsigned(COUNT_MAX, COUNT_WIDTH));
    file infile             : text;
    variable inline         : line;
    variable count          : natural := 0;
    variable data           : std_logic_vector(7 downto 0);
  begin
    in_valid  <= '0';
    in_dvalid <= '1';
    in_data   <= (others => '0');
    in_count  <= COUNT_MAX_SLV;
    in_last   <= '0';
    wait until falling_edge(reset);
    wait until rising_edge(clk);
    file_open(infile, "input.txt", read_mode);
    while not endfile(infile) loop
      in_dvalid <= '1';
      in_data   <= (others => '0');
      in_count  <= COUNT_MAX_SLV;
      in_last   <= '0';
      count := 0;
      while count < COUNT_MAX loop
        readline(infile, inline);
        if inline.all = "" then
          in_count <= std_logic_vector(to_unsigned(count, COUNT_WIDTH));
          if count = 0 then
            in_dvalid <= '0';
          else
            in_dvalid <= '1';
          end if;
          in_last <= '1';
          exit;
        else
          read(inline, data);
          in_data(count*8+7 downto count*8) <= data;
          count := count + 1;
        end if;
      end loop;
      in_valid <= '1';
      loop
        wait until rising_edge(clk);
        exit when in_ready = '1';
      end loop;
      in_valid <= '0';
    end loop;
    file_close(infile);
    in_valid <= '0';
    wait for 100 us;
    done <= true;
    wait;
  end process;

  output_proc: process is
    file outfile            : text;
    variable outline        : line;
    variable count          : natural := 0;
    variable data           : std_logic_vector(7 downto 0);
  begin
    out_ready <= '0';
    wait until falling_edge(reset);
    wait until rising_edge(clk);
    file_open(outfile, "output.txt", write_mode);
    loop
      out_ready <= '1';
      loop
        wait until rising_edge(clk);
        exit when out_valid = '1';
      end loop;
      out_ready <= '0';

      count := to_integer(unsigned(out_count));
      if count = 0 then
        count := COUNT_MAX;
      end if;
      if out_dvalid = '0' then
        count := 0;
      end if;
      for i in 0 to count - 1 loop
        write(outline, in_data(i*8+7 downto i*8));
        writeline(outfile, outline);
      end loop;
      if out_last = '1' then
        if out_error = '1' then
          write(outline, string'("error"));
        end if;
        writeline(outfile, outline);
      else
        assert count = COUNT_MAX report "output not normalized" severity failure;
      end if;
    end loop;
  end process;

  out_ready <= '1';

  uut: entity work.vhsnunzip
    generic map (
      COUNT_MAX                 => COUNT_MAX,
      COUNT_WIDTH               => COUNT_WIDTH,
      INSERT_RESHAPER           => INSERT_RESHAPER,
      RESHAPER_SPS              => RESHAPER_SPS,
      DECODER_CFG               => DECODER_CFG,
      HISTORY_DEPTH_LOG2        => HISTORY_DEPTH_LOG2,
      RAM_CONFIG                => RAM_CONFIG
    )
    port map (
      clk                       => clk,
      reset                     => reset,
      in_valid                  => in_valid,
      in_ready                  => in_ready,
      in_dvalid                 => in_dvalid,
      in_data                   => in_data,
      in_count                  => in_count,
      in_last                   => in_last,
      out_valid                 => out_valid,
      out_ready                 => out_ready,
      out_dvalid                => out_dvalid,
      out_data                  => out_data,
      out_count                 => out_count,
      out_last                  => out_last,
      out_error                 => out_error
    );

end testbench;
