#!/usr/bin/env python3

import random
import sys
import itertools
from emu.operators import *
from emu.snappy import compress

# Parse command line.
def usage():
    print('Usage: %s <test-data-file> [config=value [...]] \\\n'
          '  [-- <vhdeps target> [vhdeps options...]]' % sys.argv[0], file=sys.stderr)
    sys.exit(2)
try:
    args = iter(sys.argv)
    next(args)
    fname = next(args)
    keys = {key.lower(): value for key, value in map(
        lambda x: tuple(x.split('=', maxsplit=1)),
        itertools.takewhile(lambda x: x != '--', args))}
    vhdeps_target, *vhdeps_args = args
except ValueError:
    vhdeps_target = None
    vhdeps_args = []
except StopIteration:
    usage()

# Seed the random generator.
random.seed(keys.pop('seed', 0))

# Read uncompressed file into memory.
print('Reading input...')
with open(fname, 'rb') as fin:
    data = fin.read()

# Chunk it up randomly.
print('Compressing input...')
chunk_size = int(keys.pop('chunk', '65536'), 0)
compressed, uncompressed = compress(
    data, 'tools/bin',
    min_chunk_size=int(keys.pop('min_chunk', str(chunk_size)), 0),
    max_chunk_size=int(keys.pop('max_chunk', str(chunk_size)), 0),
    max_prob=float(keys.pop('max_prob', '0')),
    verify=keys.pop('verify', None) != None)

print('Write expected input and output...')
drain(writer(wide_data_source(compressed), '../vhdl/in.tv'))
drain(writer(wide_data_source(uncompressed), '../vhdl/out.tv'))

print('Simulating decompression in Python...')
cs = Counter(writer(data_source(compressed), '../vhdl/cs.tv'))
cd = Counter(writer(pre_decoder(cs), '../vhdl/cd.tv'))
el = Counter(writer(decoder(cd), '../vhdl/el.tv'))
c1 = Counter(writer(cmd_gen_1(el), '../vhdl/c1.tv'))
cm = Counter(writer(cmd_gen_2(c1), '../vhdl/cm.tv'))
de = Counter(writer(datapath(cm), '../vhdl/de.tv'))
drain(verifier(de, uncompressed))

# Run vhdeps if requested.
if vhdeps_target is not None:
    print('Checking that VHDL and Python streams match...')
    import vhdeps
    code = vhdeps.run_cli([
        vhdeps_target,
        'vhsnunzip_pre_decoder_tc', 'vhsnunzip_decoder_tc',
        'vhsnunzip_cmd_gen_1_tc', 'vhsnunzip_cmd_gen_2_tc',
        'vhsnunzip_pipeline_tc', 'vhsnunzip_unbuffered_tc',
        'vhsnunzip_tc',
        '-i', '..'] + vhdeps_args)
    if code != 0:
        sys.exit(code)

print()
print('Statistics:')
print('  Uncompressed size=%d, compressed size=%d, chunk count=%d' % (
    len(data), sum(map(len, compressed)), len(compressed)))
print('  Stream transfer counts: cs=%d, cd=%d, el=%d, c1=%d, cm=%d, de=%d' % (
    cs.count, cd.count, el.count, c1.count, cm.count, de.count))
print('  Approx. bytes/cycle: %.3f' % (
    len(data) / cm.count))

print()
print('All good!')
