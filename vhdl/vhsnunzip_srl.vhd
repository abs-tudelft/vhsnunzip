library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Shift register lookup unit. On Xilinx architectures, this maps to SRL32 or
-- SRL64 primitives, with an additional register in the address.
entity vhsnunzip_srl is
  generic (

    -- Data port width.
    WIDTH       : natural := 8;

    -- log2 of the memory depth. Less than 5 does not reduce logic utilization
    -- on Xilinx architectures; SRL32 primitives will be inferred.
    DEPTH_LOG2  : natural := 5

  );
  port (
    clk         : in  std_logic;

    -- Write data input.
    wr_ena      : in  std_logic;
    wr_data     : in  std_logic_vector(WIDTH-1 downto 0);

    -- Read data output. Address 0 corresponds to the most recent write,
    -- address 1 corresponds to the one before that, and so on. The address is
    -- combinatorial!
    rd_addr     : in  unsigned(DEPTH_LOG2-1 downto 0) := (others => '0');
    rd_data     : out std_logic_vector(WIDTH-1 downto 0)

  );
end vhsnunzip_srl;

architecture behavior of vhsnunzip_srl is
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

  rd_data <= memory(to_integer(rd_addr));

end behavior;
