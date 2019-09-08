library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.vhsnunzip_pkg.all;

-- Snappy decompression pipeline.
entity vhsnunzip_pipeline is
  port (
    clk         : in  std_logic;
    reset       : in  std_logic;

    -- Compressed data input stream.
    co          : in  compressed_stream_single;
    co_ready    : out std_logic;
    co_level    : out unsigned(5 downto 0);

    -- TODO
    el          : out element_stream;
    el_ready    : in  std_logic

  );
end vhsnunzip_pipeline;

architecture structure of vhsnunzip_pipeline is

  signal co_ctrl  : std_logic_vector(3 downto 0);

  signal cs       : compressed_stream_single;
  signal cs_ready : std_logic;
  signal cs_ctrl  : std_logic_vector(3 downto 0);

  signal cd       : compressed_stream_double;
  signal cd_ready : std_logic;

begin

  co_ctrl(0) <= co.last;
  co_ctrl(3 downto 1) <= std_logic_vector(co.endi);

  cs_fifo_inst: vhsnunzip_fifo
    generic map (
      DATA_WIDTH  => 8,
      CTRL_WIDTH  => 4
    )
    port map (
      clk         => clk,
      reset       => reset,
      wr_valid    => co.valid,
      wr_ready    => co_ready,
      wr_data     => co.data,
      wr_ctrl     => co_ctrl,
      rd_valid    => cs.valid,
      rd_ready    => cs_ready,
      rd_data     => cs.data,
      rd_ctrl     => cs_ctrl,
      level       => co_level
    );

  cs.last <= cs_ctrl(0);
  cs.endi <= unsigned(cs_ctrl(3 downto 1));

  pre_dec_inst: vhsnunzip_pre_decoder
    port map (
      clk         => clk,
      reset       => reset,
      cs          => cs,
      cs_ready    => cs_ready,
      cd          => cd,
      cd_ready    => cd_ready
    );

  main_dec_inst: vhsnunzip_decoder
    port map (
      clk         => clk,
      reset       => reset,
      cd          => cd,
      cd_ready    => cd_ready,
      el          => el,
      el_ready    => el_ready
    );

end structure;
