Hardware Snappy decompressor
============================

This repository contains a block that can decompress chunks of data compressed
using [Snappy](https://github.com/google/snappy)
[raw format](https://github.com/google/snappy/blob/master/format_description.txt).
It was written to read Snappy-compressed [Parquet](https://parquet.apache.org/)
files, but could be used in other contexts as well. The targeted FPGA family is
Xilinx UltraScale+, but aside from the memory primitives that were
unfortunately necessary it is vendor agnostic.

Two kinds of toplevel units are defined: an unbuffered and a buffered block:

 - The unbuffered version of the core uses 64kiB of block RAM or UltraRAM as a
   sliding window of decompressed data. This allows any raw Snappy chunk with
   copy element offsets no larger than 64kiB to be decompressed. Note that this
   maximum offset is a parameter of the compressor, and (currently) defaults to
   32kiB.

   If you know that the decompressed chunks will never be larger than 64kiB
   (this is true when decompressing
   [framed Snappy](https://github.com/google/snappy/blob/master/framing_format.txt)),
   you can disable support for decoding the headers for literal elements longer
   than 64kiB. This saves a few hundred LUTs and reduces the critical path
   length slightly.

 - The buffered version of the core uses the same amount of memory resources,
   but also uses them to buffer the input and output stream. This limits the
   chunk size to 64kiB (inclusive; fully incompressible chunks with compressed
   size 64kiB + 6 are also supported through additional LUT-based FIFOs in the
   decompression pipeline), increases LUT resource utilization, and reduces
   performance due to port sharing and the buffering operation itself, but
   allows multiple cores to work on decompressing a single datastream in
   parallel, without needing additional FIFOs. A multicore toplevel that
   handles the split and merge operation needed for this is also included.

   The width of the input and output stream is limited to 32 bytes by the
   bandwidth of the UltraRAMs. Additional BRAM-based FIFO-like buffers would
   be needed to handle a faster stream.

Synthesizing the above cores with various parameters for an UltraScale+ device
yields the following results (targeting xcvu5p-flva2104-2-i with default
synthesis parameters using Vivado v2017.4, last updated 69f61a56):

| Parameter              | Unbuffered <=64kiB | Unbuffered    | Buffered 1-core | Buffered 5-core | Buffered 8-core |
|------------------------|--------------------|---------------|-----------------|-----------------|-----------------|
| f_max                  | ~281MHz            | ~256MHz       | ~285MHz         | ~263MHz         | ~256MHz         |
| LUTs                   | ~1552 (0.3%)       | ~1844 (0.3%)  | ~2569 (0.4%)    | ~13106 (2.2%)   | ~20852 (3.5%)   |
| Registers              | ~935 (0.1%)        | ~1066 (0.1%)  | ~2324 (0.2%)    | ~11938 (1.0%)   | ~19223 (1.6%)   |
| BRAMs*                 | 0                  | 0             | 0               | 16 (1.6%)       | 32 (3.1%)       |
| URAMs*                 | 2 (0.4%)           | 2 (0.4%)      | 2 (0.4%)        | 8 (1.7%)        | 12 (2.6%)       |
| Throughput per cycle†  | ~5.5 B/cycle       | ~5.5 B/cycle  | ~4.0 B/cycle    | ~20 B/cycle     | ~32 B/cycle     |
| Throughput per second† | ~1.5 GB/s          | ~1.5 GB/s     | ~1.1 GB/s       | ~5.0 GB/s       | ~8.0 GB/s       |

*Each core can be configured to use 2 URAMs or 16 BRAMs, depending on what's
available. The multi-core design will by default try to match the BRAM/URAM
ratio to the relative availability on a Virtex UltraScale+ FPGA (=21/10).

†As can be expected with a decompression engine, the throughput varies with
the compressibility of the data; the numbers above were obtained using English
text. Theoretical minimum per core (for a sane compressor) is ~2.5 bytes per
cycle; theoretical maximum per core is 8 bytes per cycle; theoretical maximum
per multicore design is 32 bytes per cycle. The listed throughput for the
buffered core is slower because buffering time is accounted for. The throughput
numbers are output/decompressed-referenced.

Usage
-----

Include either `vhsnunzip` (multi-core) or `vhsnunzip_unbuffered` (single-core)
into your design. There is a component declaration in `vhsnunzip_pkg`. The
entity description describes the interface. The synthesis files have no
external dependencies besides the IEEE standard libraries.


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
