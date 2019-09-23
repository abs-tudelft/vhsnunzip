library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.vhsnunzip_int_pkg.all;

-- Snappy decompression pipeline.
entity vhsnunzip_pipeline is
  generic (

    -- Whether long chunks (>64kiB) should be supported. If this is disabled,
    -- the core will be a couple hundred LUTs smaller.
    LONG_CHUNKS : boolean := true

  );
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

    -- Long-term storage read enable and address stream. Both an odd and even
    -- line should be read. This stream should NOT be (significantly) FIFO'd
    -- up, though a couple pipeline stages is fine; basically, the total
    -- outstanding requests must not go over 32 minus the maximum pipeline
    -- stage storage in the decoder and command generation blocks, or the
    -- literal data FIFO may overrun. Staying under 10 or so should be
    -- perfectly fine. Also important is that lt_rd_ready is expected to go
    -- high even if there is no command, otherwise the pipeline will stall.
    -- Furthermore, the latency between handshaking the address and the read
    -- result must be constant.
    lt_rd_valid : out std_logic;
    lt_rd_ready : in  std_logic := '1';
    lt_rd_adev  : out unsigned(11 downto 0);
    lt_rd_adod  : out unsigned(11 downto 0);

    -- Read data response signals. lt_rd_next should assert to indicate that
    -- the read data will be available in the *next* cycle. No backpressure
    -- support is needed here.
    lt_rd_next  : in  std_logic;
    lt_rd_even  : in  byte_array(0 to 7);
    lt_rd_odd   : in  byte_array(0 to 7);

    -- pragma translate_off
    -- Debug outputs.
    dbg_cs      : out compressed_stream_single;
    dbg_cd      : out compressed_stream_double;
    dbg_el      : out element_stream;
    dbg_c1      : out partial_command_stream;
    dbg_cm      : out command_stream;
    dbg_s1      : out command_stream;
    -- pragma translate_on

    -- Decompressed data output stream.
    de          : out decompressed_stream;
    de_ready    : in  std_logic;
    de_level    : out unsigned(5 downto 0)

  );
end vhsnunzip_pipeline;

architecture behavior of vhsnunzip_pipeline is

  -- Compressed data FIFO signals.
  signal co_ctrl      : std_logic_vector(3 downto 0);
  signal cs_ctrl      : std_logic_vector(3 downto 0);

  -- Compressed line data stream.
  signal cs           : compressed_stream_single;
  signal cs_ready     : std_logic;
  signal cs_strobe    : std_logic;

  -- Compressed linepair data stream.
  signal cd           : compressed_stream_double;
  signal cd_ready     : std_logic;

  -- Element information stream.
  signal el           : element_stream;
  signal el_ready     : std_logic;

  -- Command generator stage one output stream.
  signal c1           : partial_command_stream;
  signal c1_ready     : std_logic;

  -- Command generator output stream.
  signal cm           : command_stream;
  signal cm_ready     : std_logic;

  -- Command stream FIFO write-side signals.
  signal cm_push      : std_logic;
  signal cm_ctrl      : std_logic_vector(25 downto 0);

  -- Command stream FIFO read-side signals.
  signal s1_cm_ctrl   : std_logic_vector(25 downto 0);
  signal s1_cm        : command_stream;
  signal s1_cm_exp    : command_stream;

  -- Start/valid signal for datapath stage 1. Indicates that all stage 0 inputs
  -- are valid, and that all stage 2 inputs will be valid in the next cycle.
  signal s1_valid     : std_logic;

  -- As above, for stage 2 and 3.
  signal s2_valid     : std_logic;

  -- Some array types.
  type srl_addr_array is array (natural range <>) of unsigned(4 downto 0);
  type rol_array is array (natural range <>) of unsigned(2 downto 0);

  -- Literal SRL signals.
  signal s2_li_addr   : srl_addr_array(0 to 7);
  signal s2_li_data   : byte_array(0 to 7);

  -- Short-term memory SRL signals.
  signal s2_st_addr   : srl_addr_array(0 to 7);
  signal s2_st_data   : byte_array(0 to 7);

  -- Long-term memory data signals.
  signal s2_le_data   : byte_array(0 to 7);
  signal s2_lo_data   : byte_array(0 to 7);

  -- Copy source mux.
  signal s2_lt_val    : std_logic;
  signal s2_lt_sel    : std_logic_array(0 to 7);
  signal s2_cp_data   : byte_array(0 to 7);

  -- Rotator and copy/literal mux.
  signal s2_rol_sel   : rol_array(0 to 7);
  signal s2_mux_sel   : std_logic_array(0 to 7);
  signal s2_mux_data  : byte_array(0 to 7);

  -- Byte strobe signals. The internal strobe signals assert when the
  -- respective mux data output is valid for either the current line or the
  -- next line (output holding register), while the external strobe signal
  -- asserts only in the former case.
  signal s2_int_strb  : std_logic_array(0 to 7);
  signal s2_ext_strb  : std_logic_array(0 to 7);

  -- Last flag and last valid byte index + one for stage 2.
  signal s2_last      : std_logic;
  signal s2_cnt       : unsigned(2 downto 0);

  -- Registered version of s2_cnt.
  signal s3_cnt       : unsigned(2 downto 0);

  -- Output holding register data, to support writing misaligned lines.
  signal s3_hold_data : byte_array(0 to 7);

  -- Output data line and push signal.
  signal s3_out_push  : std_logic;
  signal s3_out_data  : byte_array(0 to 7);
  signal s3_out_last  : std_logic;
  signal s3_out_cnt   : unsigned(3 downto 0);

  -- Signal which is set when the line indicated above was sent in response
  -- to the last datapath command, but isn't actually the last line because
  -- the command also wrote to the output holding register.
  signal s3_last_pend : std_logic;

  -- Output FIFO signals.
  signal s3_out_ctrl  : std_logic_vector(4 downto 0);
  signal de_ctrl      : std_logic_vector(4 downto 0);
  signal de_level_s   : unsigned(5 downto 0);
  signal backpres     : std_logic;

begin

  -- Compressed data input FIFO. This FIFO is what allows us to decompress
  -- blocks with a compressed size slightly over 64kiB (this happens for
  -- completely incompressible data). The main memory can't store that much,
  -- but with this FIFO included it can. The FIFO level is also useful for the
  -- main memory port arbitration algorithms.
  co_ctrl(0) <= co.last;
  co_ctrl(3 downto 1) <= std_logic_vector(co.endi);

  co_fifo_inst: vhsnunzip_fifo
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

  -- This is essentially an extension of the compressed data FIFO, but used
  -- exclusively for the literals. We use this to pass the literal data to the
  -- datapath without needing all the stream slices we'd need if we'd want to
  -- keep it synchronized with the rest of the stream. Note that the SRL should
  -- never "overrun" due to being limited by the register depth of the decoding
  -- and command generation pipeline, and it should never underrun because it
  -- has lower latency than said path. Also note that the Python model does not
  -- include/test this SRL.
  cs_strobe <= cs.valid and cs_ready;

  ld_srl_gen: for byte in 0 to 7 generate
  begin

    srl_inst: vhsnunzip_srl
      generic map (
        WIDTH       => 8,
        DEPTH_LOG2  => 5
      )
      port map (
        clk         => clk,
        wr_ena      => cs_strobe,
        wr_data     => cs.data(byte),
        rd_addr     => s2_li_addr(byte),
        rd_data     => s2_li_data(byte)
      );

  end generate;

  -- pragma translate_off
  dbg_cs_proc: process (cs, cs_ready) is
  begin
    dbg_cs <= cs;
    dbg_cs.valid <= cs.valid and cs_ready;
  end process;
  -- pragma translate_on

  -- Pre-decoder. This parallelizes the input stream so two lines of data are
  -- available for decoding. This prevents needing logic to handle element
  -- headers that cross a line boundary; we can just look into the next line
  -- when an element wraps.
  pre_dec_inst: vhsnunzip_pre_decoder
    generic map (
      LONG_CHUNKS => LONG_CHUNKS
    )
    port map (
      clk         => clk,
      reset       => reset,
      cs          => cs,
      cs_ready    => cs_ready,
      cd          => cd,
      cd_ready    => cd_ready
    );

  -- pragma translate_off
  dbg_cd_proc: process (cd, cd_ready) is
  begin
    dbg_cd <= cd;
    dbg_cd.valid <= cd.valid and cd_ready;
  end process;
  -- pragma translate_on

  -- Main decoder. This decodes the element headers and seeks past the literal
  -- data.
  simple_decoder_gen: if not LONG_CHUNKS generate
  begin
    main_dec_inst: vhsnunzip_decoder
      port map (
        clk         => clk,
        reset       => reset,
        cd          => cd,
        cd_ready    => cd_ready,
        el          => el,
        el_ready    => el_ready
      );
  end generate;

  long_decoder_gen: if LONG_CHUNKS generate
  begin
    main_dec_inst: vhsnunzip_decoder_long
      port map (
        clk         => clk,
        reset       => reset,
        cd          => cd,
        cd_ready    => cd_ready,
        el          => el,
        el_ready    => el_ready
      );
  end generate;

  -- pragma translate_off
  dbg_el_proc: process (el, el_ready) is
  begin
    dbg_el <= el;
    dbg_el.valid <= el.valid and el_ready;
  end process;
  -- pragma translate_on

  -- Datapath command generator stage 1. This splits copies up into chunks that
  -- we can handle in a single cycle.
  cmd_gen_1_inst: vhsnunzip_cmd_gen_1
    port map (
      clk         => clk,
      reset       => reset,
      el          => el,
      el_ready    => el_ready,
      c1          => c1,
      c1_ready    => c1_ready
    );

  -- pragma translate_off
  dbg_c1_proc: process (c1, c1_ready) is
  begin
    dbg_c1 <= c1;
    dbg_c1.valid <= c1.valid and c1_ready;
  end process;
  -- pragma translate_on

  -- Datapath command generator stage 2. This splits literal writes up into
  -- chunks, limited by the amount of slots already taken by the copy chunk
  -- that may come before it. It also handles all address generation.
  cmd_gen_2_inst: vhsnunzip_cmd_gen_2
    generic map (
      LONG_CHUNKS => LONG_CHUNKS
    )
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

  -- pragma translate_off
  dbg_cm_proc: process (cm, cm_ready) is
  begin
    dbg_cm <= cm;
    dbg_cm.valid <= cm.valid and cm_ready;
  end process;
  -- pragma translate_on

  -- After the command generator, we don't have backpressure-capable register
  -- slices anymore. Instead, we apply backpressure to the command generator
  -- based on the level of the output FIFO: once it hets too full, we stop
  -- issuing commands. What constitutes "too full" is a bit difficult to
  -- quantify, though. We don't want to stop issuing commands too early,
  -- because it might cause unnecessary stalls, but we can't let it get too
  -- full either, because then the write results might not appear in long-term
  -- memory before short-term runs out. This requires some tweaking, and
  -- eventually a proof of correctness, but I don't have that yet at the time
  -- of writing this comment and am unlikely to come back and update it.
  cm_ready <= not backpres and (lt_rd_ready or not cm.lt_val);
  cm_push <= cm.valid and cm_ready;

  -- Issue the long-term read command.
  lt_rd_valid <= cm.lt_val and cm.valid and not backpres;
  lt_rd_adev <= cm.lt_adev;
  lt_rd_adod <= cm.lt_adod;

  -- Command FIFO. This bridges the latency of the long-term storage access.
  -- The latency between long-term read request access acknowledgement and
  -- response should be significantly shorter than the command FIFO (otherwise
  -- the literal data FIFO would probably overflow first), so this FIFO should
  -- never overflow.
  cm_ctrl(0) <= cm.lt_val;
  cm_ctrl(1) <= cm.lt_swap;
  cm_ctrl(6 downto 2) <= std_logic_vector(cm.st_addr);
  cm_ctrl(10 downto 7) <= std_logic_vector(cm.cp_rol);
  cm_ctrl(11) <= cm.cp_rle;
  cm_ctrl(15 downto 12) <= std_logic_vector(cm.cp_end);
  cm_ctrl(19 downto 16) <= std_logic_vector(cm.li_rol);
  cm_ctrl(23 downto 20) <= std_logic_vector(cm.li_end);
  cm_ctrl(24) <= cm.ld_pop;
  cm_ctrl(25) <= cm.last;

  cm_fifo_inst: vhsnunzip_fifo
    generic map (
      CTRL_WIDTH  => 26
    )
    port map (
      clk         => clk,
      reset       => reset,
      wr_valid    => cm_push,
      wr_ctrl     => cm_ctrl,
      rd_valid    => s1_cm.valid,
      rd_ready    => s1_valid,
      rd_ctrl     => s1_cm_ctrl
    );

  s1_cm.lt_val <= s1_cm_ctrl(0);
  s1_cm.lt_swap <= s1_cm_ctrl(1);
  s1_cm.st_addr <= unsigned(s1_cm_ctrl(6 downto 2));
  s1_cm.cp_rol <= unsigned(s1_cm_ctrl(10 downto 7));
  s1_cm.cp_rle <= s1_cm_ctrl(11);
  s1_cm.cp_end <= unsigned(s1_cm_ctrl(15 downto 12));
  s1_cm.li_rol <= unsigned(s1_cm_ctrl(19 downto 16));
  s1_cm.li_end <= unsigned(s1_cm_ctrl(23 downto 20));
  s1_cm.ld_pop <= s1_cm_ctrl(24);
  s1_cm.last <= s1_cm_ctrl(25);

  -- Determine whether all data sources for stage 0 are ready. We just check
  -- the command stream and the long-term storage result (if we're expecting
  -- one); the literal data should always be valid when those two are. There
  -- is a special case for when the previous cycle was the last command; we
  -- always insert a stall cycle afterward, so the datapath has a chance to
  -- push the contents of its output holding register. We can't backpressure
  s1_valid <= s1_cm.valid and (lt_rd_next or not s1_cm.lt_val) and not s2_last;

  -- pragma translate_off
  dbg_s1_proc: process (s1_cm, s1_valid) is
  begin
    dbg_s1 <= s1_cm;
    dbg_s1.valid <= s1_valid;
  end process;
  -- pragma translate_on

  -- Stage 1 logic + stage 1-2 registers.
  s1_reg_proc: process (clk) is

    -- Whether there is data from the previous cycle in the line holding
    -- register. Bit 7 of this is always zero, but included to reduce if
    -- statement spam.
    variable hold_valid   : std_logic_array(0 to 7) := (others => '0');

    -- Thermometer code for the copy and literal end signals. This plus
    -- hold_valid is used to construct the strobe, mux, and hold_valid signals
    -- for the next cycle. Bit 15 of this is always zero, but included to
    -- reduce if statement spam.
    variable cp_end_th    : std_logic_array(0 to 15);
    variable li_end_th    : std_logic_array(0 to 15);

    -- Arcane stuff described in the big comment block further down.
    variable shift        : unsigned(2 downto 0);
    type lookahead_lookup_type is array (natural range <>) of std_logic_array(0 to 127);
    function lookahead_lookup_fn return lookahead_lookup_type is
      variable ret  : lookahead_lookup_type(0 to 7);
      variable acc  : unsigned(3 downto 0);
    begin
      for byte in 0 to 7 loop
        for shif in 0 to 7 loop
          for rot in 0 to 15 loop
            acc := to_unsigned(byte, 4) - rot - shif;
            ret(byte)(shif * 16 + rot) := acc(3);
          end loop;
        end loop;
      end loop;
      return ret;
    end function;
    constant LOOKAHEAD_LOOKUP : lookahead_lookup_type := lookahead_lookup_fn;
    variable li_ahead     : std_logic;
    variable cp_ahead     : std_logic;

    -- Level/state of the literal FIFO.
    variable li_level     : unsigned(4 downto 0) := (others => '1');

    -- Temporary variable for computing short-term SRL address.
    variable st_addr      : unsigned(4 downto 0);

  begin
    if rising_edge(clk) then

      -- Pass trivial signals through.
      s2_valid <= s1_valid;
      s2_lt_val <= s1_cm.lt_val;
      s2_last <= s1_cm.last and s1_valid;
      s2_cnt <= s1_cm.li_end(2 downto 0);

      -- Update the literal FIFO level for the push action that's about to
      -- happen, before the address is used. Therefore we must do it before
      -- we calculate the address.
      if cs_strobe = '1' then
        li_level := li_level + 1;
      end if;

      -- These bits are always zero!
      hold_valid(7) := '0';
      cp_end_th(15) := '0';
      li_end_th(15) := '0';

      -- Convert the cp_end and li_end signals into thermometer code. Note that
      -- if both are zero, everything below becomes no-op, and we have a LUT
      -- input extra here anyway.
      for byte in 0 to 14 loop
        if byte < s1_cm.cp_end then
          cp_end_th(byte) := s1_valid;
        else
          cp_end_th(byte) := '0';
        end if;
        if byte < s1_cm.li_end then
          li_end_th(byte) := s1_valid;
        else
          li_end_th(byte) := '0';
        end if;
      end loop;

      -- Compute arcane value that we need later. See massive comment block.
      if s1_cm.li_end(3) = '1' then
        shift := s1_cm.li_end(2 downto 0);
      else
        shift := "000";
      end if;

      for byte in 0 to 7 loop

        -- Determine whether this byte is a literal or a copy.
        if (cp_end_th(byte) = '1' and li_end_th(byte + 8) = '0') or cp_end_th(byte + 8) = '1' then

          -- Before copy end on the current line, and not used for a literal
          -- on the next line, so this is a copied byte.
          s2_mux_sel(byte) <= '1';

          -- Compute rotate-left amounts for copy.
          if s1_cm.cp_rle = '1' then
            s2_rol_sel(byte) <= s1_cm.cp_rol(2 downto 0) - byte;
          else
            s2_rol_sel(byte) <= s1_cm.cp_rol(2 downto 0);
          end if;

        else

          -- Not a copied byte, so it's a literal.
          s2_mux_sel(byte) <= '0';
          s2_rol_sel(byte) <= s1_cm.li_rol(2 downto 0);

        end if;

        -- We're trying to do a 16-wide rotation with an 8-wide rotator by
        -- exploiting the fact that:
        --
        --  - we only need 8 bytes at a time (though *which* 8 bytes depends on
        --    the command)
        --  - we can determine the addresses with 8-byte granularity on a
        --    byte-by-byte basis*.
        --
        -- *For long-term, we can't determine the addresses exactly, but we get
        -- two lines due to the interleaved RAM organization, so have to do the
        -- final multiplexing somewhere anyway. We just invert this mux select
        -- signal when we need to.
        --
        -- Ultimately, we need to figure out for each destination byte index
        -- whether the byte at the respective source byte index should come
        -- from the current or the lookahead line. That's way too arcane to
        -- reason about, so here's a bunch of tables for half the number of
        -- bytes.
        --
        -- Desired rotation output with don't cares
        -- ----------------------------------------
        --
        -- Row:           requested rotation
        -- Major column:  index of last byte we're interested in (remember that
        --                we only ever need 8 bytes, = 4 in this example
        --                because half width)
        -- Minor column:  destination byte index/byte index in rotated word
        -- Data:          source word byte index
        --
        --         end 0     end 1     end 2     end 3     end 4     end 5     end 6     end 7
        --        ........  ........  ........  ........  ........  ........  ........  ........
        -- rol 0: --------  0-------  01------  012-----  0123----  -1234---  --2345--  ---3456-
        -- rol 1: --------  1-------  12------  123-----  1234----  -2345---  --3456--  ---4567-
        -- rol 2: --------  2-------  23------  234-----  2345----  -3456---  --4567--  ---5670-
        -- rol 3: --------  3-------  34------  345-----  3456----  -4567---  --5670--  ---6701-
        -- rol 4: --------  4-------  45------  456-----  4567----  -5670---  --6701--  ---7012-
        -- rol 5: --------  5-------  56------  567-----  5670----  -6701---  --7012--  ---0123-
        -- rol 6: --------  6-------  67------  670-----  6701----  -7012---  --0123--  ---1234-
        -- rol 7: --------  7-------  70------  701-----  7012----  -0123---  --1234--  ---2345-
        --
        --
        -- Lookahead bits needed
        -- ---------------------
        --
        -- Row/major col: as before
        -- Minor column:  byte index within the actual source word
        -- Data:          0 if the byte comes from the current line (0..3 is
        --                used in the previous table), 1 if it comes from the
        --                lookahead line (4..7 used in the previous table),
        --                - if don't care
        --
        --         end 0     end 1     end 2     end 3     end 4     end 5     end 6     end 7
        --        ........  ........  ........  ........  ........  ........  ........  ........
        -- rol 0: ----      0---      00--      000-      0000      1000      1100      1110
        -- rol 1: ----      -0--      -00-      -000      1000      1100      1110      1111
        -- rol 2: ----      --0-      --00      1-00      1100      1110      1111      0111
        -- rol 3: ----      ---0      1--0      11-0      1110      1111      0111      0011
        -- rol 4: ----      1---      11--      111-      1111      0111      0011      0001
        -- rol 5: ----      -1--      -11-      -111      0111      0011      0001      0000
        -- rol 6: ----      --1-      --11      0-11      0011      0001      0000      1000
        -- rol 7: ----      ---1      0--1      00-1      0001      0000      1000      1100
        --        ''''''''  ''''''''  ''''''''  ''''''''  ''''''''  ''''''''  ''''''''  ''''''''
        --        shift 0   shift 0   shift 0   shift 0   shift 0   shift 1   shift 2   shift 3
        --
        -- Notice that the tables for end index 0..3 match the table for index,
        -- so we can cut the lookup table size in half by precomputing the
        -- "shift" value listed at the bottom of the table. This is the value
        -- we computed earlier. With this, we get the following function:
        --
        --   (to_unsigned(byte, 4) - s1_cm.cp_rol - shift)(3)
        --
        -- which is not legal without an intermediate because VHDL's grammar is
        -- chronically retarded. Furthermore, certain tools will probably mess
        -- this up and turn this single F7 LUT into two or three CARRY8 blocks
        -- by representing it that way, because if those tools would actually
        -- do what they're supposed to, they'd never be able to sell the
        -- garbage performance of certain newer, more buzzwordy tools. So we
        -- build a lookup constant for it.
        li_ahead := LOOKAHEAD_LOOKUP(byte)(to_integer(shift & s1_cm.li_rol));
        cp_ahead := LOOKAHEAD_LOOKUP(byte)(to_integer(shift & s1_cm.cp_rol));

        -- Never lookahead in run-length mode; the index is always in the
        -- first line.
        if s1_cm.cp_rle = '1' then
          cp_ahead := '0';
        end if;

        -- The long-term select bit selects between the two lines we get from
        -- the memory; one even and one odd. The lt_swap command signal
        -- indicates which of these is the current line and which is the
        -- lookahead (swap low -> even = current). If we set the bit low, we
        -- select the even line.
        s2_lt_sel(byte) <= s1_cm.lt_swap xor cp_ahead;

        -- Compute the short-term memory read address for this byte.
        st_addr := s1_cm.st_addr;

        -- If the short-term byte has already been written for this line, go
        -- back one in history.
        if hold_valid(byte) = '1' then
          st_addr := st_addr + 1;
        end if;

        -- Go forward one when lookahead is set.
        if cp_ahead = '1' then
          st_addr := st_addr - 1;
        end if;

        s2_st_addr(byte) <= st_addr;

        -- Compute the literal read address for this byte.
        if li_ahead = '1' then
          s2_li_addr(byte) <= li_level - 1;
        else
          s2_li_addr(byte) <= li_level;
        end if;

        -- Determine hold_valid and the strobe signals for the next cycle.
        s2_int_strb(byte) <= (li_end_th(byte) and not hold_valid(byte))
                          or li_end_th(byte + 8);
        s2_ext_strb(byte) <= li_end_th(byte) and not hold_valid(byte);
        hold_valid(byte)  := ((hold_valid(byte) or li_end_th(byte)) and not li_end_th(7))
                          or li_end_th(byte + 8);

      end loop;

      -- Update the literal FIFO level for the pop action, which functionally
      -- needs to happen after we've read it.
      if s1_valid = '1' and s1_cm.ld_pop = '1' then
        li_level := li_level - 1;
      end if;

      -- Reset the state of the holding register if this is the last command.
      if s1_valid = '1' and s1_cm.last = '1' then
        hold_valid := (others => '0');
      end if;

      if reset = '1' then
        s2_valid <= '0';
        hold_valid := (others => '0');
        li_level := (others => '1');
      end if;
    end if;
  end process;

  -- Short-term memory SRLs.
  st_srl_gen: for byte in 0 to 7 generate
  begin
    srl_inst: vhsnunzip_srl
      generic map (
        WIDTH       => 8,
        DEPTH_LOG2  => 5
      )
      port map (
        clk         => clk,
        wr_ena      => s2_int_strb(byte),
        wr_data     => s2_mux_data(byte),
        rd_addr     => s2_st_addr(byte),
        rd_data     => s2_st_data(byte)
      );
  end generate;

  -- "Load" long-term memory data.
  s2_le_data <= lt_rd_even;
  s2_lo_data <= lt_rd_odd;

  -- Generate the copy source multiplexer.
  s2_cp_data_proc: process (
    s2_st_data, s2_le_data, s2_lo_data,
    s2_lt_val, s2_lt_sel
  ) is
  begin
    for byte in 0 to 7 loop
      if s2_lt_val = '0' then
        s2_cp_data(byte) <= s2_st_data(byte);
      elsif s2_lt_sel(byte) = '0' then
        s2_cp_data(byte) <= s2_le_data(byte);
      else
        s2_cp_data(byte) <= s2_lo_data(byte);
      end if;
    end loop;
  end process;

  -- Generate the main multiplexer/rotator.
  s2_mux_data_proc: process (
    s2_li_data, s2_cp_data, s2_rol_sel, s2_mux_sel
  ) is
    variable idx  : unsigned(2 downto 0);
  begin
    for byte in 0 to 7 loop
      idx := s2_rol_sel(byte) + byte;
      if s2_mux_sel(byte) = '0' then
        s2_mux_data(byte) <= s2_li_data(to_integer(idx));
      else
        s2_mux_data(byte) <= s2_cp_data(to_integer(idx));
      end if;
    end loop;
  end process;

  -- Stage 2-3 registers.
  s2_reg_proc: process (clk) is
  begin
    if rising_edge(clk) then

      -- Passthrough.
      s3_cnt <= s2_cnt;

      -- Assign defaults.
      s3_out_push <= '0';
      s3_out_last <= '0';
      s3_out_cnt <= "1000";
      s3_last_pend <= '0';

      for byte in 0 to 7 loop

        -- Update the holding register only when the stage is valid and the
        -- byte strobe is set.
        if s2_valid = '1' and s2_int_strb(byte) = '1' then
          s3_hold_data(byte) <= s2_mux_data(byte);
        end if;

        -- The output register is don't care when the stage is invalid, so we
        -- can always write it. The data is always the current mux result if
        -- the output byte strobe is set; otherwise the data must be in the
        -- holding register, or the line isn't complete yet.
        if s2_ext_strb(byte) = '1' then
          s3_out_data(byte) <= s2_mux_data(byte);
        else
          s3_out_data(byte) <= s3_hold_data(byte);
        end if;

      end loop;

      -- The line is complete when the last byte is written.
      if s3_last_pend = '1' then

        -- Inserted cycle to push out line holding register contents.
        s3_out_push <= '1';
        s3_out_last <= '1';
        s3_out_cnt <= resize(s3_cnt, 4);

      elsif s2_valid = '1' then

        if s2_last = '1' then

          if s2_int_strb(0) = '1' and s2_ext_strb(0) = '0' then

            -- This was the last command, but it wrote to the holding register,
            -- so we need to insert a cycle. The cycle after the last command
            -- should have been kept invalid by the command generator and a
            -- special case on the read side of the command FIFO, so we should
            -- always be able to do this.
            s3_out_push <= '1';
            s3_last_pend <= '1';

          else

            -- This is the last command, and it isn't using the output holding
            -- register, so we're done.
            s3_out_push <= '1';
            s3_out_last <= '1';

            -- If byte 7 was strobed, the last line happened to be a full line.
            -- If it wasn't, we need to update the count to reflect the size of
            -- the partial line.
            if s2_ext_strb(7) = '0' then
              s3_out_cnt <= resize(s2_cnt, 4);
            end if;

          end if;

        elsif s2_ext_strb(7) = '1' then

          -- Byte 7 was written, so we have a full line to push.
          s3_out_push <= '1';

        end if;

      end if;

      if reset = '1' then
        s3_out_push <= '0';
        s3_last_pend <= '0';
      end if;

    end if;
  end process;

  -- Decompressed data output FIFO.
  s3_out_ctrl(0) <= s3_out_last;
  s3_out_ctrl(4 downto 1) <= std_logic_vector(s3_out_cnt);

  de_fifo_inst: vhsnunzip_fifo
    generic map (
      DATA_WIDTH  => 8,
      CTRL_WIDTH  => 5
    )
    port map (
      clk         => clk,
      reset       => reset,
      wr_valid    => s3_out_push,
      wr_data     => s3_out_data,
      wr_ctrl     => s3_out_ctrl,
      rd_valid    => de.valid,
      rd_ready    => de_ready,
      rd_data     => de.data,
      rd_ctrl     => de_ctrl,
      level       => de_level_s
    );

  de.last <= de_ctrl(0);
  de.cnt <= unsigned(de_ctrl(4 downto 1));
  de_level <= de_level_s;

  -- Determine the maximum output FIFO level for which the command generator
  -- run.
  backpres <= (de_level_s(4) or de_level_s(3) or de_level_s(2)) and not de_level_s(5);

end behavior;
