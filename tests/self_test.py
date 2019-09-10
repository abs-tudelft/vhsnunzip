
import random
from emu.operators import *
from emu.snappy import compress

seed = 0

while True:

    random.seed(seed)
    print('generate data for seed %d...' % seed)

    # Test lots of English Unicode text.
    data = b''
    with open('/home/jeroen/writing/01-the-hunt/output/01-the-hunt.txt', 'rb') as fil:
        data += fil.read() + b'\n\n\n'
    with open('/home/jeroen/writing/02-the-anomaly/output/02-the-anomaly.txt', 'rb') as fil:
        data += fil.read() + b'\n\n\n'
    with open('/home/jeroen/writing/03-the-rescue/output/03-the-rescue.txt', 'rb') as fil:
        data += fil.read() + b'\n\n\n'

    # Test data which can be compressed nicely with run-length encoding.
    for i in range(200):
        run = []
        for j in range(random.randint(1, 10)):
            run.append(random.randint(0, 255))
        run = bytes(run)
        run *= random.randint(1, 30)
        data += run

    # Test incompressible data.
    incompressible = []
    for i in range(65536):
        incompressible.append(bytes([i & 0xFF, i >> 8]))
    data += b''.join(incompressible)

    # Test perfectly compressible data.
    data += b'\0' * 65536

    # Chunk it up randomly.
    compressed, uncompressed = compress(
        data, 'tools/bin',
        min_chunk_size=1000, max_chunk_size=65536, max_prob=0.3)

    #cs = writer(data_source(compressed), '../vhdl/cs.tv')
    #cd = writer(pre_decoder(cs), '../vhdl/cd.tv')
    #el = writer(decoder(cd), '../vhdl/el.tv')
    #cm = writer(cmd_gen(el), '../vhdl/cm.tv')
    #de = writer(datapath(cm), '../vhdl/de.tv')

    print('checking...')

    class Counter():
        def __init__(self, generator):
            super().__init__()
            self.generator = generator
            self.count = 0

        def __iter__ (self):
            return self

        def __next__ (self):
            ret = next(self.generator)
            self.count += 1
            return ret

    class PopCounter(Counter):
        def __init__(self, generator):
            super().__init__(generator)
            self.pop_count = 0

        def __next__ (self):
            ret = super().__next__()
            if ret.ld_pop:
                self.pop_count += 1
            return ret

    cs = Counter(data_source(compressed))
    cd = Counter(pre_decoder(cs))
    el = PopCounter(decoder(cd))
    c1 = PopCounter(cmd_gen_1(el))
    cm = PopCounter(cmd_gen_2(c1))
    de = Counter(datapath(cm))

    for _ in verifier(de, uncompressed):
        pass

    print('uncompressed size=%d, compressed size=%d, chunk count=%d' % (
        len(data), sum(map(len, compressed)), len(compressed)))
    print('stream transfer counts: cs=%d, cd=%d, el=%d, c1=%d, cm=%d, de=%d' % (
        cs.count, cd.count, el.count, c1.count, cm.count, de.count))
    print('literal pop counts: el=%d, c1=%d, cm=%d' % (
        el.pop_count, c1.pop_count, cm.pop_count))
    print('approx. bytes/cycle: %.3f' % (
        len(data) / cm.count))

    assert cs.count == el.pop_count
    assert cs.count == c1.pop_count
    assert cs.count == cm.pop_count

    seed += 1

#decoder(printer(
