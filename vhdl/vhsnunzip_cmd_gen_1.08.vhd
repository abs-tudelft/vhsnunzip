library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.vhsnunzip_int_pkg.all;

-- Decompression datapath command generator stage 1.
entity vhsnunzip_cmd_gen_1 is
  port (
    clk         : in  std_logic;
    reset       : in  std_logic;

    -- Element information input stream.
    el          : in  element_stream;
    el_ready    : out std_logic;

    -- Command output stream.
    c1          : out partial_command_stream;
    c1_ready    : in  std_logic

  );
end vhsnunzip_cmd_gen_1;

architecture behavior of vhsnunzip_cmd_gen_1 is
begin
  proc: process (clk) is

    -- Input holding register.
    variable elh    : element_stream := ELEMENT_STREAM_INIT;

    -- Remaining copy length, diminished-one. The sign bit is an inverted
    -- validity bit.
    variable cp_rem : signed(6 downto 0) := (others => '1');

    -- Output holding register.
    variable c1h    : partial_command_stream := PARTIAL_COMMAND_STREAM_INIT;

  begin
    if rising_edge(clk) then

      -- Invalidate the output register if it was shifted out.
      if c1_ready = '1' then
        c1h.valid := '0';
      end if;

      -- Shift new data into the input when we can.
      if elh.valid = '0' then
        elh := el;
        if elh.valid = '1' then
          assert cp_rem = "1111111";
        end if;
        if elh.valid = '1' and elh.cp_val = '1' then
          cp_rem := signed(resize(elh.cp_len, 7));
        end if;
      end if;

      -- Decode when we have valid data and have room for the result.
      if elh.valid = '1' and c1h.valid = '0' then
        c1h.valid := '1';

        -- Record the current copy offset for the partial command. We might
        -- change it to increase the amount of bytes we can copy per cycle in
        -- a run-length-encoded copy.
        c1h.cp_off := elh.cp_off;

        -- Determine how many bytes we can write for the copy element. If there
        -- is no copy element, this becomes 0 automatically.
        if cp_rem < 8 then
          c1h.cp_len := cp_rem(3 downto 0);
        else
          c1h.cp_len := "0111";
        end if;

        if elh.cp_off <= 1 then

          -- Special case for single-byte repetition, since it's relatively
          -- common and otherwise has worst-case 1-byte/cycle performance.
          -- Requires some extra logic in the address/rotation decoders
          -- though; cp_rol becomes an index rather than a rotation when
          -- cp_rle is set. Can be disabled by just not taking this branch.
          c1h.cp_rle := '1';

        else

          -- Without run-length=1 acceleration, we can't copy more bytes at
          -- once than the copy offset, because we'd be reading beyond what
          -- we've written already.
          if unsigned(c1h.cp_len(2 downto 0)) >= elh.cp_off and c1h.cp_len(3) = '0' then
            c1h.cp_len(2 downto 0) := signed(resize(elh.cp_off(3 downto 0) - 1, 3));

            -- We can however accelerate subsequent copies; after the first
            -- copy we have two consecutive copies in memory, after the
            -- second we have four, and so on. Note that cp_off bit 3 and above
            -- must be zero here, because len was larger and len can be at most
            -- 8, so we can ignore them in the leftshift.
            elh.cp_off(3 downto 0) := elh.cp_off(2 downto 0) & "0";

          end if;

          c1h.cp_rle := '0';

        end if;

        -- Update state.
        cp_rem := cp_rem - (resize(c1h.cp_len, 5) + 1);

        -- Advance if there are no (more) bytes in the copy.
        if cp_rem(6) = '1' then
          elh.valid := '0';
          c1h.li_val := elh.li_val;
          c1h.ld_pop := elh.ld_pop;
          c1h.last := elh.last;
        else
          c1h.li_val := '0';
          c1h.ld_pop := '0';
          c1h.last := '0';
        end if;
        c1h.li_off := elh.li_off;
        c1h.li_len := elh.li_len;

      end if;

      -- Handle reset.
      if reset = '1' then
        elh.valid := '0';
        c1h.valid := '0';
        cp_rem := (others => '1');
      end if;

      -- Assign outputs.
      el_ready <= not elh.valid;
      c1 <= c1h;

    end if;
  end process;
end behavior;
