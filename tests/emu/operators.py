
from .streams import *

def data_source(chunks):
    """Represents a compressed data provider. `chunks` should be an iterable of
    chunk data, in turn represented as bytes objects. Yields a
    `CompressedStreamSingle` stream."""

    for chunk in chunks:
        for offs in range(0, len(chunk), WI):
            data = tuple(chunk[offs:offs+WI])
            endi = len(data) - 1
            data += (0,) * (WI - len(data))
            last = offs + WI >= len(chunk)
            yield CompressedStreamSingle(data, last, endi)


def wide_data_source(chunks):
    """Represents a data provider. `chunks` should be an iterable of
    chunk data, in turn represented as bytes objects. Yields a
    `WideIOStream` stream."""

    for chunk in chunks:
        if chunk:
            for offs in range(0, len(chunk), WI*4):
                data = tuple(chunk[offs:offs+WI*4])
                cnt = len(data)
                data += (0,) * (WI*4 - len(data))
                last = offs + WI*4 >= len(chunk)
                yield WideIOStream(True, data, last, cnt)
        else:
            yield WideIOStream(False, (0,) * (WI*4), True, 0)


def pre_decoder(cs_stream):
    """Models the pre-decoder block."""

    def parallelize(cs_stream):
        prev = None
        for cur in cs_stream:
            if prev is not None:
                yield prev, cur
            if cur.last:
                yield cur, CompressedStreamSingle((0,)*WI, False, WI-1)
                cur = None
            prev = cur

    busy = False
    for cur, nxt in parallelize(cs_stream):
        first = not busy
        busy = not cur.last
        if first:
            for start in range(WI):
                if not cur.data[start] & 0x80:
                    break
            start += 1

        if cur.last:
            py_endi = cur.endi
        elif nxt.last:
            py_endi = WI + nxt.endi
        else:
            py_endi = WI*2-1

        yield CompressedStreamDouble(
            cur.data + nxt.data,
            first, start,
            cur.last, cur.endi, py_endi)


def decoder(cd):
    """Models the decoder block."""

    off = 0
    cdh_valid = False

    cd = iter(cd)

    while True:

        # pull in a new half-line from the compressed stream when we need it
        first = False
        if not cdh_valid:
            cdh = next(cd)
            cdh_valid = True
            data = cdh.data
            if cdh.first:
                off = cdh.start
                first = True

        # Handle copy element.
        ofi = off & (WI-1)
        if off > cdh.endi or data[ofi] & 3 == 0:
            cp_val = False
            cp_off = 0
            cp_len = 0
        elif data[ofi] & 3 == 1:
            cp_val = True
            cp_off = (((data[ofi] >> 5) & 7) << 8) | data[ofi+1]
            cp_len = ((data[ofi] >> 2) & 7) + 3
            off += 2
        elif data[ofi] & 3 == 2:
            cp_val = True
            cp_off = data[ofi+1] | (data[ofi+2] << 8)
            cp_len = (data[ofi] >> 2) & 63
            off += 3
        elif data[ofi] & 3 == 3:
            raise ValueError('oh_snap')

        # Handle literal header.
        ofi = off & (WI-1)
        li_val = off <= cdh.endi and data[ofi] & 3 == 0
        li_len = data[ofi] >> 2
        if li_len == 60:
            li_len = data[ofi+1]
            li_hdlen = 2
        elif li_len == 61:
            li_len = (data[ofi+2] << 8) | data[ofi+1]
            li_hdlen = 3
        elif li_len > 61:
            li_hdlen = 1
            if li_val:
                raise ValueError('oh_snap')
        else:
            li_hdlen = 1
        if li_val:
            li_off = off + li_hdlen
        else:
            li_off = 0

        if li_val:
            off += li_hdlen + li_len + 1

        # Check if we need to pull in new data in the next cycle and preadjust
        # the offset accordingly.
        last = False
        ld_pop = False
        if off > cdh.endi:
            off -= WI
            cdh_valid = False
            ld_pop = True
            last = cdh.last

        yield ElementStream(
            cp_val, cp_off, cp_len,
            li_val, li_off, li_len, ld_pop,
            last, data)


def cmd_gen_1(elements):
    """Emulates stage 1 of the datapath command generator block. This stage
    preprocesses the copy elements into chunks such that the chunk length is
    limited to WB and cp_off, unless cp_off == 1 and run-length acceleration
    applies."""

    elements = iter(elements)

    elh_valid = False

    cp_rem = -1 # diminished-one!
    elh_cp_off = 0

    while True:

        # Load next element pair if we need more data.
        if not elh_valid:
            elh = next(elements)
            elh_valid = True
            if elh.cp_val:
                cp_rem = elh.cp_len
            elh_cp_off = elh.cp_off

        # Record the current copy offset for the partial command. We might
        # change it to increase the amount of bytes we can copy per cycle in
        # a run-length-encoded copy.
        cp_off = elh_cp_off

        # Determine how many bytes we can write for the copy element. If there
        # is no copy element, this becomes 0 automatically
        cp_len = min(cp_rem, WI-1)

        if elh_cp_off <= 1:

            # Special case for single-byte repetition, since it's relatively
            # common and otherwise has worst-case 1-byte/cycle performance.
            # Requires some extra logic in the address/rotation decoders
            # though; cp_rol becomes an index rather than a rotation when
            # cp_rle is set. Can be disabled by just not taking this branch.
            cp_rle = True

        else:

            # Without run-length=1 acceleration, we can't copy more bytes at
            # once than the copy offset, because we'd be reading beyond what
            # we've written already.
            if cp_len >= elh_cp_off:
                cp_len = elh_cp_off - 1
                advance = False

                # We can however accelerate subsequent copies; after the first
                # copy we have two consecutive copies in memory, after the
                # second we have four, and so on. Note that cp_off bit 3 and above
                # must be zero here, because cp_len was larger and
                # cp_len can be at most 8, so we can ignore them in the
                # leftshift.
                assert elh_cp_off < WI
                elh_cp_off <<= 1

            cp_rle = False

        # Update state.
        cp_rem -= cp_len + 1

        # Advance if there are no (more) bytes in the copy.
        advance = cp_rem < 0
        if elh_valid and advance:
            elh_valid = False

        yield PartialCommandStream(
            cp_off, cp_len, cp_rle,
            elh.li_val and advance, elh.li_off, elh.li_len,
            elh.ld_pop and advance, elh.last and advance,
            elh.py_data)


def cmd_gen_2(partial_commands):
    """Emulates stage 2 of the datapath command generator block. This does
    whatever stage 1 doesn't."""

    partial_commands = iter(partial_commands)

    off = 0
    lt_cnt = 0
    c1h_valid = False

    c1_pend = False

    cp_len = -1 # diminished-one!

    li_len = -1 # diminished-one!
    li_off = 0

    while True:

        # Load next element pair if we need more data.
        if not c1h_valid:
            c1h = next(partial_commands)
            c1h_valid = True
            c1_pend = c1h.cp_len >= 0 or c1h.li_val

        # If we're out of stuff to do, load the next commands.
        if li_len < 0 and c1_pend:
            cp_len = c1h.cp_len
            if c1h.li_val:
                li_len = c1h.li_len
            li_off = c1h.li_off
            c1_pend = False

        py_start = off

        # Compute copy source addresses.
        cp_src_rel = off - c1h.cp_off
        cp_src_rc1_line = cp_src_rel >> WB
        cp_src_rc1_offs = cp_src_rel & (WI-1)

        # cp_src_rc1_line = relative; 0 = current line, positive is further
        # forward.
        st_addr = ~cp_src_rc1_line#-1 - cp_src_rc1_line
        st_addr &= 31

        # lt_addr = absolute; 0 = first line, 1 = second line, etc.
        lt_val = cp_src_rc1_line < -31 and cp_len >= 0
        lt_addr = lt_cnt + cp_src_rc1_line

        lt_swap = bool(lt_addr & 1)
        lt_adev = ((lt_addr + 1) >> 1) & (32767 >> WB)
        lt_adod = (lt_addr >> 1) & (32767 >> WB)

        # Determine the rotation/byte mux selection.
        if c1h.cp_rle:
            cp_rol = cp_src_rc1_offs
        else:
            cp_rol = (cp_src_rc1_offs - off) & (WI*2-1)

        # Determine how many byte slots are still available for the literal.
        budget = (cp_len & (WI*2-1)) ^ (WI-1)

        # Update state for copy.
        off += cp_len + 1

        # Thanks to the preprocessing in stage 1, each copy command can be
        # handled in a single cycle, so we're done with it now.
        cp_len = -1

        # Save the offset after the copy so the datapath can derive which
        # bytes should come from the copy path.
        cp_end = off

        # Handle literal data.
        li_chunk_len = min(li_len + 1, WI*2 - li_off, budget)

        # Hardware optimization at the cost of a tiny amount of throughput;
        # can be disabled.
        if li_off >= 8:
            li_chunk_len = 0

        li_rol = (li_off - off) & (WI*2-1)

        # Update state for literal.
        off += li_chunk_len
        li_off += li_chunk_len
        li_len -= li_chunk_len

        li_end = off

        # Wrap the destination offset. Up to this point we need a bit extra!
        if off >= WI:
            lt_cnt += 1
        off &= WI - 1

        # Determine whether we still need more literal data from this element.
        # (this is possible if we ran out of write budget for this cycle)
        ld_pend = li_len >= 0 and li_off < WI

        # If this is the last element input stream entry, don't pop it until
        # we're completely done with it (not just done with decoding it).
        finishing = c1h.last and (li_len >= 0 or cp_len >= 0)

        # Invalidate the element record when we have no more need for it, so
        # the next record can be loaded.
        ld_pop = False
        last = False
        if c1h_valid and not (cp_len >= 0 or c1_pend or ld_pend or finishing):
            c1h_valid = False
            ld_pop = c1h.ld_pop
            last = c1h.last
            li_off -= WI
            if last:
                off = 0
                lt_cnt = 0

        yield CommandStream(
            lt_val, lt_adev, lt_adod, lt_swap,
            st_addr, cp_rol, c1h.cp_rle, cp_end,
            li_rol, li_end, ld_pop, last,
            c1h.py_data, py_start)


class SRL:
    """Emulates behavior of a Xilinx SRL (shift register lookup)."""

    def __init__(self, depth):
        super().__init__()
        self._data = [0] * depth
        self._ptr = 0

    def push(self, value):
        self._ptr -= 1
        self._ptr %= len(self._data)
        self._data[self._ptr] = value

    def __getitem__(self, index):
        return self._data[(self._ptr + index) % len(self._data)]


def datapath(commands):
    """Emulates the datapath block."""

    # Short-term memory.
    st = [SRL(32) for _ in range(WI)]

    # Long-term memory.
    lt = [(0,)*WI] * 2**(16-WB)

    # Amount of lines written.
    wr_ptr = 0

    # In the hardware, we get the literal data from another SRL, similar to
    # the short-term memory. Here we cheat a little and take it from
    # cm.py_data, so we don't need to model additional communication between
    # the generators.

    # Source selection for the copy pre-mux per byte:
    #  - 0 or 1: short-term
    #  - 2: long-term even
    #  - 3: long-term odd
    cp_sel = [0] * WI

    # Data after the source selector.
    cp_data = [0] * WI

    # Lookahead bit. When set, the literal/short-term SRL address should be
    # shifted forward.
    li_la = [0] * WI
    st_la = [0] * WI

    # Rotation selection for the 8:8 rotation mux per byte:
    rol_sel = [0] * WI

    # Output selection per byte:
    #  - 0: literal
    #  - 1: copy
    mux_sel = [0] * WI

    # Data after the rotation and output selection.
    mux_data = [0] * WI

    # Output holding register.
    oh_valid = [False] * (WI)
    oh_data = [0] * (WI)

    for cm in commands:

        # Decode the mux control signals.
        for byte in range(WI):

            # Determine if this byte is a copied or a literal byte.
            if byte < cm.cp_end - WI:
                mux = 1
            elif byte < cm.li_end - WI:
                mux = 0
            elif byte < cm.cp_end:
                mux = 1
            else:
                mux = 0

            # Determine the copy rotation.
            if cm.cp_rle:
                cp_rol = (cm.cp_rol - byte) & (WI*2-1)
            else:
                cp_rol = cm.cp_rol

            # Determine the rotation for the final rotator mux.
            rol = cp_rol if mux else cm.li_rol

            # We're trying to do a WI*2-wide rotation with a WI-wide rotator by
            # exploiting the fact that:
            #
            #  - we only need WI bytes at a time
            #  - we can determine the addresses with 8-byte granularity on a
            #    byte-by-byte basis.
            #
            # Example lookup table for WI=4:
            #
            # Desired rotation output with don't cares:
            #
            #         end 0     end 1     end 2     end 3     end 4     end 5     end 6     end 7
            #        ........  ........  ........  ........  ........  ........  ........  ........
            # rol 0: --------  0-------  01------  012-----  0123----  -1234---  --2345--  ---3456-
            # rol 1: --------  1-------  12------  123-----  1234----  -2345---  --3456--  ---4567-
            # rol 2: --------  2-------  23------  234-----  2345----  -3456---  --4567--  ---5670-
            # rol 3: --------  3-------  34------  345-----  3456----  -4567---  --5670--  ---6701-
            # rol 4: --------  4-------  45------  456-----  4567----  -5670---  --6701--  ---7012-
            # rol 5: --------  5-------  56------  567-----  5670----  -6701---  --7012--  ---0123-
            # rol 6: --------  6-------  67------  670-----  6701----  -7012---  --0123--  ---1234-
            # rol 7: --------  7-------  70------  701-----  7012----  -0123---  --1234--  ---2345-
            #
            #
            # Lookahead bits needed (whether 4..7 is needed in the rotation output):
            #
            #         end 0     end 1     end 2     end 3     end 4     end 5     end 6     end 7
            #        ........  ........  ........  ........  ........  ........  ........  ........
            # rol 0: ----      0---      00--      000-      0000      1000      1100      1110
            # rol 1: ----      -0--      -00-      -000      1000      1100      1110      1111
            # rol 2: ----      --0-      --00      1-00      1100      1110      1111      0111
            # rol 3: ----      ---0      1--0      11-0      1110      1111      0111      0011
            # rol 4: ----      1---      11--      111-      1111      0111      0011      0001
            # rol 5: ----      -1--      -11-      -111      0111      0011      0001      0000
            # rol 6: ----      --1-      --11      0-11      0011      0001      0000      1000
            # rol 7: ----      ---1      0--1      00-1      0001      0000      1000      1100
            #
            # Notice that the tables for end index 0..3 match the table for index 4.
            prec = max(0, cm.li_end - WI)

            # Determine if we want to select from the addressed line or the
            # subsequent line.
            cpl = ((byte - cm.cp_rol - prec) & (WI*2-1)) >= WI
            lil = ((byte - cm.li_rol - prec) & (WI*2-1)) >= WI
            #if byte + WI < cm.li_end:
                ## toggle index byte - cp_rol
                #cpl = not cpl
                #lil = not lil
            if cm.cp_rle:
                cpl = False

            # Determine the copy source:
            #  - 0 or 1 = short-term
            #  - 2 = long-term even
            #  - 3 = long-term odd
            cps = 2 * bool(cm.lt_val)
            cps += bool(cpl ^ cm.lt_swap)

            cp_sel[byte] = cps
            rol_sel[byte] = rol
            mux_sel[byte] = mux
            li_la[byte] = lil
            st_la[byte] = cpl

        # Load the data sources available to the datapath.
        li_data = tuple((cm.py_data[byte + WI*li_la[byte]] for byte in range(WI)))
        st_data = tuple((st[byte][cm.st_addr - st_la[byte] + oh_valid[byte]] for byte in range(WI)))
        le_data = lt[cm.lt_adev * 2]
        lo_data = lt[cm.lt_adod * 2 + 1]

        # Generate the copy source multiplexer.
        for byte in range(WI):
            if cp_sel[byte] == 2:
                cp_data[byte] = le_data[byte]
            elif cp_sel[byte] == 3:
                cp_data[byte] = lo_data[byte]
            else:
                cp_data[byte] = st_data[byte]

        # Generate the rotator and output mux.
        for byte in range(WI):
            src_data = cp_data if mux_sel[byte] else li_data
            mux_data[byte] = src_data[(rol_sel[byte] + byte) & (WI-1)]

        #if cm.lt_val:
            #print(cm)
            #print('st (0)  |%s|' % safe_chr(st_data, oneline=True))
            #print('le (1)  |%s|' % safe_chr(le_data, oneline=True))
            #print('lo (2)  |%s|' % safe_chr(lo_data, oneline=True))
            #print('select  |%s|' % ''.join(map(str, cp_sel)))
            #print('        |%s|' % ('-'*WI))
            #print('muxed   |%s|' % safe_chr(cp_data, oneline=True))
            #print('rol amt |%s|' % ''.join(map(str, [rol_sel[byte] & (WI-1) for byte in range(WI)])))
            #print('index   |%s|' % ''.join(map(str, [(rol_sel[byte] + byte) & (WI-1) for byte in range(WI)])))
            #print('        |%s|' % ''.join(map(lambda x: 'v' if x else ' ', mux_sel)))
            #print('mux out |%s|' % safe_chr(mux_data, oneline=True))
            #print('        |%s|' % ''.join(map(lambda x: ' ' if x else '^', mux_sel)))
            #print('index   |%s|' % ''.join(map(str, [(rol_sel[byte] + byte) & (WI-1) for byte in range(WI)])))
            #print('rol amt |%s|' % ''.join(map(str, [rol_sel[byte] & (WI-1) for byte in range(WI)])))
            #print('lookahd |%s|' % ''.join(map(str, map(int, li_la))))
            #print('literal |%s|' % safe_chr(li_data, oneline=True))

        #print()
        #print('mux out |%s|' % safe_chr(mux_data, oneline=True))
        #print('oh_data |%s|' % safe_chr(oh_data, oneline=True))
        #print('oh_valid|%s|' % ''.join(map(str, map(int, oh_valid))))

        # Update the holding register and short-term memory.
        for byte in range(WI):
            if not oh_valid[byte] and byte < cm.li_end:
                oh_data[byte] = mux_data[byte]
                oh_valid[byte] = True
                st[byte].push(mux_data[byte])

        #print('oh_data |%s|' % safe_chr(oh_data, oneline=True))
        #print('oh_valid|%s|' % ''.join(map(str, map(int, oh_valid))))

        # Handle finished lines.
        if cm.li_end >= WI or cm.last:
            data = tuple(oh_data)

            # Write to long-term.
            if cm.li_end:
                lt[wr_ptr] = data
                wr_ptr += 1

            # Write to output stream.
            if cm.last:
                yield DecompressedStream(data, cm.li_end <= WI, min(WI, cm.li_end))
            else:
                #cnt = cm.li_end if cm.last else WI
                yield DecompressedStream(data, False, WI)

            # Invalidate output holding registers.
            for byte in range(WI):
                oh_valid[byte] = False

            # Reset state if this was the last line.
            if cm.last:
                wr_ptr = 0

        # Update the holding register and short-term memory for the next cycle.
        for byte in range(WI-1):
            if (byte + WI) < cm.li_end:
                oh_data[byte] = mux_data[byte]
                oh_valid[byte] = True
                st[byte].push(mux_data[byte])

        if cm.last and cm.li_end > WI:
            yield DecompressedStream(tuple(oh_data), True, cm.li_end - WI)
            for byte in range(WI):
                oh_valid[byte] = False


def verifier(data_stream, expected):
    """Verifies the given decompressed output stream against the given list
    of expected data chunks. Chunks should be represented as bytes objects."""
    for chunk in expected:
        idx = 0
        for transfer in data_stream:
            expected = chunk[idx:idx+WI]
            actual = bytes(transfer.data[:transfer.cnt])
            if actual != expected:
                raise ValueError('data mismatch, expected |%s| but got |%s|' % (
                    safe_chr(expected, oneline=True), safe_chr(actual, oneline=True)))
            idx += transfer.cnt
            if transfer.last:
                break
            yield transfer
        if idx < len(chunk):
            raise ValueError('missing data in chunk: |%s|' % safe_chr(chunk[idx:], oneline=True))
        if idx > len(chunk):
            raise ValueError('spurious data in chunk')
        yield transfer
    next(data_stream)
    raise ValueError('spurious chunk')


def printer(stream):
    """Prints the debug representation of each transfer to stdout."""
    for transfer in stream:
        print(transfer)
        yield transfer


def writer(stream, fname):
    """Writes the serialized representation of each transfer to the given
    file."""
    with open(fname, 'w') as fil:
        for transfer in stream:
            print(transfer.serialize(), file=fil)
            yield transfer


class Counter():
    """Counts the elements passing through a stream."""

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


def drain(generator):
    """Drains a generator to /dev/null."""
    for _ in generator:
        pass
