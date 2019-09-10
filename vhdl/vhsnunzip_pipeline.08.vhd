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

    -- Long-term storage first line offset. Must be loaded by strobing ld
    -- for each chunk before chunk processing will start. Alternatively, in
    -- streaming mode with circular history, this can be left unconnected.
    lt_off_ld   : in  std_logic := '1';
    lt_off      : in  unsigned(12 downto 0) := (others => '0');

    -- TODO
    cm          : out command_stream;
    cm_ready    : in  std_logic

  );
end vhsnunzip_pipeline;

architecture structure of vhsnunzip_pipeline is

  signal co_ctrl  : std_logic_vector(3 downto 0);

  signal cs       : compressed_stream_single;
  signal cs_ready : std_logic;
  signal cs_ctrl  : std_logic_vector(3 downto 0);

  signal cd       : compressed_stream_double;
  signal cd_ready : std_logic;

  signal el       : element_stream;
  signal el_ready : std_logic;

  signal c1       : partial_command_stream;
  signal c1_ready : std_logic;

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

  cmd_gen_1_inst: vhsnunzip_cmd_gen_1
    port map (
      clk         => clk,
      reset       => reset,
      el          => el,
      el_ready    => el_ready,
      c1          => c1,
      c1_ready    => c1_ready
    );

  cmd_gen_2_inst: vhsnunzip_cmd_gen_2
    port map (
      clk         => clk,
      reset       => reset,
      c1          => c1,
      c1_ready    => c1_ready,
      lt_off_ld   => lt_off_ld,
      lt_off      => lt_off,
      cm          => cm,
      cm_ready    => cm_ready
    );

end structure;
