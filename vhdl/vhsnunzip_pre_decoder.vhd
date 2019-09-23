library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.vhsnunzip_int_pkg.all;

-- Compressed data stream preprocessor.
entity vhsnunzip_pre_decoder is
  generic (

    -- Whether long chunks (>64kiB) should be supported. If this is disabled,
    -- the core will be a couple hundred LUTs smaller.
    LONG_CHUNKS : boolean := true

  );
  port (
    clk         : in  std_logic;
    reset       : in  std_logic;

    -- Single line compressed data stream input.
    cs          : in  compressed_stream_single;
    cs_ready    : out std_logic;

    -- Double line compressed data stream output.
    cd          : out compressed_stream_double;
    cd_ready    : in  std_logic

  );
end vhsnunzip_pre_decoder;

architecture behavior of vhsnunzip_pre_decoder is
begin
  proc: process (clk) is

    -- Holding register for the current line.
    variable cur    : compressed_stream_single := COMPRESSED_STREAM_SINGLE_INIT;

    -- Holding register for the current next line.
    variable nxt    : compressed_stream_single := COMPRESSED_STREAM_SINGLE_INIT;

    -- Set when we need to pad with invalid to finish a chunk.
    variable pad    : boolean;

    -- Whether the next transfer is the first.
    variable first  : std_logic := '1';

    -- Output holding register.
    variable cdh    : compressed_stream_double := COMPRESSED_STREAM_DOUBLE_INIT;

  begin
    if rising_edge(clk) then

      -- Invalidate the output register if it was shifted out.
      if cd_ready = '1' then
        cdh.valid := '0';
      end if;

      -- Shift new data into the input when we can.
      pad := nxt.valid = '1' and nxt.last = '1';
      if cur.valid = '0' and (cs.valid = '1' or pad) then
        cur := nxt;
        nxt := cs;
        if pad then
          nxt.valid := '0';
        end if;
      end if;

      -- Transfer from the current input to the output.
      if cdh.valid = '0' then
        cdh.valid := cur.valid;
        cdh.data(0 to 7) := cur.data;
        cdh.data(8 to 15) := nxt.data;
        cdh.first := first;

        -- Seek past the uncompressed size varint.
        if LONG_CHUNKS then
          if cur.data(0)(7) = '0' then
            cdh.start := "001";
          elsif cur.data(1)(7) = '0' then
            cdh.start := "010";
          elsif cur.data(2)(7) = '0' then
            cdh.start := "011";
          elsif cur.data(3)(7) = '0' then
            cdh.start := "100";
          else
            cdh.start := "101";
          end if;
        else
          if cur.data(0)(7) = '0' then
            cdh.start := "001";
          elsif cur.data(1)(7) = '0' then
            cdh.start := "010";
          else
            cdh.start := "011";
          end if;
        end if;

        cdh.last := cur.last;
        cdh.endi := cur.endi;
        cur.valid := '0';
      end if;

      -- If output holding register contains the last transfer, the next time
      -- we write to the output holding register we'll be writing the first
      -- transfer of the next chunk.
      if cdh.valid = '1' then
        first := cdh.last;
      end if;

      -- Handle reset.
      if reset = '1' then
        cur.valid := '0';
        nxt.valid := '0';
        first     := '1';
        cdh.valid := '0';
      end if;

      -- Assign outputs.
      cs_ready <= not cur.valid and not (nxt.valid and nxt.last);
      cd <= cdh;

    end if;
  end process;
end behavior;
