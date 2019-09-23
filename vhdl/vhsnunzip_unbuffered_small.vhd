library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.vhsnunzip_pkg.all;

-- Toplevel file used for gathering pentacore synthesis results.
entity vhsnunzip_unbuffered_small is
  port (
    clk         : in  std_logic;
    reset       : in  std_logic;

    co_valid    : in  std_logic;
    co_ready    : out std_logic;
    co_data     : in  std_logic_vector(63 downto 0);
    co_cnt      : in  std_logic_vector(2 downto 0);
    co_last     : in  std_logic;

    de_valid    : out std_logic;
    de_ready    : in  std_logic;
    de_dvalid   : out std_logic;
    de_data     : out std_logic_vector(63 downto 0);
    de_cnt      : out std_logic_vector(3 downto 0);
    de_last     : out std_logic
  );
end vhsnunzip_unbuffered_small;

architecture wrapper of vhsnunzip_unbuffered_small is
begin

  inst: vhsnunzip_unbuffered
    generic map (
      LONG_CHUNKS => false
    )
    port map (
      clk         => clk,
      reset       => reset,
      co_valid    => co_valid,
      co_ready    => co_ready,
      co_data     => co_data,
      co_cnt      => co_cnt,
      co_last     => co_last,
      de_valid    => de_valid,
      de_ready    => de_ready,
      de_dvalid   => de_dvalid,
      de_data     => de_data,
      de_cnt      => de_cnt,
      de_last     => de_last
    );

end wrapper;
