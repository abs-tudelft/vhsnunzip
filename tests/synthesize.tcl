# This script implements the design specified by the following parameters with
# synthesis defaults and then reports timing and utilization. Run it like this
# (or have synthesize.py do it for you):
#
#   vivado -nolog -nojournal -mode batch -source synthesize.tcl -tclargs <toplevel>
#
# where <toplevel> is one of
#
#   `vhsnunzip_unbuffered`: streaming core.
#   `vhsnunzip_buffered`: buffered, single core.
#   `vhsnunzip_5`: buffered pentacore.
#   `vhsnunzip_8`: buffered octocore.
#
# You can run these four tasks in parallel if you like. The following log files
# will be generated if successful:
#
#   ./synth_<toplevel>/timing.log
#   ./synth_<toplevel>/utilization.log
#
set top [lindex $argv 0]
set project_name "synth_$top"
set part xcvu5p-flva2104-2-i

# Create project.
create_project $project_name ./$project_name -part $part
set_property -name "default_lib" -value "xil_defaultlib" -objects [current_project]
set_property -name "part" -value $part -objects [current_project]
set_property -name "target_language" -value "VHDL" -objects [current_project]

# Create filesets.
if {[string equal [get_filesets -quiet sources_1] ""]} {
  create_fileset -srcset sources_1
}
if {[string equal [get_filesets -quiet constrs_1] ""]} {
  create_fileset -constrset constrs_1
}

# Add VHDL files.
set files [list]
foreach fname [glob ../vhdl/*.vhd] {
  if [expr ![string match *.sim.* $fname]] {
    lappend files $fname
  }
}
add_files -norecurse -fileset [get_filesets sources_1] $files

# Add constraints files.
set file [add_files -norecurse -fileset [get_filesets constrs_1] "constraints.xdc"]
set_property -name "file_type" -value "XDC" -objects $file

# Set the toplevel file.
set_property -name "top" -value $top -objects [get_filesets sources_1]

# Synthesize the design.
synth_design
opt_design
place_design
route_design

# Report results.
report_timing_summary -file ./$project_name/timing.log
report_utilization -file ./$project_name/utilization.log
