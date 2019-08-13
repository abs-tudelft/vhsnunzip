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

  clkgen: ClockGen_mdl
    port map (
      clk                       => clk,
      reset                     => reset
    );

  in_source: StreamSource_mdl
    generic map (
      NAME                      => "in",
      ELEMENT_WIDTH             => 8,
      COUNT_MAX                 => COUNT_MAX,
      COUNT_WIDTH               => COUNT_WIDTH
    )
    port map (
      clk                       => clk,
      reset                     => reset,
      valid                     => in_valid,
      ready                     => in_ready,
      dvalid                    => in_dvalid,
      data                      => in_data,
      count                     => in_count,
      last                      => in_last
    );

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

  out_sink: StreamSink_mdl
    generic map (
      NAME                      => "out",
      ELEMENT_WIDTH             => 8,
      COUNT_MAX                 => COUNT_MAX,
      COUNT_WIDTH               => COUNT_WIDTH,
      CTRL_WIDTH                => 1
    )
    port map (
      clk                       => clk,
      reset                     => reset,
      valid                     => out_valid,
      ready                     => out_ready,
      dvalid                    => out_dvalid,
      data                      => out_data,
      count                     => out_count,
      last                      => out_last,
      ctrl(0)                   => out_error
    );

end testbench;
