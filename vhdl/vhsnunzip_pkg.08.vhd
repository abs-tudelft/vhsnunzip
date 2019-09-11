library ieee;
use ieee.std_logic_1164.all;

-- Package containing toplevel component declarations for vhsnunzip.
package vhsnunzip_pkg is

  -- Streaming toplevel for vhsnunzip. This version of the decompressor doesn't
  -- include any large-scale input and output stream buffering, so the streams
  -- are limited to the speed of the decompression engine.
  component vhsnunzip_streaming is
    generic (
      RAM_STYLE   : string := "URAM"
    );
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
      de_data     : out std_logic_vector(63 downto 0);
      de_cnt      : out std_logic_vector(3 downto 0);
      de_dvalid   : out std_logic;
      de_last     : out std_logic
    );
  end component;

end package vhsnunzip_pkg;
