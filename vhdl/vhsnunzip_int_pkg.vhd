library std;
use std.textio.all;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;

library work;
use work.vhsnunzip_utils_pkg.all;

-- Package containing internal/private declarations for vhsnunzip.
package vhsnunzip_int_pkg is

  -- 'U' during simulation, '0' during synthesis.
  constant UNDEF    : std_logic := undef_fn;

  -- Generic array of bits. This has the same definition as an
  -- std_logic_vector for as far as VHDL is concerned, but semantically, we use
  -- this to describe individual bits (with ascending ranges), and
  -- std_logic_vector for scalar values which require multiple bits (descending
  -- ranges).
  type std_logic_array is array (natural range <>) of std_logic;

  -- Array of naturals, used only for generics.
  type natural_array is array (natural range <>) of natural;

  -- Generic array of bytes.
  type byte_array is array (natural range <>) of std_logic_vector(7 downto 0);

  -- Behavioral description of a shift register lookup.
  component vhsnunzip_srl is
    generic (
      WIDTH       : natural := 8;
      DEPTH_LOG2  : natural := 5
    );
    port (
      clk         : in  std_logic;
      wr_ena      : in  std_logic;
      wr_data     : in  std_logic_vector(WIDTH-1 downto 0);
      rd_addr     : in  unsigned(DEPTH_LOG2-1 downto 0) := (others => '0');
      rd_data     : out std_logic_vector(WIDTH-1 downto 0)
    );
  end component;

  -- Generic AXI-stream FIFO component based on vhsnunzip_srl.
  component vhsnunzip_fifo is
    generic (
      DATA_WIDTH  : natural := 0;
      CTRL_WIDTH  : natural := 0;
      DEPTH_LOG2  : natural := 5
    );
    port (
      clk         : in  std_logic;
      reset       : in  std_logic;
      wr_valid    : in  std_logic;
      wr_ready    : out std_logic;
      wr_data     : in  byte_array(0 to DATA_WIDTH-1) := (others => X"00");
      wr_ctrl     : in  std_logic_vector(CTRL_WIDTH-1 downto 0) := (others => '0');
      rd_valid    : out std_logic;
      rd_ready    : in  std_logic;
      rd_data     : out byte_array(0 to DATA_WIDTH-1);
      rd_ctrl     : out std_logic_vector(CTRL_WIDTH-1 downto 0);
      level       : out unsigned(DEPTH_LOG2 downto 0);
      empty       : out std_logic;
      full        : out std_logic
    );
  end component;

  -- Payload of the compressed data stream from the memory to the decoder. This
  -- passes through an SRL-based FIFO for buffering.
  type compressed_stream_single is record

    -- Stream valid signal.
    valid     : std_logic;

    -- Compressed data line.
    data      : byte_array(0 to 7);

    -- Asserted to mark the last line of a chunk. When asserted, endi indicates
    -- the index of the last valid byte. endi must be 7 otherwise.
    last      : std_logic;
    endi      : unsigned(2 downto 0);

  end record;

  constant COMPRESSED_STREAM_SINGLE_INIT : compressed_stream_single := (
    valid     => '0',
    data      => (others => (others => UNDEF)),
    last      => UNDEF,
    endi      => (others => UNDEF)
  );

  procedure stream_des(l: inout line; value: inout compressed_stream_single; to_x: boolean);

  -- Preprocessed compressed data stream, including information to skip over
  -- the uncompressed length field, and including a second "lookahead" line to
  -- ensure that we never have to stall in the middle of decoding an element.
  type compressed_stream_double is record

    -- Stream valid signal.
    valid     : std_logic;

    -- Two lines of compressed data. Reading elements that *start* after the
    -- first line is not legal, because not all of the lookahead line may be
    -- valid. However, if an element starts at byte 7, as much of the second
    -- line as is needed to encode the element should be valid, assuming that
    -- the input is valid snappy data.
    data      : byte_array(0 to 15);

    -- Asserted to mark the first line of a chunk. When asserted, start
    -- indicates the byte index of the first element; start should be ignored
    -- otherwise.
    first     : std_logic;
    start     : unsigned(2 downto 0);

    -- Asserted to mark the last line of a chunk. When asserted, endi indicates
    -- the index of the last valid byte. endi must be 7 otherwise.
    last      : std_logic;
    endi      : unsigned(2 downto 0);

  end record;

  constant COMPRESSED_STREAM_DOUBLE_INIT : compressed_stream_double := (
    valid     => '0',
    data      => (others => (others => UNDEF)),
    first     => UNDEF,
    start     => (others => UNDEF),
    last      => UNDEF,
    endi      => (others => UNDEF)
  );

  procedure stream_des(l: inout line; value: inout compressed_stream_double; to_x: boolean);

  -- Compressed data stream preprocessor.
  component vhsnunzip_pre_decoder is
    generic (
      LONG_CHUNKS : boolean := true
    );
    port (
      clk         : in  std_logic;
      reset       : in  std_logic;
      cs          : in  compressed_stream_single;
      cs_ready    : out std_logic;
      cd          : out compressed_stream_double;
      cd_ready    : in  std_logic
    );
  end component;

  -- Snappy element information and literal data stream from the decoder to
  -- the command generator. Each transfer in this stream encompasses (in this
  -- order) zero or one copy elements, zero or one literal headers, and
  -- optionally literal data. After a transfer with li_valid set, transfers
  -- with cp_valid and li_valid low will follow until all literal data bytes
  -- have been in the first 8 bytes of li_data (for short literals that start
  -- at a low offset, there may be zero such transfers).
  type element_stream is record

    -- Stream valid signal.
    valid     : std_logic;

    -- Copy element information. cp_offs is the byte offset and cp_len is the
    -- length as encoded by the element header. cp_len is stored
    -- DIMINISHED-ONE, just like the value in the Snappy header (this saves a
    -- bit).
    cp_val    : std_logic;
    cp_off    : unsigned(15 downto 0);
    cp_len    : unsigned(5 downto 0);

    -- Literal element information. li_offs is the starting byte offset within
    -- li_data for the literal; li_len encodes the literal length. li_len is
    -- stored DIMINISHED-ONE, just like the value in the Snappy header (this
    -- saves a bit).
    li_val    : std_logic;
    li_off    : unsigned(3 downto 0);
    li_len    : unsigned(31 downto 0);

    -- Indicates that the literal data FIFO should be popped after this stream
    -- transfer has been handled.
    ld_pop    : std_logic;

    -- Indicator for last set of elements/literal data in chunk.
    last      : std_logic;

  end record;

  procedure stream_des(l: inout line; value: inout element_stream; to_x: boolean);

  constant ELEMENT_STREAM_INIT : element_stream := (
    valid     => '0',
    cp_val    => UNDEF,
    cp_off    => (others => UNDEF),
    cp_len    => (others => UNDEF),
    li_val    => UNDEF,
    li_off    => (others => UNDEF),
    li_len    => (others => UNDEF),
    ld_pop    => UNDEF,
    last      => UNDEF
  );

  -- Snappy element decoders.
  component vhsnunzip_decoder is
    port (
      clk         : in  std_logic;
      reset       : in  std_logic;
      cd          : in  compressed_stream_double;
      cd_ready    : out std_logic;
      el          : out element_stream;
      el_ready    : in  std_logic
    );
  end component;

  component vhsnunzip_decoder_long is
    port (
      clk         : in  std_logic;
      reset       : in  std_logic;
      cd          : in  compressed_stream_double;
      cd_ready    : out std_logic;
      el          : out element_stream;
      el_ready    : in  std_logic
    );
  end component;

  -- Intermediate command stream between the two command generator stages.
  type partial_command_stream is record

    -- Stream valid signal.
    valid     : std_logic;

    -- Copy element information. cp_offs is the byte offset and cp_len is the
    -- length as encoded by the element header. cp_len is stored
    -- DIMINISHED-ONE, just like the value in the Snappy header (this saves a
    -- bit).
    cp_off    : unsigned(15 downto 0);
    cp_len    : signed(3 downto 0);

    -- Run-length encoding acceleration flag for rotations. When set, the
    -- constant (0, 1, 2, 3, 4, 5, 6, 7) should be added to cp_rol before the
    -- main rotation is applied. Carry into bit 3 can be ignored; the high
    -- line is never actually used in the main rotator because of this number
    -- and the fact that the decoder only outputs rotations between 0 and 7
    -- when this is asserted. This all sounds a bit arcane, but what ultimately
    -- happens because of this is simple: cp_rol is reduced to a byte index
    -- within the two lines.
    cp_rle    : std_logic;

    -- Literal element information. li_offs is the starting byte offset within
    -- li_data for the literal; li_len encodes the literal length. li_len is
    -- stored DIMINISHED-ONE, just like the value in the Snappy header (this
    -- saves a bit).
    li_val    : std_logic;
    li_off    : unsigned(3 downto 0);
    li_len    : unsigned(31 downto 0);

    -- Indicates that the literal data FIFO should be popped after this stream
    -- transfer has been handled.
    ld_pop    : std_logic;

    -- Indicator for last set of elements/literal data in chunk.
    last      : std_logic;

  end record;

  procedure stream_des(l: inout line; value: inout partial_command_stream; to_x: boolean);

  constant PARTIAL_COMMAND_STREAM_INIT : partial_command_stream := (
    valid     => '0',
    cp_off    => (others => UNDEF),
    cp_len    => (others => UNDEF),
    cp_rle    => UNDEF,
    li_val    => UNDEF,
    li_off    => (others => UNDEF),
    li_len    => (others => UNDEF),
    ld_pop    => UNDEF,
    last      => UNDEF
  );

  -- Decompression datapath command generator stage 1.
  component vhsnunzip_cmd_gen_1 is
    port (
      clk         : in  std_logic;
      reset       : in  std_logic;
      el          : in  element_stream;
      el_ready    : out std_logic;
      c1          : out partial_command_stream;
      c1_ready    : in  std_logic
    );
  end component;

  -- Command stream for the datapath.
  type command_stream is record

    -- Stream valid signal.
    valid     : std_logic;

    -- Whether long-term memory should be read.
    lt_val    : std_logic;

    -- Absolute first linepair indices for long-term memory read (0 = first
    -- linepair that was written, 1 = second linepair that was written, etc.).
    -- Both an even and an odd line must be read, with independent addresses.
    -- They'll always be next to each other, but the even line index may be
    -- one later to read a "misaligned" line pair.
    lt_adev   : unsigned(11 downto 0);
    lt_adod   : unsigned(11 downto 0);

    -- When low, lt_adev is the address for the low line, and lt_adod is the
    -- address for the high line. When high, this is swapped.
    lt_swap   : std_logic;

    -- Relative first line index for short-term memory read (-1 = line we're
    -- currently writing; positive = further back). For each of the 8 bytes,
    -- either the given line index must be read, or the subsequent line,
    -- depending on the rotation. This is computed by the datapath to reduce
    -- FIFO usage.
    st_addr   : unsigned(4 downto 0);

    -- Desired rotation for normal copies, or byte index for run-length copies.
    -- That is:
    --
    --  - cp_rle = '0': the copy mux result should be the first 8 bytes of
    --    linepair <<> cp_rol (where <<> denotes rotate-left).
    --  - cp_rle = '1': the copy mux result should be linepair(cp_rol(2..0))
    --    for each byte.
    --
    -- The linepair is:
    --
    --  - lt_val = '1', lt_swp = '0': lt_even & lt_odd
    --  - lt_val = '1', lt_swp = '1': lt_odd & lt_odd
    --  - lt_val = '0': short_term(st_addr) & short_term(st_addr+1)
    --
    -- For both long-term and short-term copies, an 8:8 rotator is sufficient,
    -- if:
    --
    --  - the short-term read address is determined on a byte-by-byte basis
    --    based on cp_rol;
    --  - the effect of lt_swap is inverted on a byte-by-byte basis based on
    --    cp_rol.
    --
    cp_rol    : unsigned(3 downto 0);

    -- Run-length encoding acceleration flag for rotations. When set, the
    -- constant (0, 1, 2, 3, 4, 5, 6, 7) should be added to cp_rol before the
    -- main rotation is applied. Carry into bit 3 can be ignored; the high
    -- line is never actually used in the main rotator because of this number
    -- and the fact that the decoder only outputs rotations between 0 and 7
    -- when this is asserted. This all sounds a bit arcane, but what ultimately
    -- happens because of this is simple: cp_rol is reduced to a byte index
    -- within the two lines.
    cp_rle    : std_logic;

    -- This index indicates the last valid *copy* byte provided by this command
    -- + one. Bytes between cp_endi and endi are literal bytes. The copy
    -- selection signals can be decoded from this in the same way that the 
    -- byte strobe signals are determined from endi.
    cp_end    : unsigned(3 downto 0);

    -- Rotation for literals. The direction is rotate-left. The MSB should be
    -- handled by offsetting the SRL literal read by one line on a byte-by-byte
    -- basis, in the same way that the short-term memory read handles this. The
    -- remaining 3 LSBs must be handled by the main 8:8 rotator.
    li_rol    : unsigned(3 downto 0);

    -- Index of the last valid byte provided by this command + one. The byte
    -- strobe signals can be derived from this thermometer-code style, ignoring
    -- any bytes that were already written. Overflow past the current line
    -- (endi > 8) should be written to a holding register, as the beginning for
    -- the next line. The MSB therefore indicates that an aligned line of
    -- decompressed data is complete.
    li_end    : unsigned(3 downto 0);

    -- Indicates that the literal data FIFO should be popped after this command
    -- has been handled.
    ld_pop    : std_logic;

    -- Set to mark the last command for a chunk.
    last      : std_logic;

  end record;

  procedure stream_des(l: inout line; value: inout command_stream; to_x: boolean);

  constant COMMAND_STREAM_INIT : command_stream := (
    valid     => '0',
    lt_val    => UNDEF,
    lt_adev   => (others => UNDEF),
    lt_adod   => (others => UNDEF),
    lt_swap   => UNDEF,
    st_addr   => (others => UNDEF),
    cp_rol    => (others => UNDEF),
    cp_rle    => UNDEF,
    cp_end    => (others => UNDEF),
    li_rol    => (others => UNDEF),
    li_end    => (others => UNDEF),
    ld_pop    => UNDEF,
    last      => UNDEF
  );

  -- Decompression datapath command generator stage 2.
  component vhsnunzip_cmd_gen_2 is
    generic (
      LONG_CHUNKS : boolean := true
    );
    port (
      clk         : in  std_logic;
      reset       : in  std_logic;
      c1          : in  partial_command_stream;
      c1_ready    : out std_logic;
      lt_off_ld   : in  std_logic := '1';
      lt_off      : in  unsigned(12 downto 0) := (others => '0');
      cm          : out command_stream;
      cm_ready    : in  std_logic
    );
  end component;

  -- Decompression output stream payload.
  type decompressed_stream is record

    -- Stream valid signal.
    valid     : std_logic;

    -- Decompressed data line.
    data      : byte_array(0 to 7);

    -- Asserted to mark the last line of a chunk.
    last      : std_logic;

    -- Indicates the number of valid bytes. This is always 8 when last is not
    -- set, but could be anything from 0 to 8 inclusive for the last transfer.
    cnt       : unsigned(3 downto 0);

  end record;

  constant DECOMPRESSED_STREAM_INIT : decompressed_stream := (
    valid     => '0',
    data      => (others => (others => UNDEF)),
    last      => UNDEF,
    cnt       => (others => UNDEF)
  );

  procedure stream_des(l: inout line; value: inout decompressed_stream; to_x: boolean);

  -- Snappy decompression pipeline.
  component vhsnunzip_pipeline is
    generic (
      LONG_CHUNKS : boolean := true
    );
    port (
      clk         : in  std_logic;
      reset       : in  std_logic;
      co          : in  compressed_stream_single;
      co_ready    : out std_logic;
      co_level    : out unsigned(5 downto 0);
      lt_off_ld   : in  std_logic := '1';
      lt_off      : in  unsigned(12 downto 0) := (others => '0');
      lt_rd_valid : out std_logic;
      lt_rd_ready : in  std_logic := '1';
      lt_rd_adev  : out unsigned(11 downto 0);
      lt_rd_adod  : out unsigned(11 downto 0);
      lt_rd_next  : in  std_logic;
      lt_rd_even  : in  byte_array(0 to 7);
      lt_rd_odd   : in  byte_array(0 to 7);
      -- pragma translate_off
      dbg_cs      : out compressed_stream_single;
      dbg_cd      : out compressed_stream_double;
      dbg_el      : out element_stream;
      dbg_c1      : out partial_command_stream;
      dbg_cm      : out command_stream;
      dbg_s1      : out command_stream;
      -- pragma translate_on
      de          : out decompressed_stream;
      de_ready    : in  std_logic;
      de_level    : out unsigned(5 downto 0)
    );
  end component;

  -- RAM port command.
  type ram_command is record

    -- Valid bit.
    valid         : std_logic;

    -- Read/write address.
    addr          : unsigned(11 downto 0);

    -- Set high to write, low to read.
    wren          : std_logic;

    -- Data to write.
    wdat          : byte_array(0 to 7);

    -- Control info to write (saved in parity bit storage).
    wctrl         : std_logic_vector(7 downto 0);

  end record;

  type ram_command_array is array (natural range <>) of ram_command;

  -- RAM port response.
  type ram_response is record

    -- Valid bit. Asserted only for *read* access results.
    valid         : std_logic;

    -- Like valid, but asserted one cycle earlier.
    valid_next    : std_logic;

    -- Data that was read.
    rdat          : byte_array(0 to 7);

    -- Control info that was read..
    rctrl         : std_logic_vector(7 downto 0);

  end record;

  type ram_response_array is array (natural range <>) of ram_response;

  -- Unit representing a single Xilinx URAM or collection of 8 BRAMs. There are
  -- two files for this entity; one is a behavioral model intended for
  -- vendor-agnostic simulation, the other contains the Xilinx primitives (and
  -- their simulation models) to instantiate the memories.
  component vhsnunzip_ram is
    generic (
      RAM_STYLE   : string := "URAM"
    );
    port (
      clk         : in  std_logic;
      reset       : in  std_logic;
      a_cmd       : in  ram_command;
      a_resp      : out ram_response;
      b_cmd       : in  ram_command;
      b_resp      : out ram_response
    );
  end component;

  -- RAM port arbiter access request.
  type ram_request is record

    -- Valid bit.
    valid         : std_logic;

    -- Asserts that this request has escalated priority.
    hipri         : std_logic;

    -- Read/write address for the even and odd line.
    ev_addr       : unsigned(11 downto 0);
    od_addr       : unsigned(11 downto 0);

    -- Set high to write, low to read; again for the even and odd line.
    ev_wren       : std_logic;
    od_wren       : std_logic;

    -- Data to write.
    ev_wdat       : byte_array(0 to 7);
    od_wdat       : byte_array(0 to 7);

    -- Control info to write (saved in parity bit storage).
    ev_wctrl      : std_logic_vector(7 downto 0);
    od_wctrl      : std_logic_vector(7 downto 0);

  end record;

  type ram_request_array is array (natural range <>) of ram_request;

  constant RAM_REQUEST_INIT : ram_request := (
    valid     => '0',
    hipri     => '0',
    ev_addr   => (others => UNDEF),
    od_addr   => (others => UNDEF),
    ev_wren   => UNDEF,
    od_wren   => UNDEF,
    ev_wdat   => (others => (others => UNDEF)),
    od_wdat   => (others => (others => UNDEF)),
    ev_wctrl  => (others => UNDEF),
    od_wctrl  => (others => UNDEF)
  );

  -- RAM port arbiter response.
  type ram_response_pair is record

    -- Responses from the even and odd memory blocks.
    ev            : ram_response;
    od            : ram_response;

  end record;

  type ram_response_pair_array is array (natural range <>) of ram_response_pair;

  -- Arbiter for the RAM access requests generated by the decompression
  -- pipeline and input/output FIFO control blocks.
  component vhsnunzip_port_arbiter is
    generic (
      IF_LO_PRIO  : natural_array(0 to 3) := (others => 0);
      IF_HI_PRIO  : natural_array(0 to 2) := (others => 0);
      LATENCY     : natural
    );
    port (
      clk         : in  std_logic;
      reset       : in  std_logic;
      req         : in  ram_request_array(0 to 3);
      req_ready   : out std_logic_array(0 to 3);
      resp        : out ram_response_pair_array(0 to 3);
      ev_cmd      : out ram_command;
      od_cmd      : out ram_command;
      ev_resp     : in  ram_response;
      od_resp     : in  ram_response
    );
  end component;

  -- I/O stream for the buffered units, only used for simulation.
  type wide_io_stream is record
    valid     : std_logic;
    dvalid    : std_logic;
    data      : std_logic_vector(255 downto 0);
    cnt       : std_logic_vector(4 downto 0);
    last      : std_logic;
  end record;

  type wide_io_stream_array is array (natural range <>) of wide_io_stream;

  constant WIDE_IO_STREAM_INIT : wide_io_stream := (
    valid     => '0',
    dvalid    => UNDEF,
    data      => (others => UNDEF),
    cnt       => (others => UNDEF),
    last      => UNDEF
  );

  procedure stream_des(l: inout line; value: inout wide_io_stream; to_x: boolean);

  -- Buffered toplevel for a single vhsnunzip core. This version of the
  -- decompressor uses the RAMs needed for long-term decompression history
  -- storage for input/output FIFOs as well. This allows the data to be pumped
  -- in using a much wider bus (32-byte) and without stalling, but total
  -- decompression time may be longer due to memory bandwidth starvation.
  component vhsnunzip_buffered is
    generic (
      RAM_STYLE   : string := "URAM"
    );
    port (
      clk         : in  std_logic;
      reset       : in  std_logic;
      in_valid    : in  std_logic;
      in_ready    : out std_logic;
      in_data     : in  std_logic_vector(255 downto 0);
      in_cnt      : in  std_logic_vector(4 downto 0);
      in_last     : in  std_logic;
      -- pragma translate_off
      dbg_co      : out compressed_stream_single;
      dbg_de      : out decompressed_stream;
      -- pragma translate_on
      out_valid   : out std_logic;
      out_ready   : in  std_logic;
      out_dvalid  : out std_logic;
      out_data    : out std_logic_vector(255 downto 0);
      out_cnt     : out std_logic_vector(4 downto 0);
      out_last    : out std_logic
    );
  end component;

end package vhsnunzip_int_pkg;

package body vhsnunzip_int_pkg is

  function vhsn_to_x01(x: std_logic) return std_logic is
  begin
    return to_x01(x);
  end function;

  function vhsn_to_x01(x: std_logic_vector) return std_logic_vector is
  begin
    return to_x01(x);
  end function;

  function vhsn_to_x01(x: unsigned) return unsigned is
    variable y  : std_logic_vector(x'range);
  begin
    y := std_logic_vector(x);
    y := to_x01(y);
    return unsigned(y);
  end function;

  function vhsn_to_x01(x: signed) return signed is
    variable y  : std_logic_vector(x'range);
  begin
    y := std_logic_vector(x);
    y := to_x01(y);
    return signed(y);
  end function;

  procedure vhsn_read(l: inout line; value: out std_logic) is
  begin
    read(l, value);
  end procedure;

  procedure vhsn_read(l: inout line; value: out std_logic_vector) is
  begin
    read(l, value);
  end procedure;

  procedure vhsn_read(l: inout line; value: out unsigned) is
    variable v  : std_logic_vector(value'range);
  begin
    read(l, v);
    value := unsigned(v);
  end procedure;

  procedure vhsn_read(l: inout line; value: out signed) is
    variable v  : std_logic_vector(value'range);
  begin
    read(l, v);
    value := signed(v);
  end procedure;

  procedure stream_des(l: inout line; value: inout compressed_stream_single; to_x: boolean) is
  begin
    for i in value.data'range loop
      vhsn_read(l, value.data(i));
      if to_x then
        value.data(i) := vhsn_to_x01(value.data(i));
      end if;
    end loop;
    vhsn_read(l, value.last);
    vhsn_read(l, value.endi);
    if to_x then
      value.last := vhsn_to_x01(value.last);
      value.endi := vhsn_to_x01(value.endi);
    end if;
    value.valid := '1';
  end procedure;

  procedure stream_des(l: inout line; value: inout compressed_stream_double; to_x: boolean) is
  begin
    for i in value.data'range loop
      vhsn_read(l, value.data(i));
      if to_x then
        value.data(i) := vhsn_to_x01(value.data(i));
      end if;
    end loop;
    vhsn_read(l, value.first);
    vhsn_read(l, value.start);
    vhsn_read(l, value.last);
    vhsn_read(l, value.endi);
    if to_x then
      value.first := vhsn_to_x01(value.first);
      value.start := vhsn_to_x01(value.start);
      value.last := vhsn_to_x01(value.last);
      value.endi := vhsn_to_x01(value.endi);
    end if;
    value.valid := '1';
  end procedure;

  procedure stream_des(l: inout line; value: inout element_stream; to_x: boolean) is
  begin
    vhsn_read(l, value.cp_val);
    vhsn_read(l, value.cp_off);
    vhsn_read(l, value.cp_len);
    vhsn_read(l, value.li_val);
    vhsn_read(l, value.li_off);
    vhsn_read(l, value.li_len);
    vhsn_read(l, value.ld_pop);
    vhsn_read(l, value.last);
    if to_x then
      value.cp_val := vhsn_to_x01(value.cp_val);
      value.cp_off := vhsn_to_x01(value.cp_off);
      value.cp_len := vhsn_to_x01(value.cp_len);
      value.li_val := vhsn_to_x01(value.li_val);
      value.li_off := vhsn_to_x01(value.li_off);
      value.li_len := vhsn_to_x01(value.li_len);
      value.ld_pop := vhsn_to_x01(value.ld_pop);
      value.last := vhsn_to_x01(value.last);
    end if;
    value.valid := '1';
  end procedure;

  procedure stream_des(l: inout line; value: inout partial_command_stream; to_x: boolean) is
  begin
    vhsn_read(l, value.cp_off);
    vhsn_read(l, value.cp_len);
    vhsn_read(l, value.cp_rle);
    vhsn_read(l, value.li_val);
    vhsn_read(l, value.li_off);
    vhsn_read(l, value.li_len);
    vhsn_read(l, value.ld_pop);
    vhsn_read(l, value.last);
    if to_x then
      value.cp_off := vhsn_to_x01(value.cp_off);
      value.cp_len := vhsn_to_x01(value.cp_len);
      value.cp_rle := vhsn_to_x01(value.cp_rle);
      value.li_val := vhsn_to_x01(value.li_val);
      value.li_off := vhsn_to_x01(value.li_off);
      value.li_len := vhsn_to_x01(value.li_len);
      value.ld_pop := vhsn_to_x01(value.ld_pop);
      value.last := vhsn_to_x01(value.last);
    end if;
    value.valid := '1';
  end procedure;

  procedure stream_des(l: inout line; value: inout command_stream; to_x: boolean) is
  begin
    vhsn_read(l, value.lt_val);
    vhsn_read(l, value.lt_adev);
    vhsn_read(l, value.lt_adod);
    vhsn_read(l, value.lt_swap);
    vhsn_read(l, value.st_addr);
    vhsn_read(l, value.cp_rol);
    vhsn_read(l, value.cp_rle);
    vhsn_read(l, value.cp_end);
    vhsn_read(l, value.li_rol);
    vhsn_read(l, value.li_end);
    vhsn_read(l, value.ld_pop);
    vhsn_read(l, value.last);
    if to_x then
      value.lt_val := vhsn_to_x01(value.lt_val);
      value.lt_adev := vhsn_to_x01(value.lt_adev);
      value.lt_adod := vhsn_to_x01(value.lt_adod);
      value.lt_swap := vhsn_to_x01(value.lt_swap);
      value.st_addr := vhsn_to_x01(value.st_addr);
      value.cp_rol := vhsn_to_x01(value.cp_rol);
      value.cp_rle := vhsn_to_x01(value.cp_rle);
      value.cp_end := vhsn_to_x01(value.cp_end);
      value.li_rol := vhsn_to_x01(value.li_rol);
      value.li_end := vhsn_to_x01(value.li_end);
      value.ld_pop := vhsn_to_x01(value.ld_pop);
      value.last := vhsn_to_x01(value.last);
    end if;
    value.valid := '1';
  end procedure;

  procedure stream_des(l: inout line; value: inout decompressed_stream; to_x: boolean) is
  begin
    for i in value.data'range loop
      vhsn_read(l, value.data(i));
      if to_x then
        value.data(i) := vhsn_to_x01(value.data(i));
      end if;
    end loop;
    vhsn_read(l, value.last);
    vhsn_read(l, value.cnt);
    if to_x then
      value.last := vhsn_to_x01(value.last);
      value.cnt := vhsn_to_x01(value.cnt);
    end if;
    value.valid := '1';
  end procedure;

  procedure stream_des(l: inout line; value: inout wide_io_stream; to_x: boolean) is
  begin
    vhsn_read(l, value.dvalid);
    vhsn_read(l, value.data);
    vhsn_read(l, value.last);
    vhsn_read(l, value.cnt);
    if to_x then
      value.dvalid := vhsn_to_x01(value.dvalid);
      value.data := vhsn_to_x01(value.data);
      value.last := vhsn_to_x01(value.last);
      value.cnt := vhsn_to_x01(value.cnt);
    end if;
    value.valid := '1';
  end procedure;

end package body vhsnunzip_int_pkg;
