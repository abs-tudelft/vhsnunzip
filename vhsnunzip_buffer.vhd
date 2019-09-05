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

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.Stream_pkg.all;
use work.UtilInt_pkg.all;

-- This unit acts as a data buffer for the Snappy decompression core.
--
-- The buffer expects to receive the entire compressed data chunk in the form
-- of a last-delimited stream packet before any result is expected. It does
-- this to determine the compressed and decompressed lengths, which it uses to
-- figure out whether the buffer is large enough, and where the decompressed
-- data should be buffered relative to the compressed data.
--
-- Once all compressed data has been received, decompression will start. Data
-- will start trickling out of the output stream at this point. However, not
-- accepting the data immediately does not stall decompression, since this
-- buffer can store the entire decompressed block (this is necessary anyway for
-- the Snappy decompression algorithm).

entity vhsnunzip_buffer is
  generic (

    -- The maximum number of data bytes transferred per cycle on the input and
    -- output streams. This must be a power of two, and must be at least 4.
    COUNT_MAX               : natural := 64;

    -- Width of the count field. Must be at least ceil(log2(COUNT_MAX)).
    COUNT_WIDTH             : natural := 6;

    -- Depth of the data buffer. This buffer must be able to store the
    -- data decompressed so far and the remaining compressed data at all times,
    -- with a little overhead on top due to line sizes. A 1R1W RAM is inferred
    -- based on this depth, COUNT_MAX bits wide on both ports.
    DATA_DEPTH_LOG2_BYTES   : natural := 17;

    -- RAM configuration parameter. Passed to the UtilRam1R1W instances.
    RAM_CONFIG              : string := ""

  );
  port (
    clk                     : in  std_logic;
    reset                   : in  std_logic;

    -- Snappy-compressed input stream. This stream must be normalized. Each
    -- stream packet represents a block of Snappy-compressed data as per
    -- https://github.com/google/snappy/blob/master/format_description.txt
    in_valid                : in  std_logic;
    in_ready                : out std_logic;
    in_dvalid               : in  std_logic;
    in_data                 : in  std_logic_vector(COUNT_MAX*8-1 downto 0);
    in_count                : in  std_logic_vector(COUNT_WIDTH-1 downto 0);
    in_last                 : in  std_logic;

    -- Decompressed output stream. This stream is normalized. Each packet on
    -- the input stream corresponds with a packet on the output stream.
    -- out_error is asserted when a decoding error occurs, and cleared again
    -- after the last transfer.
    out_valid               : out std_logic;
    out_ready               : in  std_logic;
    out_dvalid              : out std_logic;
    out_data                : out std_logic_vector(COUNT_MAX*8-1 downto 0);
    out_count               : out std_logic_vector(COUNT_WIDTH-1 downto 0);
    out_last                : out std_logic;
    out_error               : out std_logic

  );
end vhsnunzip_buffer;

architecture behavior of vhsnunzip_buffer is

  -- Compute some useful constants for the buffer RAM.
  constant BUF_WIDTH_BYTE   : natural := COUNT_MAX;
  constant BUF_WIDTH_BIT    : natural := BUF_WIDTH_BYTE * 8;
  constant BUF_WIDTH_LOG2   : natural := log2ceil(BUF_WIDTH_BYTE);
  constant BUF_DEPTH_LOG2   : natural := DATA_DEPTH_LOG2_BYTES - BUF_WIDTH_LOG2;
  constant BUF_DEPTH_LINE   : natural := 2**BUF_DEPTH_LOG2;

  -- Main state of the state machine.
  type state_enum is (

    -- Idle; we're not currently decompressing anything. Alternatively put,
    -- we're waiting for the first decompressed line in the stream.
    S_IDLE,

    -- We're reading the compressed block into the buffer and are waiting for
    -- the last line.
    S_INPUT,

    -- We're decompressing.
    S_BUSY
  );

  -- This unit is primarily built up using single-process methedology. While
  -- this means that the state could be stored in variables only, many
  -- simulators can't trace these; so we put them in a record and assign the
  -- signal to the variables at the end of each cycle.
  type state_type is record

    -- Input stream holding register.
    inh_valid     : std_logic;
    inh_data      : std_logic_vector(COUNT_MAX*8-1 downto 0);
    inh_count     : unsigned(COUNT_WIDTH downto 0);
    inh_last      : std_logic;

    -- Output stream holding register.
    outh_valid    : std_logic;
    outh_data     : std_logic_vector(COUNT_MAX*8-1 downto 0);
    outh_count    : unsigned(COUNT_WIDTH downto 0);
    outh_last     : std_logic;
    outh_error    : std_logic;

    -- Compressed data line pointers. The compressed data block always starts
    -- at line 0 and grows upwards. The write pointer points to the line that
    -- is to be written next, and the read pointer points to the line that is
    -- to be read next.
    comp_ptr_wr   : unsigned(BUF_DEPTH_LOG2 - 1 downto 0);
    comp_ptr_rd   : unsigned(BUF_DEPTH_LOG2 - 1 downto 0);

  end record;
  -- pragma translate_off
  signal s_sig              : state_type;
  -- pragma translate_on

begin

  assert COUNT_MAX >= 4
    report "COUNT_MAX must be at least 4" severity failure;
  assert log2ceil(COUNT_MAX) = log2floor(COUNT_MAX)
    report "COUNT_MAX must be a power of two" severity failure;

  main_proc: process (clk) is
    variable s : state_type;
  begin
    if rising_edge(clk) then

      -- Manage the stream <-> holding register connection.
      if s.inh_valid = '0' then
        s.inh_valid := in_valid;
        s.inh_data  := in_data;
        s.inh_count := unsigned(resize_count(in_count, COUNT_WIDTH+1));
        s.inh_last  := in_last;
        if in_dvalid = '0' then
          s.inh_count := (others => '0');
        end if;
      end if;
      if out_ready = '1' then
        s.outh_valid := '0';
      end if;

      -- TODO: actually do something!
      if s.inh_valid = '1' and s.outh_valid = '0' then
        s.outh_valid := '1';
        s.outh_data := s.inh_data;
        s.outh_count := s.inh_count;
        s.outh_last := s.inh_last;
        s.outh_error := '0';
        s.inh_valid := '0';
      end if;

      -- Manage the stream <-> holding register connection.
      in_ready <= not s.inh_valid;
      out_valid <= s.outh_valid;
      if s.outh_count = 0 then
        out_dvalid <= '0';
      else
        out_dvalid <= '1';
      end if;
      out_data  <= s.outh_data;
      out_count <= std_logic_vector(s.outh_count(COUNT_WIDTH-1 downto 0));
      out_last  <= s.outh_last;
      out_error <= s.outh_error;

      -- Handle reset.
      if reset = '1' then
        s.inh_valid   := '0';
        s.outh_valid  := '0';
      end if;

      -- Assign the state signal to be able to see what's going on in sims that
      -- can't trace variables.
      -- pragma translate_off
      s_sig <= s;
      -- pragma translate_on
    end if;
  end process;

end behavior;
