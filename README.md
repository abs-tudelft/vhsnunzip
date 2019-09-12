Hardware Snappy decompressor
============================

Work in progress
----------------

**The code contained here is still a work in progress, but should be completed shortly. See [#1](https://github.com/jvanstraten/vhsnunzip/issues/1).**

This repository contains a block that can decompress chunks of up to 64kiB of
data (inclusive) compressed using [Snappy](https://github.com/google/snappy)
[raw format](https://github.com/google/snappy/blob/master/format_description.txt).
It was written to read Snappy-compressed [Parquet](https://parquet.apache.org/)
files, but could be used in other contexts as well, as long as the chunk size
is limited. The targeted FPGA family is Xilinx Ultrascale+, but aside from the
memory primitives that were unfortunately necessary it is vendor agnostic.

Two kinds of toplevel units are defined: a single-core block and a multi-core
block. The single-core block is faster per core, but the overall throughput of
the multi-core version can obviously be made much higher. Some numbers for the
cores for a Virtex UltraScale+ with speed grade -2:

|             | Single-core | 5-core | 8-core |
|-------------|-------------|--------|--------|
| f_max       | ~285MHz     | ???‡   | ???‡   |
| LUTs        | ~1600       | ???‡   | ???‡   |
| Registers   | ~900        | ???‡   | ???‡   |
| BRAMs*      | 0           | 16     | 16     |
| URAMs*      | 2           | 8      | 14     |
| Throughput† | 5.5 B/cycle | ???‡   | ???‡   |

*Each core can be configured to use 2 URAMs or 16 BRAMs, depending on what's
available. The multi-core design will by default try to match the BRAM/URAM
ratio to the relative availability on a Virtex UltraScale+ FPGA (=21/10).

†As can be expected with a decompression engine, the throughput varies with
the compressibility of the data. Theoretical minimum per core (for a sane
compressor) is ~2.5 bytes per cycle; theoretical maximum per core is 8 bytes
per cycle; theoretical maximum per multicore design is 32 bytes per cycle.
The throughput numbers are output/decompressed-referenced.

‡The multicore design is still a work in progress.


Usage
-----

Include either `vhsnunzip` (multi-core) or `vhsnunzip_unbuffered` (single-core)
into your design. There is a component declaration in `vhsnunzip_pkg`. The
entity description describes the interface. The synthesis files have no
external dependencies besides the IEEE standard libraries.

Currently the design files require VHDL-2008, but there is no good reason for
this. It should be easy to port them over to VHDL-93, I just haven't done it
yet.


Simulation/verification
-----------------------

To run the test cases, you need to do the following:

 - Initialize/update the three submodules:
   [the snappy library](https://github.com/google/snappy),
   [the snzip CLI tool](https://github.com/kubo/snzip),
   and [`vhlib`](https://github.com/abs-tudelft/vhlib).
 - Run `make` in `tests/tools`. This configures and compiles Snappy and snzip
   in a local directory (no root required). If this fails for whatever reason,
   try to get the `snzip` and `snunzip` executables elsewhere, and symlink them
   in `tests/tools/bin` (you might need to make this directory).
 - From the `tests` directory, run `python3 test.py <some file>`. The file you
   specify will be split into 64kiB blocks, compressed using `snzip`, and then
   decompressed using a Python model of the basic datapath. The result is
   verified for correctness, and the stream transfers that the Python model
   expects from the hardware are serialized to `vhdl/*.tv`.
 - Simulate the test cases in your preferred tool. The test cases look for the
   `*.tv` files in the current working directory, so make sure you copy them
   there if that's not the `vhdl` directory. The test cases are verified
   to work with GHDL and Modelsim/Questasim through
   [`vhdeps`](https://github.com/abs-tudelft/vhdeps) (in fact, the `test.py`
   script can run `vhdeps` for you automatically, but its command line is a bit
   arcane), and should also work with Vivado's built-in simulator.
