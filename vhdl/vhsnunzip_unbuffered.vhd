library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.vhsnunzip_int_pkg.all;

-- Streaming toplevel for vhsnunzip. This version of the decompressor doesn't
-- include any large-scale input and output stream buffering, so the streams
-- are limited to the speed of the decompression engine. However, because the
-- long-term memory isn't also used for buffering, the decompression engine
-- will never be internally bandwidth-starved, so decompression will be a bit
-- faster.
entity vhsnunzip_unbuffered is
  generic (

    -- Whether long chunks (>64kiB) should be supported. If this is disabled,
    -- the core will be a couple hundred LUTs smaller.
    LONG_CHUNKS : boolean := true;

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
    -- This unit should be able to handle any Snappy chunk compressed with a
    -- history buffer of 64kiB or less (the default for Snappy is 32kiB).
    -- Copies from further back in history will result in garbage for that
    -- copy.
    --
    -- The input stream must be normalized; that is, all 8 bytes must be valid
    -- for all but the last transfer, and the last transfer must contain at
    -- least one byte. The number of valid bytes is indicated by cnt; 8 valid
    -- bytes is represented as 0 (implicit MSB). The LSB of the first transfer
    -- corresponds to the first byte in the chunk. This is compatible with the
    -- stream library components in vhlib.
    co_valid    : in  std_logic;
    co_ready    : out std_logic;
    co_data     : in  std_logic_vector(63 downto 0);
    co_cnt      : in  std_logic_vector(2 downto 0);
    co_last     : in  std_logic;

    -- Decompressed output stream. This stream is almost normalized, with the
    -- exception of the last transfer; the size of this transfer may be zero,
    -- even if the packet is non-empty. An empty line is signalled using cnt=0
    -- and dvalid=0. This is compatible with the stream library components in
    -- vhlib. If you need a fully normalized stream, you could add a
    -- StreamReshaper with element size 1 on both the input and the output.
    de_valid    : out std_logic;
    de_ready    : in  std_logic;
    de_dvalid   : out std_logic;
    de_data     : out std_logic_vector(63 downto 0);
    de_cnt      : out std_logic_vector(3 downto 0);
    de_last     : out std_logic

  );
end vhsnunzip_unbuffered;

architecture behavior of vhsnunzip_unbuffered is

  -- Pipeline interface signals.
  signal co           : compressed_stream_single;
  signal de           : decompressed_stream;
  signal lt_rd_valid  : std_logic;
  signal lt_rd_val_r  : std_logic;
  signal lt_rd_adev   : unsigned(11 downto 0);
  signal lt_rd_adod   : unsigned(11 downto 0);
  signal lt_rd_next   : std_logic;
  signal lt_rd_even   : byte_array(0 to 7);
  signal lt_rd_odd    : byte_array(0 to 7);

  -- RAM interface signals.
  signal wr_ptr       : unsigned(12 downto 0);
  signal ev_wr_cmd    : ram_command;
  signal ev_rd_cmd    : ram_command;
  signal ev_rd_resp   : ram_response;
  signal od_wr_cmd    : ram_command;
  signal od_rd_cmd    : ram_command;
  signal od_rd_resp   : ram_response;

begin

  -- Datapath.
  datapath_inst: vhsnunzip_pipeline
    generic map (
      LONG_CHUNKS => LONG_CHUNKS
    )
    port map (
      clk         => clk,
      reset       => reset,
      co          => co,
      co_ready    => co_ready,
      lt_rd_valid => lt_rd_valid,
      lt_rd_adev  => lt_rd_adev,
      lt_rd_adod  => lt_rd_adod,
      lt_rd_next  => lt_rd_next,
      lt_rd_even  => lt_rd_even,
      lt_rd_odd   => lt_rd_odd,
      de          => de,
      de_ready    => de_ready
    );

  -- To improve tool compatibility, avoid non-std_logic types on the toplevel.
  -- Also convert to/from vhlib's stream interface where applicable.
  co_connect_proc: process (co_valid, co_data, co_cnt, co_last) is
  begin
    co.valid <= co_valid;
    for byte in 0 to 7 loop
      co.data(byte) <= co_data(byte*8+7 downto byte*8);
    end loop;
    co.endi <= unsigned(co_cnt) - 1;
    co.last <= co_last;
  end process;

  de_connect_proc: process (de) is
  begin
    de_valid <= de.valid;
    for byte in 0 to 7 loop
      de_data(byte*8+7 downto byte*8) <= de.data(byte);
    end loop;
    de_cnt <= std_logic_vector(de.cnt);
    if de.cnt > 0 then
      de_dvalid <= '1';
    else
      de_dvalid <= '0';
    end if;
    de_last <= de.last;
  end process;

  -- Write the decompressed output to the memory for long-term history
  -- storage.
  ev_wr_cmd <= (
    valid => de.valid and de_ready and not wr_ptr(0),
    addr  => wr_ptr(12 downto 1),
    wren  => '1',
    wdat  => de.data,
    wctrl => "00000000");

  od_wr_cmd <= (
    valid => de.valid and de_ready and wr_ptr(0),
    addr  => wr_ptr(12 downto 1),
    wren  => '1',
    wdat  => de.data,
    wctrl => "00000000");

  wr_ptr_proc: process (clk) is
  begin
    if rising_edge(clk) then
      if de.valid = '1' and de_ready = '1' then
        if de.last = '0' then
          wr_ptr <= wr_ptr + 1;
        else
          wr_ptr <= (others => '0');
        end if;
      end if;
      if reset = '1' then
        wr_ptr <= (others => '0');
      end if;
    end if;
  end process;

  -- Connect the long-term memory read request signals.
  ev_rd_cmd <= (
    valid => lt_rd_valid,
    addr  => lt_rd_adev,
    wren  => '0',
    wdat  => (others => X"00"),
    wctrl => "00000000");

  od_rd_cmd <= (
    valid => lt_rd_valid,
    addr  => lt_rd_adod,
    wren  => '0',
    wdat  => (others => X"00"),
    wctrl => "00000000");

  lt_rd_even <= ev_rd_resp.rdat;
  lt_rd_odd  <= od_rd_resp.rdat;
  lt_rd_next <= od_rd_resp.valid_next;

  -- RAM containing the even 8-byte lines of decompression history.
  ram_even_inst: vhsnunzip_ram
    generic map (
      RAM_STYLE => RAM_STYLE
    )
    port map (
      clk       => clk,
      reset     => reset,
      a_cmd     => ev_wr_cmd,
      a_resp    => open,
      b_cmd     => ev_rd_cmd,
      b_resp    => ev_rd_resp
    );

  -- RAM containing the odd 8-byte lines of decompression history.
  ram_odd_inst: vhsnunzip_ram
    generic map (
      RAM_STYLE => RAM_STYLE
    )
    port map (
      clk       => clk,
      reset     => reset,
      a_cmd     => od_wr_cmd,
      a_resp    => open,
      b_cmd     => od_rd_cmd,
      b_resp    => od_rd_resp
    );

end behavior;
