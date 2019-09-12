library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.vhsnunzip_int_pkg.all;

-- Buffered toplevel for a single vhsnunzip core. This version of the
-- decompressor uses the RAMs needed for long-term decompression history
-- storage for input/output FIFOs as well. This allows the data to be pumped
-- in using a much wider bus (32-byte) and without stalling. However, the
-- 32 bytes per cycle bandwidth is the full bandwidth of the instantiated
-- memory, so decompression will typically not start until a full chunk has
-- been received if there are no stalls in the input stream, which means
-- latency and overall throughput will be worse than the unbuffered design.
entity vhsnunzip_buffered is
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
    in_valid    : in  std_logic;
    in_ready    : out std_logic;
    in_data     : in  std_logic_vector(255 downto 0);
    in_cnt      : in  std_logic_vector(4 downto 0);
    in_last     : in  std_logic;

    -- Decompressed output stream. This stream is normalized.
    out_valid   : out std_logic;
    out_ready   : in  std_logic;
    out_data    : out std_logic_vector(255 downto 0);
    out_cnt     : out std_logic_vector(4 downto 0);
    out_last    : out std_logic

  );
end vhsnunzip_buffered;

architecture behavior of vhsnunzip_buffered is

  -- Pipeline interface signals.
  signal co             : compressed_stream_single;
  signal co_ready       : std_logic;
  signal co_level       : unsigned(5 downto 0);
  signal lt_off_ld      : std_logic := '1';
  signal lt_off         : unsigned(12 downto 0) := (others => '0');
  signal lt_rd_valid    : std_logic;
  signal lt_rd_ready    : std_logic := '1';
  signal lt_rd_adev     : unsigned(11 downto 0);
  signal lt_rd_adod     : unsigned(11 downto 0);
  signal lt_rd_next     : std_logic;
  signal lt_rd_even     : byte_array(0 to 7);
  signal lt_rd_odd      : byte_array(0 to 7);
  signal de             : decompressed_stream;
  signal de_ready       : std_logic;
  signal de_level       : unsigned(5 downto 0);

  -- Memory access request and response signals, before arbitration. Any of the
  -- first four requests can be handled at the same time as any of the last
  -- four requests.

  -- Data input buffer write ports. Can be handled at the same time.
  signal in_mreq        : ram_request_array(0 to 1);
  signal in_mreq_ready  : std_logic_array(0 to 1);
  signal in_mresp       : ram_response_pair_array(0 to 1);

  -- Data output buffer read ports. Can be handled at the same time.
  signal out_mreq       : ram_request_array(0 to 1);
  signal out_mreq_ready : std_logic_array(0 to 1);
  signal out_mresp      : ram_response_pair_array(0 to 1);

  -- Compressed data read port.
  signal co_mreq        : ram_request;
  signal co_mreq_ready  : std_logic;
  signal co_mresp       : ram_response_pair;

  -- Decompressed data write port.
  signal de_mreq        : ram_request;
  signal de_mreq_ready  : std_logic;
  signal de_mresp       : ram_response_pair;

  -- Long-term memory read port.
  signal lt_mreq        : ram_request;
  signal lt_mreq_ready  : std_logic;
  signal lt_mresp       : ram_response_pair;

  -- "cannot associate individually with open", thanks VHDL.
  signal unused_ready   : std_logic;
  signal unused_resp    : ram_response_pair;

  -- Memory port signals.
  signal ev_a_cmd       : ram_command;
  signal ev_b_cmd       : ram_command;
  signal od_a_cmd       : ram_command;
  signal od_b_cmd       : ram_command;
  signal ev_a_resp      : ram_response;
  signal ev_b_resp      : ram_response;
  signal od_a_resp      : ram_response;
  signal od_b_resp      : ram_response;

begin

  -- Datapath.
  datapath_inst: vhsnunzip_pipeline
    port map (
      clk           => clk,
      reset         => reset,
      co            => co,
      co_ready      => co_ready,
      co_level      => co_level,
      lt_rd_valid   => lt_rd_valid,
      lt_rd_ready   => lt_rd_ready,
      lt_rd_adev    => lt_rd_adev,
      lt_rd_adod    => lt_rd_adod,
      lt_rd_next    => lt_rd_next,
      lt_rd_even    => lt_rd_even,
      lt_rd_odd     => lt_rd_odd,
      de            => de,
      de_ready      => de_ready,
      de_level      => de_level
    );

  -- Instantiate memory access arbiters. The input/output streams have midrange
  -- priority, while the inputs to the pipeline have lowered priority and the
  -- compressed output always gets immediate access. The priorities of the
  -- pipeline input changes at runtime based on the FIFO level. This might be
  -- overkill, but maybe it'll allow some performance tweaking later.
  arbiter_a_inst: vhsnunzip_port_arbiter
    generic map (
      IF_LO_PRIO    => (0 => 2, 1 => 2, 2 => 1, 3 => 4),
      IF_HI_PRIO    => (0 => 3, 1 => 3, 2 => 2),
      LATENCY       => 3
    )
    port map (
      clk           => clk,
      reset         => reset,
      req(0)        => in_mreq(0),
      req(1)        => out_mreq(0),
      req(2)        => co_mreq,
      req(3)        => de_mreq,
      req_ready(0)  => in_mreq_ready(0),
      req_ready(1)  => out_mreq_ready(0),
      req_ready(2)  => co_mreq_ready,
      req_ready(3)  => de_mreq_ready,
      resp(0)       => in_mresp(0),
      resp(1)       => out_mresp(0),
      resp(2)       => co_mresp,
      resp(3)       => de_mresp,
      ev_cmd        => ev_a_cmd,
      od_cmd        => od_a_cmd,
      ev_resp       => ev_a_resp,
      od_resp       => od_a_resp
    );

  arbiter_b_inst: vhsnunzip_port_arbiter
    generic map (
      IF_LO_PRIO    => (0 => 2, 1 => 2, 2 => 2, 3 => 0),
      IF_HI_PRIO    => (0 => 3, 1 => 3, 2 => 2),
      LATENCY       => 3
    )
    port map (
      clk           => clk,
      reset         => reset,
      req(0)        => in_mreq(1),
      req(1)        => out_mreq(1),
      req(2)        => lt_mreq,
      req(3)        => RAM_REQUEST_INIT,
      req_ready(0)  => in_mreq_ready(1),
      req_ready(1)  => out_mreq_ready(1),
      req_ready(2)  => lt_mreq_ready,
      req_ready(3)  => unused_ready,
      resp(0)       => in_mresp(1),
      resp(1)       => out_mresp(1),
      resp(2)       => lt_mresp,
      resp(3)       => unused_resp,
      ev_cmd        => ev_b_cmd,
      od_cmd        => od_b_cmd,
      ev_resp       => ev_b_resp,
      od_resp       => od_b_resp
    );

  -- RAM containing the even 8-byte lines of decompression history.
  ram_even_inst: vhsnunzip_ram
    generic map (
      RAM_STYLE => RAM_STYLE
    )
    port map (
      clk       => clk,
      reset     => reset,
      a_cmd     => ev_a_cmd,
      a_resp    => ev_a_resp,
      b_cmd     => ev_b_cmd,
      b_resp    => ev_b_resp
    );

  -- RAM containing the odd 8-byte lines of decompression history.
  ram_odd_inst: vhsnunzip_ram
    generic map (
      RAM_STYLE => RAM_STYLE
    )
    port map (
      clk       => clk,
      reset     => reset,
      a_cmd     => od_a_cmd,
      a_resp    => od_a_resp,
      b_cmd     => od_b_cmd,
      b_resp    => od_b_resp
    );

end behavior;
