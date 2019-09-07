library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Snappy element decoder. Consumes a parallel bytestream (WI bytes per cycle)
-- to decode up to one copy and one literal element per cycle.
entity vhsnunzip_decode is
  generic (

    -- Bytes per cycle.
    WI          : natural := 8;

  );
  port (
    clk         : in  std_logic;
    reset       : in  syd

    -- Write data input.
    wr_ena      : in  std_logic;
    wr_data     : in  std_logic_vector(WIDTH-1 downto 0);

    -- Read data output. Address 0 corresponds to the most recent write,
    -- address 1 corresponds to the one before that, and so on. The address is
    -- combinatorial!
    rd_addr     : in  std_logic_vector(DEPTH_LOG2-1 downto 0) := (others => '0');
    rd_data     : out std_logic_vector(WIDTH-1 downto 0)

  );
end vhsnunzip_decode;

architecture behavior of vhsnunzip_decode is
  type memory_type is array (natural range <>) of std_logic_vector(WIDTH-1 downto 0);
  signal memory : memory_type(0 to 2**DEPTH_LOG2-1) := (others => (others => '0'));
begin

  reg_proc: process (clk) is
  begin
    if rising_edge(clk) then
      if wr_ena = '1' then
        memory(1 to 2**DEPTH_LOG2-1) <= memory(0 to 2**DEPTH_LOG2-2);
        memory(0) <= wr_data;
      end if;
    end if;
  end process;

  rd_data <= memory(to_integer(unsigned(rd_addr)));

end behavior;
