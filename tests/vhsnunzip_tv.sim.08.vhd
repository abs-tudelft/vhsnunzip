-- Copyright 2019 Delft University of Technology
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

library std;
use std.textio.all;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;

library work;
use work.TestCase_pkg.all;
use work.StreamSource_pkg.all;
use work.StreamMonitor_pkg.all;
use work.StreamSink_pkg.all;

entity vhsnunzip_tv is
end vhsnunzip_tv;

architecture testvector of vhsnunzip_tv is
begin

  test_tc: process is
    file infile       : text;
    variable inline   : line;
    file outfile      : text;
    variable outline  : line;
    variable i        : streamsource_type;
    variable o        : streamsink_type;
    variable data     : std_logic_vector(7 downto 0);
    variable chunks   : natural;
    variable timeout  : natural;
    variable bytes    : natural;
  begin
    tc_open("vhsnunzip", "basic test for vhsnunzip");

    -- Initialize the input.
    i.initialize("in");
    file_open(infile, "input.txt",  read_mode);
    chunks := 0;
    bytes := 0;
    while not endfile(infile) loop
      readline(infile, inline);
      if inline.all = "" then
        tc_note("transmit chunk " & integer'image(chunks) & "...");
        i.transmit;
        chunks := chunks + 1;
      else
        if bytes mod 1000 = 0 then
          tc_note("queued byte " & integer'image(bytes) & " for chunk " & integer'image(chunks) & "...");
        end if;
        read(inline, data);
        i.push_slv(data);
        bytes := bytes + 1;
      end if;
    end loop;
    file_close(infile);

    -- Initialize the output.
    o.initialize("out");
    o.unblock;

    -- Run the test.
    file_open(outfile, "output.txt", write_mode);
    timeout := 50;
    while chunks > 0 loop
      tc_check(timeout > 0, "timeout");
      tc_wait_for(100 us);
      if o.pq_ready then
        while o.pq_avail loop
          data := o.pq_get_slv;
          write(outline, data);
          writeline(outfile, outline);
        end loop;
        writeline(outfile, outline);
        chunks := chunks - 1;
        timeout := 50;
      else
        timeout := timeout - 1;
      end if;
    end loop;
    file_close(outfile);

    tc_pass;
    wait;
  end process;

end testvector;

