library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Snappy element decoder. Consumes a parallel bytestream (WI bytes per cycle)
-- to decode up to one copy and one literal element per cycle.
entity vhsnunzip_decode is
  generic (

    -- Whether this unit checks for and reports errors gracefully, or just
    -- crashes and burns.
    CHECK_ERRORS : boolean := true

  );
  port (
    clk         : in  std_logic;
    reset       : in  std_logic;

    -- Compressed data stream input.
    co_valid    : in  std_logic;
    co_ready    : out std_logic;
    co_payld    : in  compressed_stream_payload;

    -- Element information stream output.
    el_valid    : out std_logic;
    el_ready    : in  std_logic;
    el_payld    : out element_stream_payload

    -- Error indicator. When an error occurs, this unit asserts the err_occ
    -- (error occurred) flag, along with some diagnostic information. Behavior
    -- after an error is undefined otherwise. The only way to recover from
    -- this is to reset the entire decompression engine.
    --
    -- err_typ codes:
    --  - "00": decompressed length > 64kiB. In this case, only a single
    --    8-byte 0xDEADCODEDECOADDE literal is returned as the decompression
    --    result.
    --  - "01": unsupported element encountered. This decoder supports only
    --    1-, 2-, and 3-byte element headers, since the 4- and 5- byte headers
    --    would normally only be generated for chunks larger than 64kiB.
    --  - "10": invalid offset in copy. The offset is either 0 or greater than
    --    the number of bytes decompressed so far.
    --  - "11": mismatch between decompressed length in header and actual
    --    decompressed length so far.
    --
    -- err_off: the approximate (!) offset in the compressed chunk that caused
    -- the error.
    err_occ     : out std_logic;
    err_typ     : out std_logic_vector(1 downto 0);
    err_off     : out std_logic_vector(16 downto 0)

  );
end vhsnunzip_decode;

architecture behavior of vhsnunzip_decode is

  constant DEADCODE : byte_array(0 to 7) := (
    0 => X"DE", 1 => X"AD", 2 => X"C0", 3 => X"DE",
    4 => X"DE", 5 => X"C0", 6 => X"AD", 7 => X"DE");

  type state_type is record

    -- Compressed data holding register to break critical path.
    co_slc_valid  : std_logic;
    co_slc_payld  : compressed_stream_payload;

    -- Whether we're ready for new input. Setting this causes el_data to be
    -- shifted forward by 8 bytes/one line.
    ready         : std_logic;

    -- Compressed data holding register for parallelization.
    co_hld_valid  : std_logic;
    co_hld_payld  : compressed_stream_payload;

    -- Whether we're currently decompressing or not. Used to determine
    -- el_first.
    co_busy       : std_logic;

    -- Whether we currently have valid element data. When we're done with the
    -- current line, this is cleared, so we (try to) pull in more data in the
    -- next cycle.
    co_valid      : std_logic;

    -- The current line of element data, plus the next line.
    co_data       : byte_array(0 to 15);

    -- The offset in co_data where we need to look for the next element.
    co_off        : unsigned(16 downto 0);

    -- Whether this is the last line of element data, and if so, the index of
    -- the last byte of the last element.
    co_last       : std_logic;
    co_endi       : std_logic_vector(2 downto 0);

    -- Number of remaining decompressed bytes. Used for error detection.
    de_rem        : unsigned(17 downto 0);
  end record;

  variable state  : state_type;

begin

  reg_proc: process (clk) is
    variable s      : state_type;
    variable off    : natural range 0 to 7;
    variable unsup  : boolean;
  begin
    if rising_edge(clk) then
      s := state;

      -------------------------------------------------------------------------
      -- Pull in new data
      -------------------------------------------------------------------------
      if s.co_valid = '0' and (co_valid = '1' or s.draining = '1') then

        -- Take the lookahead data from the incoming line.
        s.co_data(8 to 15) := co_payld.data;

        -- Take the current (meta)data from the holding register.
        s.co_valid := s.co_hld_valid;
        s.co_data(0 to 7) := s.co_hld_payld.data;
        s.co_last := s.co_hld_payld.last;
        s.co_endi := s.co_hld_payld.endi;

        -- Update the holding register.
        s.co_hld_valid := co_valid;
        s.co_hld_payld := co_payld;

        -- If we're not busy yet, this is the first line. Each Snappy chunk
        -- starts with some metadata to indicate the length of the chunk, which
        -- we need to decode to check for errors,  and then strip off so it
        -- doesn't get decoded as element data.
        if s.co_busy = '0' then
          s.co_off := "0001";
          s.de_rem := (others => '0');
          s.de_rem(6 downto 0) := unsigned(s.co_data(0)(6 downto 0));
          if s.co_data(0)(7) = '1' then
            s.de_rem(13 downto 7) := unsigned(s.co_data(1)(6 downto 0));
            s.co_off := "0010";
            if s.co_data(1)(7) = '1' then
              s.de_rem(16 downto 14) := unsigned(s.co_data(2)(2 downto 0));
              s.co_off := "0011";
              if s.err_occ = '0' and s.de_rem > 65536 or s.co_data(2)(7 downto 3) /= "00000" then
                -- Error: decompressed length too long.
                s.err_off := (others => '0');
                s.err_occ := '1';
                s.err_typ := "00";
              end if;
            end if;
          end if;
        end if;

        -- Update busy state.
        if s.co_valid = '1' and s.co_last = '1' then
          s.co_busy := '0';
        end if;

      end if;

      -------------------------------------------------------------------------
      -- Decode elements
      -------------------------------------------------------------------------
      -- We always decode elements from the data buffer, regardless of whether
      -- that data buffer is actually valid and we need to advance the state.
      -- This should hopefully reduce the logic here a little; if we would only
      -- run this when we actually need it, that'd just add those conditions to
      -- all the decoders. It's much better to just use a byte
      co_off := s.co_off(2 downto 0);

      -- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
      -- Decode copy elements
      -- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
      off := to_integer(co_off(2 downto 0));

      case s.co_data(off)(1 downto 0) is

        when "01" =>
          -- 2-byte copy element.
          cp_valid := '1';
          cp_error := '0';
          co_off := co_off + 2;

        when "10" =>
          -- 3-byte copy element.
          cp_valid := '1';
          cp_error := '0';
          co_off := co_off + 3;

        when "11" =>
          -- 5-byte copy element. Note that we ignore byte 4 and 5; they should
          -- be zero! Otherwise they'd encode an offset beyond 64kiB, and we
          -- can't decompress chunks larger than that. Since Snappy should
          -- never output these longer elements when the shorter ones suffice,
          -- we treat this type of node as an error.
          cp_valid := '1';
          cp_error := '1';
          co_off := co_off + 5;

        when others =>
          -- Literal element.
          cp_valid := '0';
          cp_error := '0';

      end case;

      if s.co_data(off)(1) = '0' then
        -- 2-byte copy element, or not a copy.
        cp_off := "00000" & s.co_data(off)(7 downto 5) & s.co_data(off + 1);
        cp_len := std_logic_vector(resize(unsigned(s.co_data(off)(4 downto 2)), 6) + 3);

      else
        -- 3- or 5-byte copy element.
        cp_off := s.co_data(off + 2) & s.co_data(off + 1);
        cp_len := s.co_data(off)(7 downto 2);

      end if;

      -- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
      -- Decode literal elements
      -- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
      off := to_integer(co_off(2 downto 0));

      if s.co_data(off)(1 downto) /= "00" or cp_off(3 downto 0) > resize(unsigned(co_endi), 4) then
        -- Copy element or beyond end of stream.
        li_valid := '0';

      if std_match(s.co_data(off), "1111--00") then
        -- Literal with 2- to 5-byte header. Note that we ignore bytes 4 and 5,
        -- which would only be nonzero for literal lengths over 64kiB. Snappy
        -- should never output these longer elements when the shorter ones
        -- suffice, so we treat this type of node as an error.
        li_valid := '1';
        co_off := co_off + 1 + unsigned(s.co_data(off)(3 downto 2));

      elsif std_match(s.co_data(off), "------00") then
        -- Literal with 1-byte header.
        li_valid := '1';
        co_off := co_off + 1;

      end if;

      if std_match(s.co_data(off), "11111---") then
        -- Literal with 4- or 5-byte header, or not a literal.
        li_error := '1';

      else
        -- Literal with 1- to 3-byte header, or not a literal.
        li_error := '0';

      end if;

      li_off := co_off;

      if std_match(s.co_data(off), "111100--") then
        -- Literal with 2-byte header, or not a literal.
        li_len := "00000000" & s.co_data(off + 1);

      elsif std_match(s.co_data(off), "1111----") then
        -- Literal with 3- to 5-byte header, or not a literal.
        li_len := s.co_data(off + 2) & s.co_data(off + 1);

      else
        -- Literal with 1-byte header, or not a literal.
        li_len := "0000000000" & s.co_data(off)(7 downto 2);

      end if;

      if li_valid = '1' then
        co_off := co_off + resize(unsigned(li_len), 17) + 1;
      end if;

      -------------------------------------------------------------------------
      -- Update state
      -------------------------------------------------------------------------
      if s.co_valid = '1' and s.el_valid = '0' then

        

      end if;

      -- Handle supported copy elements.

      -- Handle reset.
      if reset = '1' then
        ready := '0';
      end if;

      

      state <= s;
    end if;
  end process;

end behavior;
