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

-- This unit decompresses a stream of data blocks compressed using the Snappy
-- format, as defined here:
-- https://github.com/google/snappy/blob/master/format_description.txt
--
-- The buffer expects to receive the entire compressed data chunk in the form
-- of a last-delimited stream packet before any result is expected; only when
-- all compressed data has been received, decompression will start. Data
-- will start trickling out of the output stream at this point. However, not
-- accepting the data immediately does not stall decompression, since this
-- buffer can store the entire decompressed block (this is necessary anyway for
-- the Snappy decompression algorithm).
--
-- A single block can decompress at most one byte per cycle. However, because
-- these blocks can handle much faster data bursts, it's possible to
-- parallelize them in round-robin fashion as long as there are many blocks to
-- be decompressed to increase throughput.

entity vhsnunzip is
  generic (

    -- The maximum number of data bytes transferred per cycle on the input and
    -- output streams. This must be a power of two, and must be at least 4.
    COUNT_MAX               : natural := 64;

    -- Width of the count field. Must be at least ceil(log2(COUNT_MAX)).
    COUNT_WIDTH             : natural := 6;

    -- Whether a StreamReshaper should be instantiated for the input. If this
    -- is set to false, the input stream is assumed to already be normalized.
    -- That is, if in_last is not set, all COUNT_MAX elements must be valid,
    -- and in_dvalid/in_count are ignored.
    INSERT_RESHAPER         : boolean := true;

    -- Shifts per stage for the reshapers in this unit.
    RESHAPER_SPS            : natural := 3;

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

    -- Snappy-compressed input stream. Each stream packet represents a block
    -- of Snappy-compressed data as per
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
end vhsnunzip;

architecture behavior of vhsnunzip is

  -- Normalized input stream.
  signal inn_valid          : std_logic;
  signal inn_ready          : std_logic;
  signal inn_dvalid         : std_logic;
  signal inn_data           : std_logic_vector(COUNT_MAX*8-1 downto 0);
  signal inn_count          : std_logic_vector(COUNT_WIDTH-1 downto 0);
  signal inn_last           : std_logic;

begin

  -- Infer the input reshaper.
  with_reshaper: if INSERT_RESHAPER generate
  begin
    reshaper_inst: StreamReshaper
      generic map (
        ELEMENT_WIDTH       => 8,
        IN_COUNT_MAX        => COUNT_MAX,
        IN_COUNT_WIDTH      => COUNT_WIDTH,
        OUT_COUNT_MAX       => COUNT_MAX,
        OUT_COUNT_WIDTH     => COUNT_WIDTH,
        CIN_BUFFER_DEPTH    => 0,
        SHIFTS_PER_STAGE    => RESHAPER_SPS
      )
      port map (
        clk                 => clk,
        reset               => reset,
        din_valid           => in_valid,
        din_ready           => in_ready,
        din_dvalid          => in_dvalid,
        din_data            => in_data,
        din_count           => in_count,
        din_last            => in_last,
        out_valid           => inn_valid,
        out_ready           => inn_ready,
        out_dvalid          => inn_dvalid,
        out_data            => inn_data,
        out_count           => inn_count,
        out_last            => inn_last
      );
  end generate;
  without_reshaper: if not INSERT_RESHAPER generate
  begin
    inn_valid  <= in_valid;
    in_ready   <= inn_ready;
    inn_dvalid <= in_dvalid;
    inn_data   <= in_data;
    inn_count  <= in_count;
    inn_last   <= in_last;
  end generate;

  -- Infer the buffer.
  buffer_inst: entity work.vhsnunzip_buffer
    generic map (
      COUNT_MAX             => COUNT_MAX,
      COUNT_WIDTH           => COUNT_WIDTH,
      DATA_DEPTH_LOG2_BYTES => DATA_DEPTH_LOG2_BYTES,
      RAM_CONFIG            => RAM_CONFIG
    )
    port map (
      clk                   => clk,
      reset                 => reset,
      in_valid              => inn_valid,
      in_ready              => inn_ready,
      in_dvalid             => inn_dvalid,
      in_data               => inn_data,
      in_count              => inn_count,
      in_last               => inn_last,
      out_valid             => out_valid,
      out_ready             => out_ready,
      out_dvalid            => out_dvalid,
      out_data              => out_data,
      out_count             => out_count,
      out_last              => out_last,
      out_error             => out_error
    );

end behavior;
