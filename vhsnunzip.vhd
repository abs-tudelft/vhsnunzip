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

entity vhsnunzip is
  generic (

    -- The maximum number of data bytes transferred per cycle on the input and
    -- output streams. This must be at least four!
    COUNT_MAX               : natural := 4;

    -- Width of the count field. Must be at least ceil(log2(COUNT_MAX)).
    COUNT_WIDTH             : natural := 2;

    -- Whether a StreamReshaper should be instantiated for the input. If this
    -- is set to false, the input stream is assumed to already be normalized.
    -- That is, if in_last is not set, all COUNT_MAX elements must be valid,
    -- and in_dvalid/in_count are ignored.
    INSERT_RESHAPER         : boolean := true;

    -- Shifts per stage for the reshapers in this unit.
    RESHAPER_SPS            : natural := 3;

    -- The amount and organization of element decoders. Each character
    -- represents a decoder. The characters can be:
    --
    --  - 'L': decoder for short literal elements, which fit in a single input
    --    stream transfer.
    --  - 'C': decoder for copy elements.
    --
    -- There is always an implicit long literal element decoder that can handle
    -- literals that cross input stream transfers. Therefore, the minimal
    -- configuration decode everything is just "C".
    --
    -- Each 'C' character requires block RAM sized by HISTORY_DEPTH_LOG2 to
    -- store the last X bytes of uncompressed data.
    DECODER_CFG             : string := "C";

    -- Depth of the history buffer. The maximum supported offset in copy
    -- elements is 2**HISTORY_DEPTH_LOG2.
    HISTORY_DEPTH_LOG2      : natural := 16;

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

  -- TODO: actually do something!
  out_valid  <= inn_valid;
  inn_ready  <= out_ready;
  out_dvalid <= inn_dvalid;
  out_data   <= inn_data;
  out_count  <= inn_count;
  out_last   <= inn_last;
  out_error  <= '1';

end behavior;
