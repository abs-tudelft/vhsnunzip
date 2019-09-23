library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.vhsnunzip_int_pkg.all;

-- Decompression datapath command generator stage 2.
entity vhsnunzip_cmd_gen_2 is
  generic (

    -- Whether long chunks (>64kiB) should be supported. If this is disabled,
    -- the core will be a couple hundred LUTs smaller.
    LONG_CHUNKS : boolean := true

  );
  port (
    clk         : in  std_logic;
    reset       : in  std_logic;

    -- Preprocessed command input stream.
    c1          : in  partial_command_stream;
    c1_ready    : out std_logic;

    -- Long-term storage first line offset. Must be loaded by strobing ld
    -- for each chunk before chunk processing will start. Alternatively, in
    -- streaming mode with circular history, this can be left unconnected.
    lt_off_ld   : in  std_logic := '1';
    lt_off      : in  unsigned(12 downto 0) := (others => '0');

    -- Command output stream.
    cm          : out command_stream;
    cm_ready    : in  std_logic

  );
end vhsnunzip_cmd_gen_2;

architecture behavior of vhsnunzip_cmd_gen_2 is
begin
  proc: process (clk) is

    -- Input holding register.
    variable c1h    : partial_command_stream := PARTIAL_COMMAND_STREAM_INIT;

    -- Virtual long-term memory line write pointer. Used to compute the read
    -- pointers from the relative offsets in the copy elements. lt_val stores
    -- whether the pointer is valid.
    variable lt_val : std_logic;
    variable lt_ptr : unsigned(12 downto 0);

    -- Elements are available in c1h that we can't load yet because we're still
    -- busy with a literal from the previous element transfer.
    variable c1_pend: std_logic;

    -- Preprocessed copy length. The sign bit is an inverted validity bit.
    variable cp_len : signed(3 downto 0) := (others => '1');

    -- Temporary variables used during decoding.
    variable cp_rel : signed(16 downto 0);
    variable cp_lt  : unsigned(12 downto 0);
    variable len    : unsigned(3 downto 0);

    -- Remaining literal length, diminished-one. The sign bit is an inverted
    -- validity bit.
    function li_high_fn return natural is
    begin
      if LONG_CHUNKS then
        return 32;
      else
        return 16;
      end if;
    end function;
    variable li_len : signed(li_high_fn downto 0) := (others => '1');

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

    -- Stall signal to insert at least one delay cycle after the last transfer
    -- for a chunk.
    variable stall  : std_logic;

  begin
    if rising_edge(clk) then

      -- If we just shifted out the last transfer, block for one cycle. This
      -- cycle is potentially needed in the datapath, for it to push out the
      -- contents of its holding register.
      stall := cmh.valid and cm_ready and cmh.last;

      -- Invalidate the output register if it was shifted out.
      if cm_ready = '1' then
        cmh.valid := '0';
      end if;

      -- Shift new data into the input when we can.
      if c1h.valid = '0' and lt_val = '1' then
        c1h := c1;
        if c1h.valid = '1' then
          c1_pend := not c1h.cp_len(3) or c1h.li_val;
        end if;
      end if;

      -- Decode when we have valid data and have room for the result.
      if c1h.valid = '1' and cmh.valid = '0' and stall = '0' then
        cmh.valid := '1';

        -- If we're out of stuff to do, load the next commands.
        if li_len(li_len'high) = '1' and c1_pend = '1' then
          cp_len := c1h.cp_len;
          if c1h.li_val = '1' then
            li_len := signed(resize(c1h.li_len, li_len'length));
          end if;
          li_off := c1h.li_off;
          c1_pend := '0';
        end if;

        -- Compute copy source addresses. cp_rel(..3) = relative line;
        -- 0 = current line, positive is further forward.
        cp_rel := signed(resize(off, 17)) - signed(resize(c1h.cp_off, 17));

        -- Compute short-term address. This coincidentally works out to a
        -- carry-free operation!
        cmh.st_addr := not unsigned(cp_rel(7 downto 3));

        -- Compute long-term addresses. This unfortunately is not exactly
        -- carry-free...
        cp_lt := lt_ptr + unsigned(cp_rel(15 downto 3));
        cmh.lt_swap := cp_lt(0);
        cmh.lt_adev := cp_lt(12 downto 1) + cp_lt(0 downto 0);
        cmh.lt_adod := cp_lt(12 downto 1);

        -- If we need to read too far back for the short term memory to reach
        -- in all cases, use the long-term memory. The reason for the
        -- separation between short- and long-term by the way, is that the
        -- short-term memory is a single-cycle-access SRL-based memory (so we
        -- can read back the results from the previous cycle immediately),
        -- while the long-term memory is pipelined, has port arbiters, and so
        -- on, so it has significant write-to-read latency.
        if cp_rel(16 downto 3) < -31 then
          cmh.lt_val := not cp_len(3);
        else
          cmh.lt_val := '0';
        end if;

        -- Determine the rotation/byte mux selection.
        cmh.cp_rle := c1h.cp_rle;
        if c1h.cp_rle = '1' then
          cmh.cp_rol := "0" & unsigned(cp_rel(2 downto 0));
        else
          cmh.cp_rol := unsigned(cp_rel(2 downto 0)) - off;
        end if;

        -- Determine how many byte slots are still available for the literal.
        budget := unsigned(cp_len(3 downto 0)) xor "0111";

        -- Update state for copy.
        off := off + unsigned(cp_len) + 1;

        -- Thanks to the preprocessing in stage 1, each copy command can be
        -- handled in a single cycle, so we're done with it now.
        cp_len := (others => '1');

        -- Save the offset after the copy so the datapath can derive which
        -- bytes should come from the copy path.
        cmh.cp_end := off;

        -- Determine how many literal bytes we can write.
        if li_len < signed(resize(budget, li_len'length)) then
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

        -- Determine the rotation for the literal.
        cmh.li_rol := li_off - off;

        -- Update state for literal.
        off := off + len;
        li_off := li_off + len;
        li_len := li_len - signed(resize(len, li_len'length));

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

        -- Don't advance
        --  - if we still have pending elements (that is, we're still writing
        --    literals from the previous record);
        --  - if we're still copying;
        --  - when we still need more literal data from this element. This is
        --    possible if we ran out of write budget for this cycle;
        --  - if this is the last element input stream entry, and we're not
        --    completely done yet.
        if c1_pend = '1' then
          advance := false;
        end if;

        -- Don't advance when we still need more literal data from this
        -- element. This is possible if we ran out of write budget for this
        -- cycle.
        if li_len(li_len'high) = '0' and li_off < 8 then
          advance := false;
        end if;

        -- If this is the last element input stream entry, don't advance until
        -- we're completely done with it (not just done with decoding it).
        if c1h.last = '1' and li_len(li_len'high) = '0' then
          advance := false;
        end if;

        -- Invalidate the element record when we have no more need for it, so
        -- the next record can be loaded.
        if advance then
          c1h.valid := '0';
          cmh.ld_pop := c1h.ld_pop;
          cmh.last := c1h.last;
          li_off := li_off - 8;
          if c1h.last = '1' then
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
        c1h.valid := '0';
        cmh.valid := '0';
        lt_val := '0';
        c1_pend := '0';
        cp_len := (others => '1');
        li_len := (others => '1');
        off := (others => '0');
      end if;

      -- Assign outputs.
      c1_ready <= lt_val and not c1h.valid;
      cm <= cmh;

    end if;
  end process;
end behavior;
