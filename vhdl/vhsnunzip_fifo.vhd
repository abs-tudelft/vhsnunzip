library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.vhsnunzip_int_pkg.all;

-- AXI-stream FIFO using byte_array data, derived from SRLs.
entity vhsnunzip_fifo is
  generic (

    -- Data port width in bytes.
    DATA_WIDTH  : natural := 0;

    -- Control port width in bits.
    CTRL_WIDTH  : natural := 0;

    -- log2 of the memory depth. Less than 5 does not reduce logic utilization
    -- on Xilinx architectures; SRL32 primitives will be inferred.
    DEPTH_LOG2  : natural := 5

  );
  port (
    clk         : in  std_logic;
    reset       : in  std_logic;

    -- Write data input stream.
    wr_valid    : in  std_logic;
    wr_ready    : out std_logic;
    wr_data     : in  byte_array(0 to DATA_WIDTH-1) := (others => X"00");
    wr_ctrl     : in  std_logic_vector(CTRL_WIDTH-1 downto 0) := (others => '0');

    -- Read data output stream.
    rd_valid    : out std_logic;
    rd_ready    : in  std_logic;
    rd_data     : out byte_array(0 to DATA_WIDTH-1);
    rd_ctrl     : out std_logic_vector(CTRL_WIDTH-1 downto 0);

    -- FIFO level. This is diminished-one-encoded! That is, -1 is empty, 0 is
    -- one valid entry, etc. This has to do with how Xilinx SRL primitive read
    -- addresses work.
    level       : out unsigned(DEPTH_LOG2 downto 0);

    -- Empty and full status signals, derived from level.
    empty       : out std_logic;
    full        : out std_logic

  );
end vhsnunzip_fifo;

architecture behavior of vhsnunzip_fifo is

  -- Internal copy of the FIFO level, see level port for more info.
  signal level_s  : unsigned(DEPTH_LOG2 downto 0) := (others => '1');

  -- Internal copies of the empty and full status signals.
  signal empty_s  : std_logic;
  signal full_s   : std_logic := '0';

  -- Write- and read enable signals. These assert when an AXI handshake
  -- completes.
  signal wr_ena   : std_logic;
  signal rd_ena   : std_logic;

  -- Concatenated versions of the wr_data and rd_data byte arrays.
  constant WIDTH  : natural := DATA_WIDTH*8 + CTRL_WIDTH;
  signal wr_data_concat : std_logic_vector(WIDTH-1 downto 0);
  signal rd_data_concat : std_logic_vector(WIDTH-1 downto 0);

begin

  reg_proc: process (clk) is
    variable level_v  : unsigned(DEPTH_LOG2 downto 0);
  begin
    if rising_edge(clk) then

      -- Update the counter.
      level_v := level_s;
      if rd_ena = '1' then
        level_v := level_v - 1;
      end if;
      if wr_ena = '1' then
        level_v := level_v + 1;
      end if;
      level_s <= level_v;

      -- Precompute the full signal and store it in a register.
      if level_v = 2**DEPTH_LOG2-1 then
        full_s <= '1';
      else
        full_s <= '0';
      end if;

      -- Handle reset.
      if reset = '1' then
        level_s <= (others => '1');
        full_s <= '0';
      end if;

    end if;
  end process;

  -- The empty signal is just the MSB of the FIFO level.
  empty_s <= level_s(DEPTH_LOG2);

  -- Handle the AXI-stream handshakes.
  wr_ready <= not full_s;
  wr_ena <= wr_valid and not full_s;

  rd_valid <= not empty_s;
  rd_ena <= rd_ready and not empty_s;

  -- Use an SRL as backing memory for the FIFO.
  srl_inst: vhsnunzip_srl
    generic map (
      WIDTH       => WIDTH,
      DEPTH_LOG2  => DEPTH_LOG2
    )
    port map (
      clk         => clk,
      wr_ena      => wr_ena,
      wr_data     => wr_data_concat,
      rd_addr     => level_s(DEPTH_LOG2-1 downto 0),
      rd_data     => rd_data_concat
    );

  -- Pack/unpack the data vectors.
  pack_proc: process (wr_data, wr_ctrl) is
  begin
    if CTRL_WIDTH > 0 then
      wr_data_concat(CTRL_WIDTH-1 downto 0) <= wr_ctrl;
    end if;
    for i in 0 to DATA_WIDTH-1 loop
      wr_data_concat(8*i+7+CTRL_WIDTH downto 8*i+CTRL_WIDTH) <= wr_data(i);
    end loop;
  end process;

  unpack_proc: process (rd_data_concat) is
  begin
    if CTRL_WIDTH > 0 then
      rd_ctrl <= rd_data_concat(CTRL_WIDTH-1 downto 0);
    end if;
    for i in 0 to DATA_WIDTH-1 loop
      rd_data(i) <= rd_data_concat(8*i+7+CTRL_WIDTH downto 8*i+CTRL_WIDTH);
    end loop;
  end process;

  -- Forward the internal signals.
  level <= level_s;
  empty <= empty_s;
  full <= full_s;

end behavior;
