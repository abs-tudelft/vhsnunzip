library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.vhsnunzip_int_pkg.all;

-- Arbiter for the RAM access requests generated by the decompression pipeline
-- and input/output FIFO control blocks. There are two of these in each
-- buffered decompressor, corresponding to the two memory ports.
entity vhsnunzip_port_arbiter is
  generic (

    -- Priority assigned to each access port when the priority signal is low.
    -- A higher number means higher priority. Arbitration between same-priority
    -- ports is round-robin.
    IF_LO_PRIO  : natural_array(0 to 3) := (others => 0);

    -- Priority assigned to each access port when the priority signal is high.
    -- Note that interface 3 only supports one priority level, so this array
    -- only goes up to port 2.
    IF_HI_PRIO  : natural_array(0 to 2) := (others => 0);

    -- Must be set to the read latency of the addressed memory. This
    -- configuration is verified in simulation.
    LATENCY     : natural

  );
  port (
    clk         : in  std_logic;
    reset       : in  std_logic;

    -- Request interfaces. Interface 3 does not support two priority levels.
    req         : in  ram_request_array(0 to 3);
    req_ready   : out std_logic_array(0 to 3);
    resp        : out ram_response_pair_array(0 to 3);

    -- Memory interface. Both ports must have the same read latency.
    ev_cmd      : out ram_command;
    od_cmd      : out ram_command;
    ev_resp     : in  ram_response;
    od_resp     : in  ram_response

  );
end vhsnunzip_port_arbiter;

architecture behavior of vhsnunzip_port_arbiter is

  -- The arbiter is implemented using two 9-input lookup table (F9MUX on recent
  -- Xilinx architectures) with the following inputs:
  --  - 8: previous port index high
  --  - 7: previous port index low
  --  - 6: request 3 valid
  --  - 5: request 2 high priority
  --  - 4: request 2 valid
  --  - 3: request 1 high priority
  --  - 2: request 1 valid
  --  - 1: request 0 high priority
  --  - 0: request 0 valid
  -- The outputs are:
  --  - 1: selected port index high
  --  - 0: selected port index low
  -- The ability to put this in a single slice (per bit) is the reason for not
  -- supporting two priority levels on port 3. The following code generates the
  -- lookup table.
  type port_index_array is array (natural range <>) of unsigned(1 downto 0);
  function arb_lookup_fn return port_index_array is
    variable idx_bits : unsigned(8 downto 0);
    variable prev_idx : natural range 0 to 3;
    variable req_val  : std_logic_array(0 to 3);
    variable req_prio : natural_array(0 to 3);
    variable port_idx : natural;
    variable cur_prio : natural;
    variable retval   : port_index_array(0 to 511);
  begin
    for idx in 0 to 511 loop
      idx_bits := to_unsigned(idx, 9);
      prev_idx := to_integer(idx_bits(8 downto 7));
      for p in 0 to 3 loop
        req_val(p) := idx_bits(p*2);
      end loop;
      for p in 0 to 2 loop
        if idx_bits(p*2+1) = '1' then
          req_prio(p) := IF_HI_PRIO(p);
        else
          req_prio(p) := IF_LO_PRIO(p);
        end if;
      end loop;
      req_prio(3) := IF_LO_PRIO(3);

      -- Default (no requests active): retain port index state.
      retval(idx) := to_unsigned(prev_idx, 2);
      cur_prio := 0;

      for j in 3 downto 0 loop
        port_idx := (j + prev_idx + 1) mod 4;
        if req_val(port_idx) = '1' then
          if req_prio(port_idx) >= cur_prio then
            retval(idx) := to_unsigned(port_idx, 2);
            cur_prio := req_prio(port_idx);
          end if;
        end if;
      end loop;

    end loop;
    return retval;
  end function;
  constant ARB_LOOKUP : port_index_array(0 to 511) := arb_lookup_fn;

  -- Current and previous selected port index.
  signal port_idx     : unsigned(1 downto 0);
  signal port_idx_r   : port_index_array(0 to LATENCY);

  -- Pipeline registers for the even/odd read valid signals. Simulation-only;
  -- used to verify the latency configuration.
  -- pragma translate_off
  signal ev_rd_val_r  : std_logic_array(0 to LATENCY);
  signal od_rd_val_r  : std_logic_array(0 to LATENCY);
  -- pragma translate_on

begin

  arb_comb_proc: process (req, port_idx_r) is
    variable idx_bits   : unsigned(8 downto 0);
    variable port_idx_v : unsigned(1 downto 0);

    function bit_to_01(x: std_logic) return std_logic is
    begin
      if x = '1' or x = 'H' then
        return '1';
      else
        return '0';
      end if;
    end function;
  begin

    -- Construct the lookup table index. Basically, the F9 LUT inputs.
    idx_bits(8) := bit_to_01(port_idx_r(0)(1));
    idx_bits(7) := bit_to_01(port_idx_r(0)(0));
    for p in 0 to 3 loop
      idx_bits(p*2) := bit_to_01(req(p).valid);
    end loop;
    for p in 0 to 2 loop
      idx_bits(p*2+1) := bit_to_01(req(p).hipri);
    end loop;

    -- Infer the LUT.
    port_idx_v := ARB_LOOKUP(to_integer(idx_bits));
    port_idx <= port_idx_v;

    -- Decode the ready signals.
    for p in 0 to 3 loop
      if port_idx_v = p then
        req_ready(p) <= '1';
      else
        req_ready(p) <= '0';
      end if;
    end loop;

  end process;

  arb_reg_proc: process (clk) is
  begin
    if rising_edge(clk) then
      port_idx_r(1 to LATENCY) <= port_idx_r(0 to LATENCY-1);
      port_idx_r(0) <= port_idx;
      if reset = '1' then
        port_idx_r <= (others => "00");
      end if;
    end if;
  end process;

  -- Pipeline the 4:1 port request multiplexer, since it'll probably be fairly
  -- big and take input from a potentially large FPGA surface area.
  cmd_mux_proc: process (clk) is
  begin
    if rising_edge(clk) then
      ev_cmd.valid   <= req(to_integer(port_idx)).valid;
      ev_cmd.addr    <= req(to_integer(port_idx)).ev_addr;
      ev_cmd.wren    <= req(to_integer(port_idx)).ev_wren;
      ev_cmd.wdat    <= req(to_integer(port_idx)).ev_wdat;
      ev_cmd.wctrl   <= req(to_integer(port_idx)).ev_wctrl;

      od_cmd.valid   <= req(to_integer(port_idx)).valid;
      od_cmd.addr    <= req(to_integer(port_idx)).od_addr;
      od_cmd.wren    <= req(to_integer(port_idx)).od_wren;
      od_cmd.wdat    <= req(to_integer(port_idx)).od_wdat;
      od_cmd.wctrl   <= req(to_integer(port_idx)).od_wctrl;

      if reset = '1' then
        ev_cmd.valid <= '0';
        od_cmd.valid <= '0';
      end if;
    end if;
  end process;

  -- Broadcast the response data to all ports, but generate the valid and
  -- valid_next signals based on which port made the associated request.
  resp_broadcast_proc: process (ev_resp, od_resp, port_idx_r) is
  begin
    for p in 0 to 3 loop
      if port_idx_r(LATENCY) = p then
        resp(p).ev.valid <= ev_resp.valid;
        resp(p).od.valid <= od_resp.valid;
      else
        resp(p).ev.valid <= '0';
        resp(p).od.valid <= '0';
      end if;
      if port_idx_r(LATENCY - 1) = p then
        resp(p).ev.valid_next <= ev_resp.valid_next;
        resp(p).od.valid_next <= od_resp.valid_next;
      else
        resp(p).ev.valid_next <= '0';
        resp(p).od.valid_next <= '0';
      end if;
      resp(p).ev.rdat <= ev_resp.rdat;
      resp(p).od.rdat <= od_resp.rdat;
      resp(p).ev.rctrl <= ev_resp.rctrl;
      resp(p).od.rctrl <= od_resp.rctrl;
    end loop;
  end process;

  -- Check the latency setting in simulation by matching the
  -- pragma translate_off
  check_latency_proc: process (clk) is
  begin
    if rising_edge(clk) then

      -- Make our own pipeline for the expected read valid signals.
      ev_rd_val_r(0) <= req(to_integer(port_idx)).valid
                and not req(to_integer(port_idx)).ev_wren;
      od_rd_val_r(0) <= req(to_integer(port_idx)).valid
                and not req(to_integer(port_idx)).od_wren;
      ev_rd_val_r(1 to LATENCY) <= ev_rd_val_r(0 to LATENCY-1);
      od_rd_val_r(1 to LATENCY) <= od_rd_val_r(0 to LATENCY-1);

      if reset = '1' then
        ev_rd_val_r <= (others => '0');
        od_rd_val_r <= (others => '0');
      end if;

      -- Validate the read valid signals generated by the memory.
      if reset = '0' then
        assert ev_resp.valid = ev_rd_val_r(LATENCY) severity failure;
        assert od_resp.valid = od_rd_val_r(LATENCY) severity failure;
        assert ev_resp.valid_next = ev_rd_val_r(LATENCY - 1) severity failure;
        assert od_resp.valid_next = od_rd_val_r(LATENCY - 1) severity failure;
      end if;

    end if;
  end process;
  -- pragma translate_on

end behavior;