
entity slicer is
  generic (

    -- The 2log of the width of the input stream in bytes. The width must be at
    -- least 4 bytes, so this must be at least 2.
    BPC_LOG2                : natural := 2;

    -- The number of driven element decoders.
    ELEMENTS_PER_CYCLE      : natural := 1

  );
  port (
    clk                     : in  std_logic;
    reset                   : in  std_logic;

    -- Command input stream.
    cmd_valid               : in  std_logic;
    cmd_ready               : out std_logic;
    cmd_compressed_size     : in  std_logic_vector(31 downto 0);
    cmd_uncompressed_size   : in  std_logic_vector(31 downto 0);

    -- Response output stream.
    resp_valid              : out std_logic;
    resp_ready              : in  std_logic;
    resp_error              : out std_logic

    -- Snappy-compressed input stream.
    in_valid                : in  std_logic;
    in_ready                : out std_logic;
    in_data                 : in  std_logic_vector(2**BPC_LOG2*8-1 downto 0)

  );
end slicer;

architecture behavior of slicer is
  type state_type is record

    -- Command input stream holding registers. This just forms a stream slice.
    cmd_valid               : std_logic;
    cmd_compressed_size     : std_logic_vector(31 downto 0);
    cmd_uncompressed_size   : std_logic_vector(31 downto 0);

    -- Snappy-compressed input stream holding registers. This just forms a
    -- stream slice.
    in_valid                : std_logic;
    in_data                 : std_logic_vector(2**BPC_LOG2*8-1 downto 0);

    -- Response output stream holding register.
    resp_valid              : std_logic;
    resp_error              : std_logic;

    -- Indicates that we're busy == our state registers are valid.
    busy                    : std_logic;

    -- This flag is set when we encounter an error of some kind while
    -- uncompressing.
    err                     : std_logic;

    -- Data holding register. This is twice the bus width. Bus words get
    -- shifted into this register as needed, so we always have two consecutive
    -- bus words in here when data_valid is high. This allows us to parse
    -- element headers (up to five bytes in size -- this is why the bus width
    -- needs to be at least four bytes) for all starting positions in the bus
    -- word.
    data                    : std_logic_vector(2**BPC_LOG2*16-1 downto 0);

    -- The starting offset of the next element with respect to data. This can
    -- be more than the bus width; this just means we need to shift more data.
    next_el_offs            : unsigned(31 downto 0);

    -- Number of bus words we still need to accept.
    in_shift_remain         : unsigned(31 downto 0);

    -- Number of input bytes remaining.
    in_bytes_remain         : unsigned(31 downto 0);

  end record;
  signal s_sig  : state_type;
begin
  proc: process (clk) is
    variable s    : state_type;
    variable size : std_logic_vector(31 downto 0);
  begin
    if rising_edge(clk) then
      s := s_sig;

      -- Infer command stream holding register/handle handshake.
      if s.cmd_valid = '0' then
        s.cmd_valid := cmd_valid;
        s.cmd_compressed_size := cmd_compressed_size;
        s.cmd_uncompressed_size := cmd_uncompressed_size;
      end if;
      if reset = '1' then
        s.cmd_valid := '0';
      end if;
      cmd_ready <= not s.cmd_valid;

      -- Infer input data stream holding register/handle handshake.
      if s.in_valid = '0' then
        s.in_valid := in_valid;
        s.in_data := in_data;
      end if;
      if reset = '1' then
        s.in_valid := '0';
      end if;
      in_ready <= not s.in_valid;

      -- Handle the output stream.
      if resp_ready = '1' or reset = '1' then
        s.resp_valid <= '0';
      end if;
      resp_valid <= s.resp_valid;
      resp_error <= s.resp_error;

      -- If we're not busy and all the streams are ready, initialize ourselves
      -- for a new uncompression block. We can't do this when the response
      -- stream (holding register) isn't free, because we never check the
      -- holding register state after this point.
      if (
        s.busy = '0'
        and s.cmd_valid = '1'
        and s.resp_valid = '0'
        and s.in_valid = '1'
      ) then
        s.busy := '1';
        s.err := '0';

        -- Accept the first bus word.
        s.data(2**BPC_LOG2*16-1 downto 2**BPC_LOG2*8) := s.in_data;
        s.in_valid := '0';

        -- Determine the size and value of the initial varint.
        size := s.in_data(35 downto 32);
              & s.in_data(30 downto 24);
              & s.in_data(22 downto 16);
              & s.in_data(14 downto  8);
              & s.in_data( 6 downto  0);
        if s.in_data(7) = '0' then
          s.next_el_offs := 1;
          size(31 downto 7) := (others => '0');
        elsif in_data(15) = '0' then
          s.next_el_offs := 2;
          size(31 downto 14) := (others => '0');
        elsif in_data(23) = '0' then
          s.next_el_offs := 3;
          size(31 downto 21) := (others => '0');
        elsif in_data(31) = '0' then
          s.next_el_offs := 4;
          size(31 downto 28) := (others => '0');
        else
          s.next_el_offs := 5;
        end if;

        -- Match the varint value against cmd_compressed_size.
        if size /= s.cmd_uncompressed_size then
          report "uncompressed size mismatch (command stream vs header)"
            severity warning;
          s.err := '1';
        end if;

        -- Use the compressed size from the command stream to figure out how
        -- many times we still need to shift in a bus word. We just did the
        -- first one already!
        s.in_shift_remain := shift_right(unsigned(s.cmd_compressed_size) - 1, BPC_LOG2);
        s.in_bytes_remain := unsigned(s.cmd_compressed_size) - s.next_el_offs;

        -- next_el_offs currently contains the offset of the first element. But
        -- we still need to shift in the next bus word, because we need two bus
        -- words before we can start doing anything. We handle this by
        -- pretending that the data register is currently referenced one bus
        -- word in front of the actual data; this forces the next bus word to
        -- be loaded and the data register to be shifted to the start of the
        -- stream.
        s.next_el_offs := s.next_el_offs + 2**BPC_LOG2;

      end if;

      if s.busy = '1' then

        -- Shift in more data when it is available and we need it.
        if s.next_el_offs >= 2**BPC_LOG2 then
          if s.in_shift_remain = 0 or s.in_valid = '1' then
            s.data := s.in_data & s.data(2**BPC_LOG2*16-1 downto 2**BPC_LOG2*8);
            s.data_valid := '1';
            if s.in_shift_remain /= 0 then
              s.in_valid := '0';
            end if;
            s.in_shift_remain := s.in_shift_remain - 1;
            s.next_el_offs := s.next_el_offs - 2**BPC_LOG2;
          end if;
        end if;

        for i in 0 to ELEMENTS_PER_CYCLE - 1 loop

          if s.next_el_offs < 2**BPC_LOG2 then

          end if;

        end loop;

      end if;

      if reset = '1' then
        s.busy := '0';
        s.err := '0';
      end if;

      s_sig <= s;
    end if;
  end process;
end behavior;
