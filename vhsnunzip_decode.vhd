library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.vhsnunzip_pkg.all;

entity vhsnunzip_decode is
  generic (

    -- Decompression history memory access latency.
    HIST_LAT  : natural := 4

  );
  port (
    clk       : in  std_logic;
    reset     : in  std_logic;

    -- Compressed element input stream. If first is set, start indicates the
    -- index of the first byte of the first element. If last is set, end
    -- indicates the index of the last byte of the last element; otherwise it
    -- must be "1111".
    co_valid  : in  std_logic;
    co_ready  : out std_logic;
    co_data   : in  byte_array(0 to 15);
    co_first  : in  std_logic;
    co_start  : in  std_logic_vector(3 downto 0);
    co_last   : in  std_logic;
    co_end    : in  std_logic_vector(3 downto 0);

    -- Decompressed data output stream. This may produce data between reception
    -- of the first compressed element and transmission of the last
    -- decompressed data element, indicated with last. There is no
    -- backpressure, so the memory must be able to sustain 16 bytes per cycle
    -- during decompression.
    de_valid  : out std_logic;
    de_data   : out byte_array(0 to 15);
    de_last   : out std_logic;

    -- Decompression history read request. The address is represented in units
    -- of 16 bytes relative to the first line of decompressed data. However,
    -- 32 bytes must be returned from this address onwards. This is equivalent
    -- to 4 four URAM ports or 8 BRAM ports, equivalent to 2 URAMs blocks or
    -- 4 BRAM blocks (16 BRAMs are needed in total though to get to 64kiB).
    hia_valid : out std_logic;
    hia_ready : in  std_logic;
    hia_addr  : out std_logic_vector(11 downto 0);

    -- Decompression history read response. hir_valid is expected to be high
    -- (along with valid data) HIST_LAT cycle(s) after hia_valid and hia_ready
    -- are both high.
    hir_valid : in  std_logic;
    hir_data  : in  byte_array(0 to 31)

  );
end vhsnunzip_decode;

architecture behavior of vhsnunzip_decode is

  -- Returns 'U' during simulation, but '0' during synthesis.
  function undef_fn return std_logic is
    variable undef: std_logic := '0';
  begin
    -- pragma translate_off
    undef := 'U';
    -- pragma translate_on
    return undef;
  end function;
  constant UNDEF    : std_logic := undef_fn;

  -----------------------------------------------------------------------------
  -- Compressed data input stage state
  -----------------------------------------------------------------------------
  constant PL_COIN  : natural := 0;
  type coin_state is record

    -- Whether we're ready for new input.
    ready     : std_logic;

    -- Compressed data buffer. Data/hld_valid are shifted in MSB-first.
    hld_valid : std_logic_vector(1 downto 0);
    data      : byte_array(0 to 31);

    -- Whether new data was shifted into the data register. This implies that
    -- the bytes in data from start to endi inclusive are valid.
    valid     : std_logic;

    -- co_data indices of the first byte of the next element to decode, and the
    -- index of the last valid byte. co_start is only valid when co_first is
    -- set.
    first     : std_logic;
    start     : std_logic_vector(3 downto 0);
    last      : std_logic;
    endi      : std_logic_vector(4 downto 0);

    -- This is set when the last element has been pulled into the pipeline to
    -- block the input stream. It is cleared by the last pipeline stage when it
    -- processes the last line of decompressed data.
    draining  : std_logic;

  end record;
  constant COIN_INIT : coin_state := (
    ready     => '0',
    hld_valid => "00",
    data      => (others => (others => UNDEF)),
    valid     => '0',
    first     => UNDEF,
    start     => (others => UNDEF),
    last      => UNDEF,
    endi      => (others => UNDEF),
    draining  => '0'
  );

  -----------------------------------------------------------------------------
  -- Stage for decoding lengths of element headers and bodies
  -----------------------------------------------------------------------------
  constant PL_COLE  : natural := 1;
  type hdlen_array is array (natural range <>) of std_logic_vector(1 downto 0);
  type litlen_array is array (natural range <>) of std_logic_vector(15 downto 0);
  type cole_state is record

    -- Header length for the first 16 element starting positions in co_data.
    -- 0 is used to signal an unsupported element type.
    hdlen     : hdlen_array(0 to 15);

    -- Literal length for the first 16 element starting positions in co_data.
    -- This is zero for copy elements.
    litlen    : litlen_array(0 to 15);

  end record;
  constant COLE_INIT : cole_state := (
    hdlen  => (others => (others => UNDEF)),
    litlen => (others => (others => UNDEF))
  );

  -- TODO
  constant PL_MAX : natural := 3;

  -- Pipeline state record. The pipeline as a whole, as well as each pipeline
  -- stage, is associated with a variable of this type. Note that most members
  -- are not actually used by all stages; unused members should be
  -- constant-propagated and pruned away during preliminary synthesis. They are
  -- useful when debugging in simulation, however, to get a consistent view of
  -- the decoding state for each pipeline stage.
  type pipeline_type is record
    coin      : coin_state;
    cole      : cole_state;
  end record;
  constant PIPELINE_INIT : pipeline_type := (
    coin => COIN_INIT,
    cole => COLE_INIT
  );
  type pipeline_array is array (natural range <>) of pipeline_type;

  -- State register, containing the state of each pipeline stage.
  signal state  : pipeline_type;

  -- Pipeline stage registers.
  signal stages : pipeline_array(1 to PL_MAX);

begin

  pipeline_proc: process (clk) is
    variable s  : pipeline_type;
    variable r  : pipeline_array(0 to PL_MAX-1);
  begin
    if rising_edge(clk) then

      -- Load the pipeline state from the previous cycle.
      s := state;
      r(0) := PIPELINE_INIT;
      r(1 to PL_MAX-1) := stages(1 to PL_MAX-1);

      -------------------------------------------------------------------------
      -- PL_COIN: accept/parallelize incoming compressed data
      -------------------------------------------------------------------------
      if s.coin.ready = '1' and (co_valid = '1' or s.coin.draining = '1') then

        -- Clear the first flag if we're shifting data out.
        if s.coin.hld_valid(0) = '1' then
          s.coin.first := '0';
          s.coin.start := "0000";
        end if;

        -- Shift the shift register.
        s.coin.hld_valid(0) := s.coin.hld_valid(1);
        s.coin.data(0 to 15) := s.coin.data(16 to 31);
        s.coin.valid := s.coin.hld_valid(1);

        if s.coin.draining = '1' then

          -- When draining, pad with invalid.
          if s.coin.endi(4) = '0' then
            s.coin.valid := '0';
          end if;
          s.coin.hld_valid(1) := '0';
          s.coin.endi(4) := '0';
          s.coin.last := '1';

        else

          -- When not draining, shift in compressed data.
          s.coin.hld_valid(1) := '1';
          s.coin.data(16 to 31) := co_data;
          if co_first = '1' then
            s.coin.first := co_first;
            s.coin.start := co_start;
          end if;
          s.coin.draining := co_last;
          s.coin.last := '0';
          s.coin.endi := "1" & co_end;

          assert co_last = '1' or co_end = "1111"
            report "co_end must be all ones for all transfers but the last"
            severity error;

        end if;

      else

        -- Not ready for a shift for whatever reason (stall from upstream
        -- and/or downstream).
        s.coin.valid := '0';

      end if;

      r(PL_COIN).coin := s.coin;

      -------------------------------------------------------------------------
      -- PL_COLE: stage for decoding lengths of element headers and bodies
      -------------------------------------------------------------------------
      -- To quickly decode up to a copy and a literal element in a single
      -- cycle, we decode the header and literal lengths for all 16 possible
      -- start locations in parallel. Then we multiplex those twice to get the
      -- start positions of the next (up to) two elements, which are then used
      -- to multiplex the element headers themselves.
      --
      -- The header size of a Snappy element is fully determined by its first
      -- byte, as follows:
      --
      --  - 0b0-----00: literal, 1 header byte
      --  - 0b10----00: literal, 1 header byte
      --  - 0b110---00: literal, 1 header byte
      --  - 0b1110--00: literal, 1 header byte
      --  - 0b11110000: literal, 2 header bytes
      --  - 0b11110100: literal, 3 header bytes
      --  - 0b11111000: literal, 4 header bytes (not supported)
      --  - 0b11111100: literal, 5 header bytes (not supported)
      --  - 0b------01: copy, 2 header bytes
      --  - 0b------10: copy, 3 header bytes
      --  - 0b------11: copy, 5 header bytes (not supported)
      --
      -- However, we don't need to support all of these:
      --
      --  - literals with 4-byte headers are used to encode literals between
      --    65537 and 16777216 bytes in length, while literals with 5-byte
      --    headers are used for literals between 16777217 and 4294967296 bytes
      --    in length. While it is permissible for a compressor to use these
      --    longer elements for 65536 or less bytes as well, it would not be
      --    very efficient, so we make the assumption that it won't do this.
      --    Since we only support blocks up to 64kiB in (decompressed) size,
      --    we have no need for longer literals.
      --  - 5-byte copy elements are used to encode offsets beyond 64kiB. As
      --    above, while it is legal to encode shorter offsets with this
      --    format, it would not be efficient, so we don't need to support
      --    them.
      --
      -- This means two things:
      --
      --  - We only need to handle headers between 1 and 3 bytes, which saves
      --    multiplexer LUTs that handle header alignment before further
      --    decoding.
      --  - We need a way to signal an error when we encounter an unsupported
      --    element header.
      --
      -- We can signal all four of those conditions with just two bits, using
      -- zero for errors.
      for idx in 0 to 15 loop
        case r(PL_COLE).coin.data(idx)(1 downto 0) is
          when "00" =>
            case r(PL_COLE).coin.data(idx)(7 downto 2) is
              when "111100" => s.cole.hdlen(idx) := "10"; -- 2-byte literal
              when "111101" => s.cole.hdlen(idx) := "11"; -- 3-byte literal
              when "111110" => s.cole.hdlen(idx) := "00"; -- 4-byte literal
              when "111111" => s.cole.hdlen(idx) := "00"; -- 5-byte literal
              when others   => s.cole.hdlen(idx) := "01"; -- 1-byte literal
            end case;
          when "01"   => s.cole.hdlen(idx) := "10"; -- 2-byte copy
          when "10"   => s.cole.hdlen(idx) := "11"; -- 3-byte copy
          when others => s.cole.hdlen(idx) := "00"; -- 5-byte copy
        end case;
      end loop;

      -- For the element types we support, the literal body length is encoded
      -- as follows:
      --
      --  - 0bLLLLLL00: length = L + 1
      --  - 0b11110000 0bLLLLLLLL: length = L + 1
      --  - 0b11110100 0bLLLLLLLL 0bLLLLLLLL: length = L + 1 (little endian)
      --  - others: copy/unsupported, so length is zero
      for idx in 0 to 15 loop
        if r(PL_COLE).coin.data(idx)(1 downto 0) = "00" then
          if r(PL_COLE).coin.data(idx) = "11110000" then
            -- Literal with 2-byte header.
            s.cole.litlen(idx) := X"00" & r(PL_COLE).coin.data(idx + 1);
          elsif r(PL_COLE).coin.data(idx) = "11110100" then
            -- Literal with 3-byte header.
            s.cole.litlen(idx) := r(PL_COLE).coin.data(idx + 2)
                                & r(PL_COLE).coin.data(idx + 1);
          else
            -- Literal with 1-byte header.
            s.cole.litlen(idx) := X"00" & "00" & r(PL_COLE).coin.data(idx)(7 downto 2);
          end if;
          s.cole.litlen(idx) := std_logic_vector(unsigned(s.cole.litlen(idx)) + 1);
        else
          -- Copy or unsupported element.
          s.cole.litlen(idx) := X"0000";
        end if;
      end loop;

      r(PL_COLE).cole := s.cole;

      -- TODO
      s.coin.ready := '1';
      de_valid <= s.coin.valid;
      de_data <= s.coin.data(0 to 15);
      de_last <= s.coin.last;


      -------------------------------------------------------------------------
      -- End of last stage
      -------------------------------------------------------------------------
      -- Handle reset.
      if reset = '1' then
        s := PIPELINE_INIT;
        r := (others => PIPELINE_INIT);
      end if;

      -- Save the pipeline state for the next cycle.
      state <= s;

      -- Shift the stage registers.
      stages(1 to PL_MAX) <= r(0 to PL_MAX-1);

      -- Assign output signals.
      co_ready <= s.coin.ready and not s.coin.draining;

    end if;
  end process;

end behavior;
