library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.vhsnunzip_pkg.all;

-- Streaming toplevel for vhsnunzip. This version of the decompressor doesn't
-- include any large-scale input and output stream buffering, so the streams
-- are limited to the speed of the decompression engine.
entity vhsnunzip_streaming is
  generic (

    -- This block can use either 2 UltraRAMs or 16 Xilinx 36k block RAMs.
    -- Select "URAM" for UltraRAMs or "BRAM" for block RAMs.
    RAM_STYLE   : string := "URAM"

  );
  port (
    clk         : in  std_logic;
    reset       : in  std_logic;

    -- Compressed input stream. Each last-delimited packet is interpreted as a
    -- chunk of Snappy data as described by:
    --
    --   https://github.com/google/snappy/blob/
    --     b61134bc0a6a904b41522b4e5c9e80874c730cef/format_description.txt
    --
    -- This unit is designed for chunks of up to and including 64kiB
    -- uncompressed size, but as long as the maximum literal length is 64kiB
    -- (i.e. 4- and 5-byte literal headers are not used), the compression
    -- window size is limited to 64kiB (i.e. all copy offsets are 64kiB-1 or
    -- lower), this block should work for sizes up to 2MiB-1 (after this, the
    -- decompressed size header grows beyond 3 bytes). Violating these rules
    -- results in garbage at the output, but should not cause lasting problems,
    -- so the next chunk should be decompressed correctly again.
    --
    -- The input stream must be normalized; that is, all 8 bytes must be valid
    -- for all but the last transfer, and the last transfer must contain at
    -- least one byte. The number of valid bytes is indicated by cnt; 8 valid
    -- bytes is represented as 0 (implicit MSB). The LSB of the first transfer
    -- corresponds to the first byte in the chunk. This is compatible with the
    -- stream library components in vhlib.
    co_valid    : in  std_logic;
    co_ready    : out std_logic;
    co_data     : in  std_logic_vector(63 downto 0);
    co_cnt      : in  std_logic_vector(2 downto 0);
    co_last     : in  std_logic;

    -- Decompressed output stream. Like the input stream, this stream is
    -- normalized.
    de_valid    : out std_logic;
    de_ready    : in  std_logic;
    de_data     : out std_logic_vector(63 downto 0);
    de_cnt      : out std_logic_vector(2 downto 0);
    de_last     : out std_logic

  );
end vhsnunzip_streaming;

architecture behavior of vhsnunzip_streaming is

  -- RAM interface signals.
  signal ev_wr_cmd  : ram_command;
  signal ev_rd_cmd  : ram_command;
  signal ev_rd_resp : ram_response;
  signal od_wr_cmd  : ram_command;
  signal od_rd_cmd  : ram_command;
  signal od_rd_resp : ram_response;

begin

  -- RAM containing the even 8-byte lines of decompression history.
  ram_even_inst: vhsnunzip_ram
    generic map (
      RAM_STYLE => RAM_STYLE
    )
    port map (
      clk       => clk,
      a_cmd     => ev_wr_cmd,
      a_resp    => open,
      b_cmd     => ev_rd_cmd,
      b_resp    => ev_rd_resp
    );

  -- RAM containing the odd 8-byte lines of decompression history.
  ram_idd_inst: vhsnunzip_ram
    generic map (
      RAM_STYLE => RAM_STYLE
    )
    port map (
      clk       => clk,
      a_cmd     => od_wr_cmd,
      a_resp    => open,
      b_cmd     => od_rd_cmd,
      b_resp    => od_rd_resp
    );

end behavior;
