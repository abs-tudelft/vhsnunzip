library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.vhsnunzip_pkg.all;

-- Toplevel file used for gathering octocore synthesis results.
entity vhsnunzip_8 is
  port (
    clk         : in  std_logic;
    reset       : in  std_logic;

    in_valid    : in  std_logic;
    in_ready    : out std_logic;
    in_data     : in  std_logic_vector(255 downto 0);
    in_cnt      : in  std_logic_vector(4 downto 0);
    in_last     : in  std_logic;

    out_valid   : out std_logic;
    out_ready   : in  std_logic;
    out_dvalid  : out std_logic;
    out_data    : out std_logic_vector(255 downto 0);
    out_cnt     : out std_logic_vector(4 downto 0);
    out_last    : out std_logic
  );
end vhsnunzip_8;

architecture structure of vhsnunzip_8 is
begin

  inst: vhsnunzip
    generic map (
      COUNT       => 8
    )
    port map (
      clk         => clk,
      reset       => reset,
      in_valid    => in_valid,
      in_ready    => in_ready,
      in_data     => in_data,
      in_cnt      => in_cnt,
      in_last     => in_last,
      out_valid   => out_valid,
      out_ready   => out_ready,
      out_dvalid  => out_dvalid,
      out_data    => out_data,
      out_cnt     => out_cnt,
      out_last    => out_last
    );

end structure;
