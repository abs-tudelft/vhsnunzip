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
use work.vhsnunzip_pkg.all;

entity vhsnunzip_tb is
  generic (
    DUMMY: boolean := false
  );
end vhsnunzip_tb;

architecture testbench of vhsnunzip_tb is

  signal done       : boolean := false;

  signal clk        : std_logic;
  signal reset      : std_logic;

  signal co_valid   : std_logic;
  signal co_ready   : std_logic;
  signal co_data    : byte_array(0 to 15);
  signal co_first   : std_logic;
  signal co_start   : std_logic_vector(3 downto 0);
  signal co_last    : std_logic;
  signal co_end     : std_logic_vector(3 downto 0);

  signal de_valid   : std_logic;
  signal de_data    : byte_array(0 to 15);
  signal de_last    : std_logic;

  signal hia_valid  : std_logic;
  signal hia_ready  : std_logic;
  signal hia_addr   : std_logic_vector(11 downto 0);

  signal hir_valid  : std_logic;
  signal hir_data   : byte_array(0 to 31);

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
    file infile             : text;
    variable inline         : line;
    variable count          : natural := 0;
    variable data           : std_logic_vector(7 downto 0);
    variable page_open      : boolean := false;
    variable last           : boolean := false;
  begin
    co_valid  <= '0';
    co_data   <= (others => X"00");
    co_first  <= '0';
    co_start  <= "0000";
    co_last   <= '0';
    co_end    <= "1111";
    wait until falling_edge(reset);
    wait until rising_edge(clk);
    file_open(infile, "input.txt", read_mode);
    while not endfile(infile) loop
      co_data <= (others => X"00");
      co_first <= '0';
      co_start <= "0000";
      co_last <= '0';
      co_end <= "1111";
      last := false;

      count := 0;
      while count < 16 loop
        readline(infile, inline);

        -- Handle "last" marker.
        if inline.all = "last:" then
          co_last <= '1';
          co_end <= std_logic_vector(to_unsigned(count, 4));
          page_open := false;
          last := true;
          readline(infile, inline);
        end if;

        -- Read data.
        read(inline, data);
        co_data(count) <= data;
        count := count + 1;

        -- Read the empty line at the end of a block.
        if last then
          readline(infile, inline);
          assert inline.all = "" severity failure;
          exit;
        end if;

        -- Start one byte after the first byte with zero LSB.
        if not page_open and data(7) = '0' then
          co_first <= '1';
          co_start <= std_logic_vector(to_unsigned(count, 4));
          page_open := true;
        end if;

      end loop;

      co_valid <= '1';
      loop
        wait until rising_edge(clk);
        exit when co_ready = '1';
      end loop;
      co_valid <= '0';
    end loop;
    file_close(infile);
    co_valid <= '0';
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
    wait until falling_edge(reset);
    wait until rising_edge(clk);
    file_open(outfile, "output.txt", write_mode);
    loop

      loop
        wait until rising_edge(clk);
        exit when de_valid = '1';
      end loop;

      for i in 0 to 15 loop
        write(outline, de_data(i));
        writeline(outfile, outline);
      end loop;

      if de_last = '1' then
        --if de_error = '1' then
        --  write(outline, string'("error"));
        --end if;
        writeline(outfile, outline);
      end if;

    end loop;
  end process;

  uut: entity work.vhsnunzip_decode
    port map (
      clk       => clk,
      reset     => reset,

      co_valid  => co_valid,
      co_ready  => co_ready,
      co_data   => co_data,
      co_first  => co_first,
      co_start  => co_start,
      co_last   => co_last,
      co_end    => co_end,

      de_valid  => de_valid,
      de_data   => de_data,
      de_last   => de_last,

      hia_valid => hia_valid,
      hia_ready => hia_ready,
      hia_addr  => hia_addr,

      hir_valid => hir_valid,
      hir_data  => hir_data

    );

end testbench;
