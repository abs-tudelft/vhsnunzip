library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.vhsnunzip_pkg.all;

-- Decompression datapath command generator.
entity vhsnunzip_cmd_gen is
  port (
    clk         : in  std_logic;
    reset       : in  std_logic;

    -- Element information input stream.
    el          : in  element_stream;
    el_ready    : out std_logic;

    -- Long-term storage first line offset. Must be loaded by strobing ld
    -- for each chunk before chunk processing will start. Alternatively, in
    -- streaming mode with circular history, this can be left unconnected.
    lt_off_ld   : in  std_logic := '1';
    lt_off      : in  unsigned(12 downto 0) := (others => '0');

    -- Command output stream.
    cm          : out command_stream;
    cm_ready    : in  std_logic

  );
end vhsnunzip_cmd_gen;

architecture behavior of vhsnunzip_cmd_gen is
begin
  proc: process (clk) is

    -- Input holding register.
    variable elh    : element_stream := ELEMENT_STREAM_INIT;

    -- Virtual long-term memory line write pointer. Used to compute the read
    -- pointers from the relative offsets in the copy elements. lt_val stores
    -- whether the pointer is valid.
    variable lt_val : std_logic;
    variable lt_ptr : unsigned(12 downto 0);

    -- Elements are available in elh that we can't load yet because we're still
    -- busy with a literal from the previous element transfer.
    variable el_pend: std_logic;

    -- Remaining copy length, diminished-one. The sign bit is an inverted
    -- validity bit.
    variable cp_len : signed(6 downto 0) := (others => '1');

    -- Temporary variables used during decoding.
    variable cp_rel : signed(16 downto 0);
    variable cp_lt  : unsigned(12 downto 0);
    variable len    : unsigned(3 downto 0);

    -- Remaining literal length, diminished-one. The sign bit is an inverted
    -- validity bit.
    variable li_len : signed(16 downto 0) := (others => '1');

    -- Remaining literal length, diminished-one.
    variable li_off : unsigned(3 downto 0);

    -- Current decompressed line offset.
    variable off    : unsigned(3 downto 0);

    -- Number of bytes we can (still) write this cycle.
    variable budget : unsigned(3 downto 0);

    -- Temporary flag, representing whether we can advance to the next element
    -- information record.
    variable advance: boolean;

    -- Output holding register.
    variable cmh    : command_stream := COMMAND_STREAM_INIT;

  begin
    if rising_edge(clk) then

      -- Invalidate the output register if it was shifted out.
      if cm_ready = '1' then
        cmh.valid := '0';
      end if;

      -- Shift new data into the input when we can.
      if elh.valid = '0' and lt_val = '1' then
        elh := el;
        if elh.valid = '1' then
          el_pend := elh.cp_val or elh.li_val;
        end if;
      end if;

      -- Decode when we have valid data and have room for the result.
      if elh.valid = '1' and cmh.valid = '0' then
        cmh.valid := '1';

        -- If we're out of stuff to do, load the next commands.
        if li_len < 0 and el_pend = '1' then
          if elh.cp_val = '1' then
            cp_len := signed(resize(elh.cp_len, 7));
          end if;
          if elh.li_val = '1' then
            li_len := signed(resize(elh.li_len, 17));
          end if;
          li_off := elh.li_off;
          el_pend := '0';
        end if;

        -- Determine the amount of bytes we can write in this cycle. There is
        -- a register in the datapath that allows us to write past the current
        -- line under normal conditions; the extra bytes will be put into the
        -- output holding register in the next cycle. We're still limited to
        -- 8 bytes per cycle this way, but don't have to stall anywhere near as
        -- often. When this is data for the last line though, we shouldn't use
        -- this register.
        budget := "1000";
        if elh.last = '1' then
          budget := budget - off;
        end if;

        -- Compute copy source addresses. cp_rel(..3) = relative line;
        -- 0 = current line, positive is further forward.
        cp_rel := signed(resize(off, 17)) - signed(resize(elh.cp_off, 17));

        -- Compute short-term address. This coincidentally works out to a
        -- carry-free operation!
        cmh.st_addr := not unsigned(cp_rel(7 downto 3));

        -- Compute long-term addresses. This unfortunately is not exactly
        -- carry-free...
        cp_lt := lt_ptr + unsigned(cp_rel(15 downto 3));
        cmh.lt_swap := cp_lt(0);
        cmh.lt_adev := cp_lt(12 downto 1) + cp_lt(0);
        cmh.lt_adod := cp_lt(12 downto 1);

        -- If we need to read too far back for the short term memory to reach
        -- in all cases, use the long-term memory. The reason for the
        -- separation between short- and long-term by the way, is that the
        -- short-term memory is a single-cycle-access SRL-based memory (so we
        -- can read back the results from the previous cycle immediately),
        -- while the long-term memory is pipelined, has port arbiters, and so
        -- on, so it has significant write-to-read latency.
        if cp_rel(16 downto 3) < -31 then
          cmh.lt_val := '1';
        else
          cmh.lt_val := '0';
        end if;

        -- Determine how many bytes we can write for the copy element. If there
        -- is no copy element, this becomes 0 automatically.
        if cp_len < signed(resize(budget, 7)) then
          len := unsigned(cp_len(3 downto 0)) + 1;
        else
          len := budget;
        end if;

        if elh.cp_off <= 1 then

          -- Special case for single-byte repetition, since it's relatively
          -- common and otherwise has worst-case 1-byte/cycle performance.
          -- Requires some extra logic in the address/rotation decoders
          -- though; cp_rol becomes an index rather than a rotation when
          -- cp_rle is set. Can be disabled by just not taking this branch.
          cmh.cp_rle := '1';
          cmh.cp_rol := "0" & unsigned(cp_rel(2 downto 0));

        else

          -- Without run-length=1 acceleration, we can't copy more bytes at
          -- once than the copy offset, because we'd be reading beyond what
          -- we've written already.
          if len > elh.cp_off then
            len := elh.cp_off(3 downto 0);

            -- We can however accelerate subsequent copies; after the first
            -- copy we have two consecutive copies in memory, after the
            -- second we have four, and so on. Note that cp_off bit 3 and above
            -- must be zero here, because len was larger and len can be at most
            -- 8, so we can ignore them in the leftshift.
            elh.cp_off(3 downto 0) := elh.cp_off(2 downto 0) & "0";

          end if;

          cmh.cp_rle := '0';
          cmh.cp_rol := unsigned(cp_rel(2 downto 0)) - off;

        end if;

        -- Update state for copy.
        off := off + len;
        cp_len := cp_len - signed(resize(len, 7));
        budget := budget - len;

        -- Save the offset after the copy so the datapath can derive which
        -- bytes should come from the copy path.
        cmh.cp_end := off;

        -- Handle literal data if we're done with the copy.
        if cp_len < 0 then

          -- Determine how many literal bytes we can write.
          if li_len < signed(resize(budget, 17)) then
            len := unsigned(li_len(3 downto 0)) + 1;
          else
            len := budget;
          end if;

          -- The literal element header could start at byte 7 of the incoming
          -- data line, which means that the literal data might start as far
          -- forward as byte index 10. In this case, we can't write the full
          -- 8 bytes, because the indexation into the lookahead line would
          -- overflow. There are two ways to deal with this; either we limit
          -- len such that it doesn't overflow, or we just don't write any
          -- chunk in this case and wait until the next cycle, when we'll have
          -- advanced a line. The latter costs only a *tiny* bit of throughput
          -- while the latter requires a bit more logic.
          if li_off(3) = '1' then
            len := "0000";
          end if;

        else
          len := "0000";
        end if;

        -- Determine the rotation for the literal.
        cmh.li_rol := li_off - off;

        -- Update state for literal.
        off := off + len;
        li_off := li_off + len;
        li_len := li_len - signed(resize(len, 17));

        -- Save the offset after the literal so the datapath can derive which
        -- bytes should come from the literal path, and how many bytes are
        -- valid.
        cmh.li_end := off;

        -- Carry the MSB of the decompression offset into the line pointer.
        if off(3) = '1' then
          lt_ptr := lt_ptr + 1;
        end if;
        off(3) := '0';

        -- Determine whether we're done with this element information record.
        advance := true;

        -- Don't advance if we still have pending elements (that is, we're
        -- still writing literals from the previous record).
        if el_pend = '1' then
          advance := false;
        end if;

        -- Don't advance if we're still copying.
        if cp_len >= 0 then
          advance := false;
        end if;

        -- Don't advance when we still need more literal data from this
        -- element. This is possible if we ran out of write budget for this
        -- cycle.
        if li_len >= 0 and li_off < 8 then
          advance := false;
        end if;

        -- If this is the last element input stream entry, don't advance until
        -- we're completely done with it (not just done with decoding it).
        if elh.last = '1' and (li_len >= 0 or cp_len >= 0) then
          advance := false;
        end if;

        -- Invalidate the element record when we have no more need for it, so
        -- the next record can be loaded.
        if advance then
          elh.valid := '0';
          cmh.ld_pop := elh.ld_pop;
          cmh.last := elh.last;
          li_off := li_off - 8;
          if elh.last = '1' then
            lt_val := '0';
            off := (others => '0');
          end if;
        else
          cmh.ld_pop := '0';
          cmh.last := '0';
        end if;

      end if;

      -- Load the long-term memory pointer when we get it.
      if lt_val = '0' and lt_off_ld = '1' then
        lt_ptr := lt_off;
        lt_val := '1';
      end if;

      -- Handle reset.
      if reset = '1' then
        elh.valid := '0';
        cmh.valid := '0';
        lt_val := '0';
        el_pend := '0';
        cp_len := (others => '1');
        li_len := (others => '1');
        off := (others => '0');
      end if;

      -- Assign outputs.
      el_ready <= lt_val and not elh.valid;
      cm <= cmh;

    end if;
  end process;
end behavior;
