#!/usr/bin/env python3

import sys
import os
from os.path import join as pjoin
import tempfile
import subprocess
import itertools
import random
import vhdeps

# Parse command line.
def usage():
    print('Usage: %s <test-data-file> [generic/key=value [...]] -- \\\n'
          '  <vhdeps target> [vhdeps options...]' % sys.argv[0], file=sys.stderr)
    sys.exit(2)
try:
    args = iter(sys.argv)
    next(args)
    fname = next(args)
    keys = {key.lower(): value for key, value in map(
        lambda x: tuple(x.split('=', maxsplit=1)),
        itertools.takewhile(lambda x: x != '--', args))}
    vhdeps_target, *vhdeps_args = args
except (StopIteration, ValueError):
    usage()

# Seed the random generator.
random.seed(keys.pop('seed', 0))

# Read uncompressed file into memory.
with open(fname, 'rb') as fin:
    data = fin.read()

TESTCASE_VHD = """
library work;

entity vhsnunzip_tc is
end vhsnunzip_tc;

-- pragma simulation timeout 100 ms

architecture TestVector of vhsnunzip_tc is
begin

  tb_inst: entity work.vhsnunzip_tb
    generic map ({generics});

end TestVector;
"""

with tempfile.TemporaryDirectory() as tempdir:

    # Split the file up into chunks.
    chunk_size = int(keys.pop('chunk', '65536'), 0)
    max_chunk_size = int(keys.pop('max_chunk', str(chunk_size)), 0)
    min_chunk_size = int(keys.pop('min_chunk', str(chunk_size)), 0)
    verify = keys.pop('verify', None) != None
    offset = 0
    uncompressed_chunks = []
    compressed_chunks = []
    while offset < len(data):
        print('compressing chunk %d...' % len(compressed_chunks), end='\r')

        uncompressed_chunk = data[offset:offset + random.randint(min_chunk_size, max_chunk_size)]

        # Compress the chunk using snzip and check decompression with snunzip.
        with open(pjoin(tempdir, 'data'), 'wb') as fout:
            fout.write(uncompressed_chunk)
        subprocess.check_call(['tools/bin/snzip', '-traw', pjoin(tempdir, 'data')])
        with open(pjoin(tempdir, 'data.raw'), 'rb') as fin:
            compressed_chunk = fin.read()
        if verify:
            subprocess.check_call(['tools/bin/snunzip', '-traw', pjoin(tempdir, 'data.raw')])
            with open(pjoin(tempdir, 'data'), 'rb') as fin:
                assert fin.read() == uncompressed_chunk
            os.unlink(pjoin(tempdir, 'data'))
        else:
            os.unlink(pjoin(tempdir, 'data.raw'))

        offset += len(uncompressed_chunk)
        uncompressed_chunks.append(uncompressed_chunk)
        compressed_chunks.append(compressed_chunk)
    print()
    print('uncompressed size: %d' % sum(map(len, uncompressed_chunks)))
    print('compressed size: %d' % sum(map(len, compressed_chunks)))

    # Write the compressed data to a VHDL-friendly file format.
    with open(pjoin(tempdir, 'input.txt'), 'w') as fout:
        for chunk in compressed_chunks:
            for byte in chunk:
                fout.write('{:08b}\n'.format(byte))
            fout.write('\n')

    # Write the test case.
    generics = {
        'BYTES_PER_CYCLE': keys.pop('bytes_per_cycle', '4'),
        'DECODER_CFG': keys.pop('decoder_cfg', '"C"'),
        'HISTORY_DEPTH_LOG2': keys.pop('history_depth_log2', '16'),
    }
    generics = ', '.join(['%s => %s' % x for x in generics.items()])
    with open(pjoin(tempdir, 'vhsnunzip_tc.sim.08.vhd'), 'w') as fout:
        fout.write(TESTCASE_VHD.format(generics=generics))

    # Run vhdeps.
    code = vhdeps.run_cli([
        vhdeps_target, 'vhsnunzip_tc',
        '-i', '..', '-i', tempdir] + vhdeps_args)
    if code != 0:
        sys.exit(code)

    # Read the output file.
    uncompressed_chunks_out = [[]]
    with open(pjoin(tempdir, 'output.txt'), 'r') as fin:
        for line in fin.read().split('\n')[:-1]:
            if line in ('', 'error'):
                if line == 'error':
                    print('decompression error for chunk %d' % (len(uncompressed_chunks_out) - 1))
                uncompressed_chunks_out[-1] = bytes(uncompressed_chunks_out[-1])
                uncompressed_chunks_out.append([])
            else:
                try:
                    uncompressed_chunks_out[-1].append(int(line, 2))
                except ValueError:
                    print('error parsing output - U or X bit?')
                    sys.exit(1)
    uncompressed_chunks_out = uncompressed_chunks_out[:-1]
    #print(uncompressed_chunks_out)
    print('checking the output is TODO!')
    sys.exit(1)
