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

    -- pragma translate_off
    -- Debug outputs.
    dbg_co      : out compressed_stream_single;
    dbg_de      : out decompressed_stream;
    -- pragma translate_on

    -- Decompressed output stream. This stream is normalized. The dvalid signal
    -- is used for the special case of a zero-length packet; a single transfer
    -- with last high, dvalid low, cnt zero, and unspecified data is produced
    -- in this case. Otherwise, dvalid is always high.
    out_valid   : out std_logic;
    out_ready   : in  std_logic;
    out_dvalid  : out std_logic;
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

  -- Output FIFO signals.
  signal of_data_val    : std_logic_vector(1 downto 0);
  signal of_data        : std_logic_vector(255 downto 0);
  signal of_ctrl_val    : std_logic;
  signal of_dvalid      : std_logic;
  signal of_cnt         : std_logic_vector(4 downto 0);
  signal of_last        : std_logic;
  signal of_level       : unsigned(5 downto 0);
  signal of_block       : std_logic;
  signal outf_valid_vec : std_logic_vector(2 downto 0);
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

  -- State registers.
  signal in_ptr_r       : unsigned(10 downto 0) := (others => '0');
  signal co_ptr_r       : unsigned(11 downto 0) := (others => '0');
  signal co_rem_r       : unsigned(12 downto 0) := (others => '1');
  signal de_ptr_r       : unsigned(12 downto 0) := (others => '0');
  signal de_last_seen_r : std_logic := '0';
  signal of_ptr_r       : unsigned(10 downto 0) := (others => '0');
  signal of_rem_r       : unsigned(11 downto 0) := (others => '1');
  signal of_last_cnt_r  : unsigned(4 downto 0) := (others => '0');
  signal of_last_sent_r : std_logic;
  signal level_r        : unsigned(11 downto 0) := (others => '0');
  signal busy_r         : std_logic;

  -- Internal reset signal, asserted when we've completed a chunk.
  signal int_reset      : std_logic;

begin

  -- pragma translate_off
  dbg_co_proc: process (co, co_ready) is
  begin
    dbg_co <= co;
    dbg_co.valid <= co.valid and co_ready;
  end process;
  dbg_de_proc: process (de, de_ready) is
  begin
    dbg_de <= de;
    dbg_de.valid <= de.valid and de_ready;
  end process;
  -- pragma translate_on

  -- Datapath.
  pipeline_inst: vhsnunzip_pipeline
    generic map (
      LONG_CHUNKS   => false
    )
    port map (
      clk           => clk,
      reset         => int_reset,
      co            => co,
      co_ready      => co_ready,
      co_level      => co_level,
      lt_off_ld     => lt_off_ld,
      lt_off        => lt_off,
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

  -- Connect the long-term read port to the pipeline.
  lt_mreq <= (
    valid    => lt_rd_valid,
    hipri    => '0',
    ev_addr  => lt_rd_adev,
    od_addr  => lt_rd_adod,
    ev_wren  => '0',
    od_wren  => '0',
    ev_wdat  => (others => X"00"),
    od_wdat  => (others => X"00"),
    ev_wctrl => (others => '0'),
    od_wctrl => (others => '0')
  );
  lt_rd_ready <= lt_mreq_ready;
  lt_rd_next  <= lt_mresp.ev.valid_next;
  lt_rd_even  <= lt_mresp.ev.rdat;
  lt_rd_odd   <= lt_mresp.od.rdat;

  -- Output FIFO. We need some kind of buffer here because we can't stall the
  -- memory access pipeline and can't predict ready ahead of time without one.
  out_data_fifo_gen: for idx in 0 to 1 generate
  begin
    out_data_fifo_inst: vhsnunzip_fifo
      generic map (
        CTRL_WIDTH  => 128
      )
      port map (
        clk         => clk,
        reset       => reset,
        wr_valid    => of_data_val(idx),
        wr_ctrl     => of_data(128*idx+127 downto 128*idx),
        rd_valid    => outf_valid_vec(idx),
        rd_ready    => outf_ready,
        rd_ctrl     => out_data(128*idx+127 downto 128*idx)
      );
  end generate;

  out_ctrl_fifo_inst: vhsnunzip_fifo
    generic map (
      CTRL_WIDTH    => 7
    )
    port map (
      clk           => clk,
      reset         => reset,
      wr_valid      => of_ctrl_val,
      wr_ctrl(6)    => of_dvalid,
      wr_ctrl(5)    => of_last,
      wr_ctrl(4 downto 0) => of_cnt,
      rd_valid      => outf_valid_vec(2),
      rd_ready      => outf_ready,
      rd_ctrl(6)    => out_dvalid,
      rd_ctrl(5)    => out_last,
      rd_ctrl(4 downto 0) => out_cnt,
      level         => of_level
    );

  -- Connect the data FIFO inputs to the memory ports.
  out_fifo_connect_proc: process (of_mresp) is
  begin
    of_data_val(0) <= of_mresp(0).ev.valid;
    of_data_val(1) <= of_mresp(1).ev.valid;
    for byte in 0 to 7 loop
      of_data(byte*8+  0+7 downto byte*8+  0) <= of_mresp(0).ev.rdat(byte);
      of_data(byte*8+ 64+7 downto byte*8+ 64) <= of_mresp(0).od.rdat(byte);
      of_data(byte*8+128+7 downto byte*8+128) <= of_mresp(1).ev.rdat(byte);
      of_data(byte*8+192+7 downto byte*8+192) <= of_mresp(1).od.rdat(byte);
    end loop;
  end process;

  -- The output stream validates when all FIFO outputs become valid.
  outf_valid <= outf_valid_vec(0) and outf_valid_vec(1) and outf_valid_vec(2);
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
  --  - in_ptr: compressed write pointer (in linequad units);
  --  - co_ptr: compressed read pointer (in linepair units);
  --  - co_rem: (remaining) compressed linepairs, diminished-one;
  --  - co_busy: used to limit linepair reads to 50% duty cycle;
  --  - de_ptr: decompressed write pointer (in line units);
  --  - of_ptr: decompressed read pointer (in linequad units);
  --  - of_rem: (remaining) decompressed linequads, diminished-two;
  --  - level: FIFO level (in linequad units, explained below);
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
    variable in_ptr       : unsigned(10 downto 0) := (others => '0');
    variable co_ptr       : unsigned(11 downto 0) := (others => '0');
    variable co_rem       : unsigned(12 downto 0) := (others => '1');
    variable co_busy      : std_logic;
    variable de_ptr       : unsigned(12 downto 0) := (others => '0');
    variable de_last_seen : std_logic := '0';
    variable of_ptr       : unsigned(10 downto 0) := (others => '0');
    variable of_rem       : unsigned(11 downto 0) := (0 => '0', others => '1');
    variable of_last_cnt  : unsigned(4 downto 0) := (others => '0');
    variable of_last_sent : std_logic;
    variable level        : unsigned(11 downto 0) := (others => '0');
    variable busy         : std_logic;

    -- Stream holding registers.
    variable inh_valid    : std_logic;
    variable inh_data     : std_logic_vector(255 downto 0);
    variable inh_endi     : unsigned(4 downto 0);
    variable inh_last     : std_logic;
    variable coh          : compressed_stream_single;
    variable deh          : decompressed_stream;

    -- Memory request output holding registers.
    variable in_mreqh     : ram_request_array(0 to 1);
    variable in_m_done    : std_logic_array(0 to 1);
    variable of_mreqh     : ram_request_array(0 to 1);
    variable co_mreqh     : ram_request;
    variable de_mreqh     : ram_request;

  begin
    if rising_edge(clk) then

      -- Load state register signals.
      in_ptr        := in_ptr_r;
      co_ptr        := co_ptr_r;
      co_rem        := co_rem_r;
      de_ptr        := de_ptr_r;
      de_last_seen  := de_last_seen_r;
      of_ptr        := of_ptr_r;
      of_rem        := of_rem_r;
      of_last_cnt   := of_last_cnt_r;
      of_last_sent  := of_last_sent_r;
      level         := level_r;
      busy          := busy_r;

      -- Invalidate the stream output registers if they were shifted out.
      for idx in 0 to 1 loop
        if in_mreq_ready(idx) = '1' then
          in_mreqh(idx).valid := '0';
        end if;
        if of_mreq_ready(idx) = '1' then
          of_mreqh(idx).valid := '0';
        end if;
      end loop;
      if co_mreq_ready = '1' then
        co_busy := co_mreqh.valid;
        if co_mreqh.valid = '1' and co_mreqh.ev_addr(0) = '1' then
          level := level - 1;
        end if;
        co_mreqh.valid := '0';
      else
        co_busy := '0';
      end if;
      if de_mreq_ready = '1' then
        de_mreqh.valid := '0';
      end if;

      -- Shift new data into the input when we can.
      if inh_valid = '0' and busy = '0' then
        inh_valid := in_valid;
        inh_data := in_data;
        inh_endi := unsigned(in_cnt) - 1;
        inh_last  := in_last;
        in_m_done := "00";
      end if;
      if deh.valid = '0' and busy = '1' then
        deh := de;
      end if;

      -- Handle the input stream.
      lt_off_ld <= '0';
      in_mreqh(0).hipri := '0';
      in_mreqh(1).hipri := '0';
      in_mreqh(0).ev_wren := '1';
      in_mreqh(0).od_wren := '1';
      in_mreqh(1).ev_wren := '1';
      in_mreqh(1).od_wren := '1';
      in_mreqh(0).ev_addr(0) := '0';
      in_mreqh(0).od_addr(0) := '0';
      in_mreqh(1).ev_addr(0) := '1';
      in_mreqh(1).od_addr(0) := '1';
      if busy = '0' and inh_valid = '1' and level_r(11) = '0' then
        for idx in 0 to 1 loop
          if in_mreqh(idx).valid = '0' and in_m_done(idx) = '0' then
            in_mreqh(idx).valid := '1';
            in_mreqh(idx).ev_addr(11 downto 1) := in_ptr;
            in_mreqh(idx).od_addr(11 downto 1) := in_ptr;
            if idx = 0 then
              for byte in 0 to 7 loop
                in_mreqh(idx).ev_wdat(byte) := inh_data(byte*8+  0+7 downto byte*8+  0);
                in_mreqh(idx).od_wdat(byte) := inh_data(byte*8+ 64+7 downto byte*8+ 64);
              end loop;
              in_mreqh(idx).ev_wctrl := X"0E";
              in_mreqh(idx).od_wctrl := X"0E";
              if inh_endi(4 downto 3) = "00" then
                in_mreqh(idx).ev_wctrl(3 downto 1) := std_logic_vector(inh_endi(2 downto 0));
                in_mreqh(idx).ev_wctrl(0) := inh_last;
              end if;
              if inh_endi(4 downto 3) = "01" then
                in_mreqh(idx).od_wctrl(3 downto 1) := std_logic_vector(inh_endi(2 downto 0));
                in_mreqh(idx).od_wctrl(0) := inh_last;
              end if;
            else
              for byte in 0 to 7 loop
                in_mreqh(idx).ev_wdat(byte) := inh_data(byte*8+128+7 downto byte*8+128);
                in_mreqh(idx).od_wdat(byte) := inh_data(byte*8+192+7 downto byte*8+192);
              end loop;
              in_mreqh(idx).ev_wctrl := X"0E";
              in_mreqh(idx).od_wctrl := X"0E";
              if inh_endi(4 downto 3) = "10" then
                in_mreqh(idx).ev_wctrl(3 downto 1) := std_logic_vector(inh_endi(2 downto 0));
                in_mreqh(idx).ev_wctrl(0) := inh_last;
              end if;
              in_mreqh(idx).od_wctrl(3 downto 1) := std_logic_vector(inh_endi(2 downto 0));
              in_mreqh(idx).od_wctrl(0) := inh_last;
            end if;
            in_m_done(idx) := '1';
          end if;
        end loop;

        if in_m_done = "11" then
          inh_valid := '0';
          co_rem := co_rem + inh_endi(4 downto 4) + 1;
          in_ptr := in_ptr + 1;
          level := level + 1;
          if inh_last = '1' then
            busy := '1';
            lt_off_ld <= '1';
            de_ptr := in_ptr & "00";
            of_ptr := in_ptr;
          end if;
        end if;
      end if;
      lt_off <= in_ptr & "00";

      -- Handle the compressed data stream to the datapath.
      co_mreqh.hipri := '0';
      co_mreqh.ev_wren := '0';
      co_mreqh.od_wren := '0';
      co_mreqh.ev_wdat := (others => X"00");
      co_mreqh.od_wdat := (others => X"00");
      co_mreqh.ev_wctrl := (others => '0');
      co_mreqh.od_wctrl := (others => '0');
      if co_mreqh.valid = '0' and co_rem_r(12) = '0' then
        if co_busy = '0' and (co_level(5) = '1' or co_level(4) = '0') then
          co_mreqh.valid := '1';
          co_mreqh.ev_addr := co_ptr;
          co_mreqh.od_addr := co_ptr;
          co_ptr := co_ptr + 1;
          co_rem := co_rem - 1;
        end if;
      end if;

      co <= coh;
      coh.valid := '0';
      coh.data := co_mresp.od.rdat;
      coh.last := co_mresp.od.rctrl(0);
      coh.endi := unsigned(co_mresp.od.rctrl(3 downto 1));
      if co_mresp.ev.valid = '1' then
        co.valid <= '1';
        co.data <= co_mresp.ev.rdat;
        co.last <= co_mresp.ev.rctrl(0);
        co.endi <= unsigned(co_mresp.ev.rctrl(3 downto 1));
        coh.valid := not co_mresp.ev.rctrl(0); -- last
      end if;

      -- Handle the decompressed data stream from the datapath.
      de_mreqh.hipri := '0';
      de_mreqh.ev_wren := '1';
      de_mreqh.od_wren := '1';
      de_mreqh.ev_wctrl := (others => '0');
      de_mreqh.od_wctrl := (others => '0');
      if deh.valid = '1' and de_mreqh.valid = '0' and (level_r(11 downto 10) /= "10" or co_rem_r(12) = '1') then
        deh.valid := '0';
        de_mreqh.valid := de_ptr(0) or deh.last;
        de_mreqh.ev_addr := de_ptr(12 downto 1);
        de_mreqh.od_addr := de_ptr(12 downto 1);
        if de_ptr(0) = '0' then
          de_mreqh.ev_wdat := deh.data;
        end if;
        de_mreqh.od_wdat := deh.data;
        if de_ptr(1 downto 0) = "11" or deh.last = '1' then
          level := level + 1;
          if deh.cnt /= "0000" or de_ptr(1 downto 0) /= "00" then
            of_rem := of_rem + 1;
          end if;
        end if;
        if deh.last = '1' then
          de_last_seen := '1';
        end if;
        of_last_cnt := of_last_cnt + deh.cnt;
        de_ptr := de_ptr + 1;
      end if;

      -- Reset ourselves (with the exception of the output FIFOs and memory
      -- logic) when we're done with a chunk.
      int_reset <= reset;
      if of_last_sent = '1' then
        if of_mreqh(0).valid = '0' and of_mreqh(1).valid = '0' then
          int_reset <= not int_reset;
        end if;
      end if;

      -- Handle the output stream.
      of_ctrl_val <= '0';
      of_dvalid <= '1';
      of_cnt <= "00000";
      of_last <= '0';
      for idx in 0 to 1 loop
        of_mreqh(idx).hipri := '0';
        of_mreqh(idx).ev_wren := '0';
        of_mreqh(idx).od_wren := '0';
        of_mreqh(idx).ev_wdat := (others => X"00");
        of_mreqh(idx).od_wdat := (others => X"00");
        of_mreqh(idx).ev_wctrl := (others => '0');
        of_mreqh(idx).od_wctrl := (others => '0');
      end loop;
      if of_rem_r(11) = '0' or ((of_rem_r(0) = '1' or of_last_sent = '0') and de_last_seen_r = '1') then
        if of_mreqh(0).valid = '0' and of_mreqh(1).valid = '0' and of_block = '0' then
          of_mreqh(0).valid := '1';
          of_mreqh(1).valid := '1';
          of_mreqh(0).ev_addr := of_ptr & "0";
          of_mreqh(0).od_addr := of_ptr & "0";
          of_mreqh(1).ev_addr := of_ptr & "1";
          of_mreqh(1).od_addr := of_ptr & "1";

          of_ctrl_val <= '1';
          if of_rem(11) = '1' then
            of_last <= '1';
            if of_rem_r(0) = '1' then
              of_cnt <= std_logic_vector(of_last_cnt);
            else
              of_dvalid <= '0';
            end if;
            of_last_sent := '1';
          end if;

          of_rem := of_rem - 1;
          of_ptr := of_ptr + 1;
        end if;
      end if;

      -- Handle reset.
      if reset = '1' then
        inh_valid     := '0';
      end if;
      if int_reset = '1' then
        in_ptr        := (others => '0');
        co_ptr        := (others => '0');
        co_rem        := (others => '1');
        de_ptr        := (others => '0');
        of_ptr        := (others => '0');
        of_rem        := (0 => '0', others => '1');
        of_last_cnt   := (others => '0');
        of_last_sent  := '0';
        de_last_seen  := '0';
        level         := (others => '0');
        busy          := '0';
        coh.valid     := '0';
        co.valid      <= '0';
        co_busy       := '0';
        deh.valid     := '0';
        in_mreqh(0).valid := '0';
        in_mreqh(1).valid := '0';
        of_mreqh(0).valid := '0';
        of_mreqh(1).valid := '0';
        co_mreqh.valid := '0';
        de_mreqh.valid := '0';
        of_ctrl_val   <= '0';
        of_cnt        <= "00000";
        of_last       <= '0';
        lt_off_ld     <= '0';
      end if;

      -- Assign outputs.
      in_ready <= not inh_valid and not busy;
      de_ready <= not deh.valid and busy;
      in_mreq <= in_mreqh;
      of_mreq <= of_mreqh;
      co_mreq <= co_mreqh;
      de_mreq <= de_mreqh;

      -- Assign state register signals.
      in_ptr_r        <= in_ptr;
      co_ptr_r        <= co_ptr;
      co_rem_r        <= co_rem;
      de_ptr_r        <= de_ptr;
      de_last_seen_r  <= de_last_seen;
      of_ptr_r        <= of_ptr;
      of_rem_r        <= of_rem;
      of_last_cnt_r   <= of_last_cnt;
      of_last_sent_r  <= of_last_sent;
      level_r         <= level;
      busy_r          <= busy;

    end if;
  end process;

  -- Instantiate memory access arbiters. The input/output streams have midrange
  -- priority, while the inputs to the pipeline have lowered priority and the
  -- compressed output always gets immediate access. The priorities of the
  -- pipeline input could be changed at runtime based on the FIFO levels, but
  -- we don't do this right now.
  arbiter_a_inst: vhsnunzip_port_arbiter
    generic map (
      IF_LO_PRIO    => (0 => 3, 1 => 1, 2 => 1, 3 => 4),
      IF_HI_PRIO    => (0 => 3, 1 => 1, 2 => 1),
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
      IF_LO_PRIO    => (0 => 3, 1 => 1, 2 => 2, 3 => 0),
      IF_HI_PRIO    => (0 => 3, 1 => 1, 2 => 2),
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
