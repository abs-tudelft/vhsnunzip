library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package vhsnunzip_pkg is

  type byte_array is array (natural range <>) of std_logic_vector(7 downto 0);

  component vhsnunzip_srl is
    generic (
      WIDTH       : natural := 8;
      DEPTH_LOG2  : natural := 5
    );
    port (
      clk         : in  std_logic;
      wr_ena      : in  std_logic;
      wr_data     : in  std_logic_vector(WIDTH-1 downto 0);
      rd_addr     : in  std_logic_vector(DEPTH_LOG2-1 downto 0) := (others => '0');
      rd_data     : out std_logic_vector(WIDTH-1 downto 0)
    );
  end component;

  component vhsnunzip_fifo is
    generic (
      WIDTH       : natural := 8;
      DEPTH_LOG2  : natural := 5
    );
    port (
      clk         : in  std_logic;
      reset       : in  std_logic;
      wr_valid    : in  std_logic;
      wr_ready    : out std_logic;
      wr_data     : in  byte_array(WIDTH-1 downto 0);
      rd_valid    : out std_logic;
      rd_ready    : in  std_logic;
      rd_data     : out byte_array(WIDTH-1 downto 0);
      level       : out std_logic_vector(DEPTH_LOG2 downto 0);
      empty       : out std_logic;
      full        : out std_logic
    );
  end component;

end package vhsnunzip_pkg;
