library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.vhsnunzip_pkg.all;

-- Behavioral description of a Xilinx URAM or collection of 8 BRAMs. 4k deep,
-- 8+1 bytes wide, for 32+4kiB of storage, with two R/W access ports. The total
-- read latency is exactly 3 cycles.
--
-- Unfortunately, Vivado cannot infer the memories from this, so this file
-- should be treated as simulation-only, and as a guideline for porting to a
-- different architecture.
entity vhsnunzip_ram is
  generic (

    -- RAM style generic for compatibility with the synthesis version of this
    -- file. Unused here.
    RAM_STYLE   : string := "URAM"

  );
  port (
    clk         : in  std_logic;

    -- Access port A.
    a_cmd       : in  ram_command;
    a_resp      : out ram_response;

    -- Access port B.
    b_cmd       : in  ram_command;
    b_resp      : out ram_response

  );
end vhsnunzip_ram;

architecture behavior of vhsnunzip_ram is

  constant CMD_STAGES   : natural := 1;
  constant RESP_STAGES  : natural := 1;

  type ram_line is record
    data  : byte_array(0 to 7);
    ctrl  : std_logic_vector(7 downto 0);
  end record;
  type ram_array is array (natural range <>) of ram_line;
  signal ram : ram_array(0 to 4095);

begin
  reg_proc: process (clk) is
    variable a_cmd_v  : ram_command_array(0 to CMD_STAGES);
    variable b_cmd_v  : ram_command_array(0 to CMD_STAGES);
    variable a_resp_v : ram_response_array(0 to RESP_STAGES);
    variable b_resp_v : ram_response_array(0 to RESP_STAGES);
  begin
    if rising_edge(clk) then

      -- Shift the pipeline registers.
      if CMD_STAGES > 0 then
        a_cmd_v(1 to CMD_STAGES) := a_cmd_v(0 to CMD_STAGES-1);
        b_cmd_v(1 to CMD_STAGES) := b_cmd_v(0 to CMD_STAGES-1);
      end if;
      if RESP_STAGES > 0 then
        a_resp_v(1 to RESP_STAGES) := a_resp_v(0 to RESP_STAGES-1);
        b_resp_v(1 to RESP_STAGES) := b_resp_v(0 to RESP_STAGES-1);
      end if;

      -- Insert the command into the pipeline.
      a_cmd_v(0) := a_cmd;
      b_cmd_v(0) := b_cmd;

      -- Execute the commands.
      a_resp_v(0).valid := '0';
      a_resp_v(0).rdat  := (others => (others => 'U'));
      a_resp_v(0).rctrl := (others => 'U');
      if a_cmd_v(CMD_STAGES).valid = '1' then
        if a_cmd_v(CMD_STAGES).wren = '1' then
          ram(to_integer(a_cmd_v(CMD_STAGES).addr)).data <= a_cmd_v(CMD_STAGES).wdat;
          ram(to_integer(a_cmd_v(CMD_STAGES).addr)).ctrl <= a_cmd_v(CMD_STAGES).wctrl;
        else
          a_resp_v(0).valid := '1';
          a_resp_v(0).rdat := ram(to_integer(a_cmd_v(CMD_STAGES).addr)).data;
          a_resp_v(0).rctrl := ram(to_integer(a_cmd_v(CMD_STAGES).addr)).ctrl;
        end if;
      end if;

      b_resp_v(0).valid := '0';
      b_resp_v(0).rdat  := (others => (others => 'U'));
      b_resp_v(0).rctrl := (others => 'U');
      if b_cmd_v(CMD_STAGES).valid = '1' then
        if b_cmd_v(CMD_STAGES).wren = '1' then
          ram(to_integer(b_cmd_v(CMD_STAGES).addr)).data <= b_cmd_v(CMD_STAGES).wdat;
          ram(to_integer(b_cmd_v(CMD_STAGES).addr)).ctrl <= b_cmd_v(CMD_STAGES).wctrl;
        else
          b_resp_v(0).valid := '1';
          b_resp_v(0).rdat := ram(to_integer(b_cmd_v(CMD_STAGES).addr)).data;
          b_resp_v(0).rctrl := ram(to_integer(b_cmd_v(CMD_STAGES).addr)).ctrl;
        end if;
      end if;

      -- Output the results.
      a_resp <= a_resp_v(RESP_STAGES);
      b_resp <= b_resp_v(RESP_STAGES);

    end if;
  end process;
end behavior;
