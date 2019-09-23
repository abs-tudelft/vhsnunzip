library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.vhsnunzip_int_pkg.all;

-- Snappy element decoder supporting only chunks up to and including 64kiB.
entity vhsnunzip_decoder is
  port (
    clk         : in  std_logic;
    reset       : in  std_logic;

    -- Double line compressed data stream input.
    cd          : in  compressed_stream_double;
    cd_ready    : out std_logic;

    -- Element information stream output.
    el          : out element_stream;
    el_ready    : in  std_logic

  );
end vhsnunzip_decoder;

architecture behavior of vhsnunzip_decoder is
begin
  proc: process (clk) is

    -- Input holding register.
    variable cdh    : compressed_stream_double := COMPRESSED_STREAM_DOUBLE_INIT;

    -- Offset of the next element with respect to cdh.data.
    variable off    : unsigned(16 downto 0) := (others => '0');

    -- Next offset, in case the data we're decoding actually consists of
    -- element headers and not literal data/
    variable offns  : unsigned(3 downto 0) := (others => '0');
    variable offn   : unsigned(16 downto 0) := (others => '0');

    -- Same as `off`, but modulo the line width and converted to integer.
    variable ofi    : natural range 0 to 7 := 0;

    -- Output holding register.
    variable elh    : element_stream := ELEMENT_STREAM_INIT;

  begin
    if rising_edge(clk) then

      -- Invalidate the output register if it was shifted out.
      if el_ready = '1' then
        elh.valid := '0';
      end if;

      -- Shift new data into the input when we can.
      if cdh.valid = '0' then
        cdh := cd;
        if cdh.valid = '1' and cdh.first = '1' then
          off := resize(cdh.start, 17);
        end if;
      end if;

      -- Decode when we have valid data and have room for the result.
      if cdh.valid = '1' and elh.valid = '0' then
        elh.valid := '1';

        ---------------------------------------------------------------------
        -- Handle copy elements
        ---------------------------------------------------------------------
        offns := resize(off(2 downto 0), 4);
        ofi := to_integer(off(2 downto 0));

        case cdh.data(ofi)(1 downto 0) is

          when "01" =>
            -- 2-byte copy element.
            elh.cp_val := '1';
            offns := offns + 2;

          when "10" =>
            -- 3-byte copy element.
            elh.cp_val := '1';
            offns := offns + 3;

          when "11" =>
            -- 5-byte copy element. Note that we ignore byte 4 and 5; they
            -- should be zero! Otherwise they'd encode an offset beyond
            -- 64kiB, and we can't decompress chunks larger than that.
            elh.cp_val := '1';
            offns := offns + 5;

          when others =>
            -- Literal element.
            elh.cp_val := '0';

        end case;

        if cdh.data(ofi)(1) = '0' then
          -- 2-byte copy element, or not a copy.
          elh.cp_off := "00000" & unsigned(cdh.data(ofi)(7 downto 5)) & unsigned(cdh.data(ofi + 1));
          elh.cp_len := resize(unsigned(cdh.data(ofi)(4 downto 2)), 6) + 3;

        else
          -- 3- or 5-byte copy element.
          elh.cp_off := unsigned(cdh.data(ofi + 2)) & unsigned(cdh.data(ofi + 1));
          elh.cp_len := unsigned(cdh.data(ofi)(7 downto 2));

        end if;

        ---------------------------------------------------------------------
        -- Handle literal elements
        ---------------------------------------------------------------------
        ofi := to_integer(offns(2 downto 0));

        if offns > cdh.endi then
          -- No element (for now); beyond end of stream or starts on the next
          -- line.
          elh.li_val := '0';

        elsif cdh.data(ofi)(1 downto 0) /= "00" then
          -- Copy element.
          elh.li_val := '0';

        elsif cdh.data(ofi)(7 downto 4) = "1111" then
          -- Literal with 2- to 5-byte header. Note that we ignore bytes 4 and 5,
          -- which would only be nonzero for literal lengths over 64kiB.
          elh.li_val := '1';
          offns := offns + 2 + unsigned(cdh.data(ofi)(3 downto 2));

        else
          -- Literal with 1-byte header.
          elh.li_val := '1';
          offns := offns + 1;

        end if;

        elh.li_off := offns;

        if std_match(cdh.data(ofi), "111100--") then
          -- Literal with 2-byte header, or not a literal.
          elh.li_len := X"000000" & unsigned(cdh.data(ofi + 1));

        elsif std_match(cdh.data(ofi), "1111----") then
          -- Literal with 3- to 5-byte header, or not a literal.
          elh.li_len := X"0000" & unsigned(cdh.data(ofi + 2)) & unsigned(cdh.data(ofi + 1));

        else
          -- Literal with 1-byte header, or not a literal.
          elh.li_len := X"000000" & "00" & unsigned(cdh.data(ofi)(7 downto 2));

        end if;

        -- Seek past literal data.
        offn := resize(offns, 17);
        if elh.li_val = '1' then
          offn := offn + resize(elh.li_len, 17) + 1;
        end if;

        ---------------------------------------------------------------------

        -- Invalidate the decoded elements if we were actually decoding
        -- literal data from a previously decoded literal, or if both elements
        -- were beyond the end of the stream. All of the above could actually
        -- go inside this if statement, but by doing it this way, the decoded
        -- header information is independent of the result of the condition
        -- (only the valid bits are).
        if off > cdh.endi then
          elh.cp_val := '0';
          elh.li_val := '0';
        else
          off := offn;
        end if;

        -- If our new offset is beyond the current line, invalidate the line
        -- and decrease by 8 accordingly to prepare for the next line. Also
        -- indicate to the datapath that it should pop from the literal line
        -- stream after executing this command to stay in sync.
        if off > cdh.endi then
          off := off - 8;
          cdh.valid := '0';
          elh.ld_pop := '1';
          elh.last := cdh.last;
        else
          elh.ld_pop := '0';
          elh.last := '0';
        end if;

      end if;

      -- Handle reset.
      if reset = '1' then
        cdh.valid := '0';
        elh.valid := '0';
        off := (others => '0');
      end if;

      -- Assign outputs.
      cd_ready <= not cdh.valid;
      el <= elh;

    end if;
  end process;
end behavior;
