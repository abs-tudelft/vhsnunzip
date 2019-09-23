#!/usr/bin/env python3

import sys
import os
import shutil
import subprocess

def report_info(toplevel):
    """Reports key specs for the given toplevel, if synthesis data for that
    toplevel is available. Returns whether this data was available."""

    # Figure out the paths.
    timing_fname = 'synth_%s/timing.log' % toplevel
    util_fname = 'synth_%s/utilization.log' % toplevel
    if not os.path.isfile(timing_fname) or not os.path.isfile(util_fname):
        return False

    # Parse the timing file.
    with open(timing_fname, 'r') as fil:
        timing = fil.read()
    max_f_mhz = 1000.0 / (4.0 - float(timing.split('WNS(ns)')[1].split('\n')[2].split()[0]))

    # Parse the resource utilization file.
    with open(util_fname, 'r') as fil:
        util = fil.read()
    luts = int(util.split('CLB LUTs')[1].split('|')[1].split()[0])
    regs = int(util.split('CLB Registers')[1].split('|')[1].split()[0])
    bram = int(util.split('Block RAM Tile')[1].split('|')[1].split()[0])
    uram = int(util.split('URAM')[1].split('|')[1].split()[0])

    # Print summary/
    print('Key specs for %s:' % toplevel)
    print(' - Max. freq: %.2f MHz' % max_f_mhz)
    print(' - LUTs:      %6d %.1f%%' % (luts, luts / 6005.77))
    print(' - Registers: %6d %.1f%%' % (regs, regs / 12011.54))
    print(' - BRAMs:     %6d %.1f%%' % (bram, bram / 10.24))
    print(' - URAMs:     %6d %.1f%%' % (uram, uram / 4.70))
    print()

    return True

# Parse command line.
def usage():
    print('Usage: %s [toplevel]' % sys.argv[0], file=sys.stderr)
    sys.exit(2)
if len(sys.argv) > 2 or (len(sys.argv) > 1 and sys.argv[1] in ['-h', '-help', '--help']):
    usage()

# If we get an argument, treat it as a toplevel file that the user wants data
# for. If the data isn't available yet, try to get it.
if len(sys.argv) > 1:
    toplevel = sys.argv[1]

    # See if the result files exist already. If not, try to run Vivado to get
    # them.
    synth_dir = 'synth_%s' % toplevel

    if not report_info(toplevel):
        if os.path.isdir(synth_dir):
            shutil.rmtree(synth_dir)
        subprocess.check_call([
            'vivado', '-nolog', '-nojournal', '-mode', 'batch',
            '-source', 'synthesize.tcl', '-tclargs', toplevel])
        report_info(toplevel)

# If we don't get a command-line argument, just list all the data that's
# currently available.
else:
    for directory in os.listdir('.'):
        if not os.path.isdir(directory):
            continue
        if not directory.startswith('synth_'):
            continue
        report_info(directory[6:])
