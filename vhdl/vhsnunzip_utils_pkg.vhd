library std;
use std.textio.all;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;

package vhsnunzip_utils_pkg is

  -- Returns 'U' during simulation, but '0' during synthesis.
  function undef_fn return std_logic;

end package vhsnunzip_utils_pkg;

package body vhsnunzip_utils_pkg is

  function undef_fn return std_logic is
    variable retval : std_logic := '0';
  begin
    -- pragma translate_off
    retval := 'U';
    -- pragma translate_on
    return retval;
  end function;

end package body vhsnunzip_utils_pkg;
