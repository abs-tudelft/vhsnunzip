library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.vhsnunzip_int_pkg.all;
use work.vhsnunzip_pkg.all;

-- Streaming toplevel for vhsnunzip. This version of the decompressor doesn't
-- include any large-scale input and output stream buffering, so the streams
-- are limited to the speed of the decompression engine. However, because the
-- long-term memory isn't also used for buffering, the decompression engine
-- will never be internally bandwidth-starved, so decompression will be a bit
-- faster.
entity vhsnunzip is
  generic (

    -- Number of decompression cores to instantiate.
    COUNT       : positive := 5;

    -- (Desired) ratio of block RAM to UltraRAM usage, expressed as a fraction.
    -- The defaults below represent the ratio available in most Virtex
    -- Ultrascale+ devices. Set to 8/1 to use only block RAMs; set to 0/1 to
    -- use only UltraRAMs.
    B2U_MUL     : natural := 21;
    B2U_DIV     : positive := 10

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
end vhsnunzip;

architecture behavior of vhsnunzip is

  function imax(a: integer; b: integer) return integer is
  begin
    if a > b then
      return a;
    else
      return b;
    end if;
  end function;

  function log2ceil(i: natural) return natural is
    variable x, y : natural;
  begin
    x := i;
    y := 0;
    while x > 1 loop
      x := (x + 1) / 2;
      y := y + 1;
    end loop;
    return y;
  end function;

  function get_ram_style(
    idx       : natural;
    b2u_m     : natural;
    b2u_d     : positive
  ) return string is
    variable brams  : natural := 0;
    variable urams  : natural := 0;
    variable remain : natural := idx;
  begin
    loop
      if urams * b2u_m / b2u_d > brams then
        if remain = 0 then
          return "BRAM";
        end if;
        brams := brams + 16;
      else
        if remain = 0 then
          return "URAM";
        end if;
        urams := urams + 2;
      end if;
      remain := remain - 1;
    end loop;
  end function;

  constant COUNT_BITS : natural := imax(1, log2ceil(COUNT));

  type snappy_stream is record
    valid     : std_logic;
    data      : std_logic_vector(255 downto 0);
    cnt       : std_logic_vector(4 downto 0);
    last      : std_logic;
  end record;
  type snappy_stream_array is array (natural range <>) of snappy_stream;

  -- Streams for the individual units.
  signal u_in         : snappy_stream_array(0 to COUNT-1);
  signal u_in_ready   : std_logic_array(0 to COUNT-1);
  signal u_out        : snappy_stream_array(0 to COUNT-1);
  signal u_out_ready  : std_logic_array(0 to COUNT-1);

  -- Internal copies of the handshake outputs.
  signal in_ready_i   : std_logic;
  signal out_valid_i  : std_logic;
  signal out_last_i   : std_logic;

  -- Select signals.
  signal in_sel       : unsigned(COUNT_BITS-1 downto 0) := (others => '0');
  signal out_sel      : unsigned(COUNT_BITS-1 downto 0) := (others => '0');

begin

  -- Instantiate the cores.
  core_gen: for idx in 0 to COUNT - 1 generate
  begin
    core_inst: vhsnunzip_buffered
      generic map (
        RAM_STYLE   => get_ram_style(idx, B2U_MUL, B2U_DIV)
      )
      port map (
        clk         => clk,
        reset       => reset,
        in_valid    => u_in(idx).valid,
        in_ready    => u_in_ready(idx),
        in_data     => u_in(idx).data,
        in_cnt      => u_in(idx).cnt,
        in_last     => u_in(idx).last,
        out_valid   => u_out(idx).valid,
        out_ready   => u_out_ready(idx),
        out_data    => u_out(idx).data,
        out_cnt     => u_out(idx).cnt,
        out_last    => u_out(idx).last
      );
  end generate;

  -- Split the input into COUNT streams in round-robin fashion. Advance to the
  -- next block when the last transfer is handshaked.
  in_split_comb_proc: process (
    in_valid, u_in_ready, in_data, in_cnt, in_last, in_sel
  ) is
  begin
    for idx in 0 to COUNT - 1 loop
      if in_sel = idx then
        u_in(idx).valid <= in_valid;
      else
        u_in(idx).valid <= '0';
      end if;
      u_in(idx).data <= in_data;
      u_in(idx).cnt  <= in_cnt;
      u_in(idx).last <= in_last;
    end loop;
    in_ready_i <= u_in_ready(to_integer(in_sel));
  end process;

  in_split_reg_proc: process (clk) is
  begin
    if rising_edge(clk) then
      if in_valid = '1' and in_ready_i = '1' and in_last = '1' then
        if in_sel = COUNT - 1 then
          in_sel <= (others => '0');
        else
          in_sel <= in_sel + 1;
        end if;
      end if;
      if reset = '1' then
        in_sel <= (others => '0');
      end if;
    end if;
  end process;

  -- Merge the COUNT output streams into one by doing the reverse operation of
  -- the input splitter.
  out_merge_comb_proc: process (u_out, out_ready, out_sel) is
  begin
    for idx in 0 to COUNT - 1 loop
      if out_sel = idx then
        u_out_ready(idx) <= out_ready;
      else
        u_out_ready(idx) <= '0';
      end if;
    end loop;
    out_valid_i <= u_out(to_integer(out_sel)).valid;
    out_data    <= u_out(to_integer(out_sel)).data;
    out_cnt     <= u_out(to_integer(out_sel)).cnt;
    out_last_i  <= u_out(to_integer(out_sel)).last;
  end process;

  out_split_reg_proc: process (clk) is
  begin
    if rising_edge(clk) then
      if out_valid_i = '1' and out_ready = '1' and out_last_i = '1' then
        if out_sel = COUNT - 1 then
          out_sel <= (others => '0');
        else
          out_sel <= out_sel + 1;
        end if;
      end if;
      if reset = '1' then
        out_sel <= (others => '0');
      end if;
    end if;
  end process;

  -- Forward internal signal copies.
  in_ready <= in_ready_i;
  out_valid <= out_valid_i;
  out_last <= out_last_i;

end behavior;
