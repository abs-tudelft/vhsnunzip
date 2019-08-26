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

  -- Main state of the state machine.
  type state_enum is (

    -- Idle; we're not currently decompressing anything.
    S_IDLE,

    -- Busy; we're decompressing a chunk.
    S_BUSY,

    -- Last input transfer has been received. We need to shift in one more
    -- transfer's worth of dummy data since we have a sliding window.
    S_LAST,

    -- Error; we tried decompressing something, but something went so wrong
    -- that we can't continue. We've already sent the last output transfer with
    -- the error indicator, so now we're basically just waiting for the last
    -- input transfer so we can reset.
    S_ERROR
  );

  type std_logic_array is array (natural range <>) of std_logic;
  type byte_array is array (natural range <>) of std_logic_vector(7 downto 0);
  type count_array is array (natural range <>) of unsigned(COUNT_WIDTH downto 0);

  -- Basic element header information needed to decode and distribute the
  -- elements over the decoders.
  type element_info_type is record

    -- When set, the element is a copy element. Otherwise, it's a literal.
    copy  : std_logic;

    -- Indicates that this is a long literal, i.e. one that wraps over into
    -- subsequent input stream transfers. In this case, len is invalid.
    long  : std_logic;

    -- Uncompressed length of the elements in bytes, unless long is set.
    len   : unsigned(COUNT_WIDTH downto 0);

  end record;
  type element_info_array is array (natural range <>) of element_info_type;

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

    -- Compressed data window. This comprises two input stream transfers, which
    -- are shifted right every time a new input transfer is inserted.
    win_valid     : std_logic_array(0 to 1);
    win_data      : byte_array(0 to 2*COUNT_MAX-1);
    win_count     : count_array(0 to 1);
    win_last      : std_logic_array(0 to 1);

    -- Decoded element info for each position in win.
    el_info       : element_info_array(0 to COUNT_MAX - 1);

    -- Output stream holding register.
    outh_valid    : std_logic;
    outh_data     : std_logic_vector(COUNT_MAX*8-1 downto 0);
    outh_count    : unsigned(COUNT_WIDTH downto 0);
    outh_last     : std_logic;
    outh_error    : std_logic;

  end record;
  -- pragma translate_off
  signal s_sig              : state_type;
  -- pragma translate_on

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

  main_proc: process (clk) is
    variable s : state_type;
  begin
    if rising_edge(clk) then

      -- Manage the stream <-> holding register connection.
      if s.inh_valid = '0' then
        s.inh_valid := inn_valid;
        s.inh_data  := inn_data;
        s.inh_count := unsigned(resize_count(inn_count, COUNT_WIDTH+1));
        s.inh_last  := inn_last;
        if inn_dvalid = '0' then
          s.inh_count := (others => '0');
        end if;
      end if;
      if out_ready = '1' then
        s.outh_valid := '0';
      end if;

      -- Stage 1: shift the input holding register into the window.
      if s.win_valid(0) = '0' and ((s.win_last(1) and s.win_valid(1)) = '1' or s.inh_valid = '1') then
        s.win_valid(0) := s.win_valid(1);
        s.win_data(0 to COUNT_MAX-1) := s.win_data(COUNT_MAX to 2*COUNT_MAX-1);
        s.win_count(0) := s.win_count(1);
        s.win_last(0) := s.win_last(1);

        for i in 0 to COUNT_MAX - 1 loop
          s.win_data(COUNT_MAX + i) := s.inh_data(i*8+7 downto i*8);
        end loop;
        s.win_count(1) := s.inh_count;
        if s.win_last(1) = '0' then
          s.win_valid(1) := '1';
          s.win_last(1) := s.inh_last;
          s.inh_valid := '0';
        else
          s.win_valid(1) := '0';
          s.win_last(1) := '0';
        end if;
      end if;

      -- TODO: actually do something!
      if s.win_valid(0) = '1' and s.outh_valid = '0' then
        s.outh_valid := '1';
        for i in 0 to COUNT_MAX - 1 loop
          s.outh_data(i*8+7 downto i*8) := s.win_data(i);
        end loop;
        s.outh_count := s.win_count(0);
        s.outh_last := s.win_last(0);
        s.outh_error := '1';
        s.win_valid(0) := '0';
      end if;

      -- Manage the stream <-> holding register connection.
      inn_ready <= not s.inh_valid;
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
        s.win_valid   := (others => '0');
      end if;

      -- Assign the state signal to be able to see what's going on in sims that
      -- can't trace variables.
      -- pragma translate_off
      s_sig <= s;
      -- pragma translate_on
    end if;
  end process;

end behavior;
