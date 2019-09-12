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
  signal pipe_reset     : std_logic;
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

  -- Output FIFO signals.
  signal of_data_val    : std_logic_vector(3 downto 0);
  signal of_data        : std_logic_vector(255 downto 0);
  signal of_ctrl_val    : std_logic;
  signal of_cnt         : std_logic_vector(4 downto 0);
  signal of_last        : std_logic;
  signal of_level       : unsigned(5 downto 0);
  signal of_block       : std_logic;
  signal outf_valid_vec : std_logic_vector(4 downto 0);
  signal outf_valid     : std_logic;
  signal outf_ready     : std_logic;

  -- Data input buffer write ports. Can be handled at the same time.
  signal in_mreq        : ram_request_array(0 to 1);
  signal in_mreq_ready  : std_logic_array(0 to 1);
  signal in_mresp       : ram_response_pair_array(0 to 1);

  -- Data output buffer read ports. Can be handled at the same time.
  signal of_mreq        : ram_request_array(0 to 1);
  signal of_mreq_ready  : std_logic_array(0 to 1);
  signal of_mresp       : ram_response_pair_array(0 to 1);

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

  -- Dummy signals; we just need these to finish the array of the second port
  -- arbiter (you can't associate a port array only partially).
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
      reset         => pipe_reset,
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

  -- Output FIFO. We need some kind of buffer here because we can't stall the
  -- memory access pipeline and can't predict ready ahead of time without one.
  out_data_fifo_gen: for idx in 0 to 3 generate
  begin
    out_data_fifo_inst: vhsnunzip_fifo
      generic map (
        CTRL_WIDTH  => 64
      )
      port map (
        clk         => clk,
        reset       => reset,
        wr_valid    => of_data_val(idx),
        wr_ctrl     => of_data(64*idx+63 downto 64*idx),
        rd_valid    => outf_valid_vec(idx),
        rd_ready    => outf_ready,
        rd_ctrl     => out_data(64*idx+63 downto 64*idx)
      );
  end generate;

  out_ctrl_fifo_inst: vhsnunzip_fifo
    generic map (
      CTRL_WIDTH    => 6
    )
    port map (
      clk           => clk,
      reset         => reset,
      wr_valid      => of_ctrl_val,
      wr_ctrl(5)    => of_last,
      wr_ctrl(4 downto 0) => of_cnt,
      rd_valid      => outf_valid_vec(4),
      rd_ready      => outf_ready,
      rd_ctrl(5)    => out_last,
      rd_ctrl(4 downto 0) => out_cnt,
      level         => of_level
    );

  -- Connect the data FIFO inputs to the memory ports.
  out_fifo_connect_proc: process (of_mresp) is
  begin
    of_data_val(0) <= of_mresp(0).ev.valid;
    of_data_val(1) <= of_mresp(0).od.valid;
    of_data_val(2) <= of_mresp(1).ev.valid;
    of_data_val(3) <= of_mresp(1).od.valid;
    for byte in 0 to 7 loop
      of_data(byte*8+  0+7 downto byte*8+  0) <= of_mresp(0).ev.rdat(byte);
      of_data(byte*8+ 64+7 downto byte*8+ 64) <= of_mresp(0).od.rdat(byte);
      of_data(byte*8+128+7 downto byte*8+128) <= of_mresp(1).ev.rdat(byte);
      of_data(byte*8+192+7 downto byte*8+192) <= of_mresp(1).od.rdat(byte);
    end loop;
  end process;

  -- Push the control data for the output along with one of the memory read
  -- port commands.
  of_ctrl_val <= of_mreq(0).valid and of_mreq_ready(0);

  -- The output stream validates when all FIFO outputs become valid.
  outf_valid <= outf_valid_vec(0) and outf_valid_vec(1)
            and outf_valid_vec(2) and outf_valid_vec(3)
            and outf_valid_vec(4);
  outf_ready <= outf_valid and out_ready;
  out_valid  <= outf_valid;

  -- Block reading and pushing output data when the ctrl FIFO level is 3/4
  -- full. This leaves room for 8 pipeline stages in the read path.
  of_block <= of_level(4) and of_level(3) and not of_level(5);

  -- This block contains 64kiB of large-scale memory, either URAM or
  -- BRAM-based, that's used for three things:
  --
  --  - Long-term decompression history: Snappy compression works by copying
  --    chunks of previously decompressed data. Typically the compression
  --    window size selected during compression limits history depth
  --    requirements to 32kiB, but that's a configuration option, so we should
  --    support the full 64kiB chunk size.
  --  - Input buffering: all four 64-bit memory ports are used in parallel to
  --    consume input data as fast as possible before compression starts.
  --  - Output buffering: all four ports can also run in parallel to push out
  --    the fully compressed chunk.
  --
  -- The purpose of the last two items is to allow multiple of these cores to
  -- work on a single stream of chunks in parallel without needing additional
  -- buffering.
  --
  -- Doing the buffering of both compressed and decompressed chunk data in a
  -- single memory no larger than the maximum decompressed chunk size takes
  -- some bookkeeping. First of all, we need to know the size of the compressed
  -- chunk before we can start decompressing. The easiest way to get this is to
  -- just buffer up the entire chunk. Once we've done that, we can start
  -- writing decompressed data to the memory immediately following the
  -- decompressed chunk. The compressed data gets consumed as we decompress, so
  -- the compressed data write pointer can and will roll over back to zero
  -- during decompression.
  --
  -- The above only works when the compressor is sane, and actually compresses
  -- the input; if it would just write a bunch of one-byte literal elements to
  -- fill up the 64kiB decompressed chunk you'd end up needing 128kiB for the
  -- compressed chunk, which obviously doesn't fit. A completely incompressible
  -- 64kiB chunk of data will, however, result in slightly more than 64kiB of
  -- compressed data; 6 bytes more to be exact (3 bytes for the decompressed
  -- size header, and 3 to encode a 64kiB literal header). The extra space
  -- needed for this (and more) is however easily covered by the 32x8 byte
  -- input FIFO in the pipeline.
  --
  -- We use the following state variables to manage this:
  --
  --  - in_ptr: compressed write pointer;
  --  - co_ptr: compressed read pointer;
  --  - co_rem: (remaining) compressed chunk size, diminished-one;
  --  - de_ptr: decompressed write pointer;
  --  - of_ptr: decompressed read pointer;
  --  - of_rem: (remaining) decompressed chunk size, diminished-one;
  --  - level: FIFO level (explained below);
  --  - busy: whether we're decompressing.
  --
  -- The functionality of the pointers should be fairly obvious. co_rem acts
  -- like a FIFO level for the compressed data; it represents the number of
  -- valid compressed bytes in the memory (with byte granularity). It is used
  -- by the "co" logic to determine the "last" and "endi" flags: last is set
  -- when bit 16..3 is zero, at which point "endi" is just the 3 LSBs.
  -- out_rem is used similarly for the output stream. These signals are *not*
  -- used to determine the FIFO full status, however; level does this.
  --
  -- While buffering compressed input data, level represents the number of
  -- linepairs (= 16 bytes) in the memory currently dedicated to compressed
  -- data. The input stream stalls when its MSB hits one, which gives time for
  -- the co logic to push data into the pipeline input FIFO to clear up space
  -- for the fully incompressible 64kiB chunk scenario. When the last
  -- compressed chunk transfer is received, the pipeline is unblocked by
  -- pushing the long-term offset, busy is set, and the behavior of level
  -- changes; it now represents 64kiB minus the number of linepairs available
  -- for the decompressed data. As such, it is still decremented when
  -- a compressed line is pushed into the pipeline, but it also increments
  -- when a decompressed line is pulled out of the pipeline. Therefore, when
  -- the MSB is set, the "de" logic must block.
  --
  -- There is a possibility for deadlock in all of this when invalid data is
  -- passed to the decompressor. The primary symptom is the MSB of level being
  -- set and nothing happening. Depending on busy, this either signals that the
  -- compressed or decompressed chunk size is too large. Dealing with such
  -- deadlocks is TODO; ultimately, they should be handled gracefully by
  -- terminating the decompressed chunk along with an error flag, draining the
  -- remainder of the compressed chunk to /dev/null (if applicable), and
  -- resetting the pipeline.
  mem_management_proc: process (clk) is

    -- See comment block above for descriptions of these state variables.
    variable in_ptr     : unsigned(12 downto 0) := (others => '0');
    variable co_ptr     : unsigned(12 downto 0) := (others => '0');
    variable co_rem     : unsigned(16 downto 0) := (others => '1');
    variable de_ptr     : unsigned(12 downto 0) := (others => '0');
    variable of_ptr     : unsigned(12 downto 0) := (others => '0');
    variable of_rem     : unsigned(16 downto 0) := (others => '1');
    variable level      : unsigned(12 downto 0) := (others => '0');
    variable busy       : std_logic;

    -- Stream holding registers.
    variable inh_valid  : std_logic;
    variable inh_data   : std_logic_vector(255 downto 0);
    variable inh_cnt    : std_logic_vector(4 downto 0);
    variable inh_last   : std_logic;
    variable coh        : compressed_stream_single;
    variable deh        : decompressed_stream;

    -- Memory request output holding registers.
    variable in_mreqh   : ram_request_array(0 to 1);
    variable of_mreqh   : ram_request_array(0 to 1);
    variable co_mreqh   : ram_request;
    variable de_mreqh   : ram_request;

  begin
    if rising_edge(clk) then

      -- Buffer the pipeline reset flag here, so we can reset the pipeline when
      -- recovering from a deadlock.
      pipe_reset <= reset;

      -- Invalidate the stream output registers if they were shifted out.
      if co_ready = '1' then
        coh.valid := '0';
      end if;
      for idx in 0 to 1 loop
        if in_mreq_ready(idx) = '1' then
          in_mreqh(idx).valid := '0';
        end if;
        if of_mreq_ready(idx) = '1' then
          of_mreqh(idx).valid := '0';
        end if;
      end loop;
      if co_mreq_ready = '1' then
        co_mreqh.valid := '0';
      end if;
      if de_mreq_ready = '1' then
        de_mreqh.valid := '0';
      end if;

      -- Shift new data into the input when we can.
      if inh_valid = '0' and busy = '0' then
        inh_valid := in_valid;
        inh_data  := in_data;
        inh_cnt   := in_cnt;
        inh_last  := in_last;
      end if;
      if coh.valid = '0' then
        coh := co;
      end if;

      -- TODO magic that my sleepy brain cannot comprehend right now goes here.

      -- Handle reset.
      if reset = '1' then
        in_ptr    := (others => '0');
        co_ptr    := (others => '0');
        co_rem    := (others => '1');
        de_ptr    := (others => '0');
        of_ptr    := (others => '0');
        of_rem    := (others => '1');
        level     := (others => '0');
        busy      := '0';
        inh_valid := '0';
        coh.valid := '0';
        deh.valid := '0';
        in_mreqh(0).valid := '0';
        in_mreqh(1).valid := '0';
        of_mreqh(0).valid := '0';
        of_mreqh(1).valid := '0';
        co_mreqh.valid := '0';
        de_mreqh.valid := '0';
      end if;

      -- Assign outputs.
      in_ready <= not inh_valid and not busy;
      co <= coh;
      de_ready <= not deh.valid and busy;
      in_mreq <= in_mreqh;
      of_mreq <= of_mreqh;
      co_mreq <= co_mreqh;
      de_mreq <= de_mreqh;

    end if;
  end process;

  -- Instantiate memory access arbiters. The input/output streams have midrange
  -- priority, while the inputs to the pipeline have lowered priority and the
  -- compressed output always gets immediate access. The priorities of the
  -- pipeline input could be changed at runtime based on the FIFO levels, but
  -- we don't do this right now.
  arbiter_a_inst: vhsnunzip_port_arbiter
    generic map (
      IF_LO_PRIO    => (0 => 3, 1 => 3, 2 => 1, 3 => 4),
      IF_HI_PRIO    => (0 => 3, 1 => 3, 2 => 1),
      LATENCY       => 3
    )
    port map (
      clk           => clk,
      reset         => reset,
      req(0)        => in_mreq(0),
      req(1)        => of_mreq(0),
      req(2)        => co_mreq,
      req(3)        => de_mreq,
      req_ready(0)  => in_mreq_ready(0),
      req_ready(1)  => of_mreq_ready(0),
      req_ready(2)  => co_mreq_ready,
      req_ready(3)  => de_mreq_ready,
      resp(0)       => in_mresp(0),
      resp(1)       => of_mresp(0),
      resp(2)       => co_mresp,
      resp(3)       => de_mresp,
      ev_cmd        => ev_a_cmd,
      od_cmd        => od_a_cmd,
      ev_resp       => ev_a_resp,
      od_resp       => od_a_resp
    );

  arbiter_b_inst: vhsnunzip_port_arbiter
    generic map (
      IF_LO_PRIO    => (0 => 3, 1 => 3, 2 => 2, 3 => 0),
      IF_HI_PRIO    => (0 => 3, 1 => 3, 2 => 2),
      LATENCY       => 3
    )
    port map (
      clk           => clk,
      reset         => reset,
      req(0)        => in_mreq(1),
      req(1)        => of_mreq(1),
      req(2)        => lt_mreq,
      req(3)        => RAM_REQUEST_INIT,
      req_ready(0)  => in_mreq_ready(1),
      req_ready(1)  => of_mreq_ready(1),
      req_ready(2)  => lt_mreq_ready,
      req_ready(3)  => unused_ready,
      resp(0)       => in_mresp(1),
      resp(1)       => of_mresp(1),
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
