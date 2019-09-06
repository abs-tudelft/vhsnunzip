from collections import namedtuple

def safe_chr(vals, oneline=False):
    """Print a byte or iterable of bytes as ASCII, using ANSI color codes to
    represent non-printables."""
    if not hasattr(vals, '__iter__'):
        vals = [vals]
    s = []
    for val in vals:
        if val == ord('\n'):
            if oneline:
                s.append('\033[32mn\033[0m')
            else:
                s.append(chr(val))
        elif val == ord('\r'):
            s.append('\033[32mr\033[0m')
        elif val == ord('\t'):
            s.append('\033[32mt\033[0m')
        elif val >= 32 and val <= 126:
            s.append(chr(val))
        else:
            s.append('\033[31m?\033[0m')
    return ''.join(s)

# Pipeline width, must be 8 or 16.
WI = 8

CompressedStream = namedtuple('CompressedStream', [
    'data',     # chunk data (WI bytes)
    'first',    # indicator for first line in chunk
    'start',    # first valid byte index if first is set
    'last',     # indicator for last line in chunk
    'end',      # last valid byte index if last is set
])

def compressed_stream(chunk):
    """Yields CompressedStream items based on the given chunk. Chain multiple
    to get multiple chunks."""
    for offs in range(0, len(chunk), WI):
        data = list(chunk[offs:offs+WI])
        first = not offs
        if first:
            start = 0
            while data[start] & 0x80:
                start += 1
            start += 1
        else:
            start = 0
        last = offs + WI >= len(chunk)
        end = len(data) - 1
        data += [0] * (WI - len(data))
        data = tuple(data)
        yield CompressedStream(data, first, start, last, end)

def parallelized_stream(compressed):
    """Makes the data in the CompressedStream twice as wide by looking ahead
    one transfer."""
    compressed = iter(compressed)
    prev = None
    for cur in compressed:
        if prev is not None:
            yield CompressedStream(prev.data + cur.data, prev.first, prev.start, prev.last, prev.end)
        if cur.last:
            yield CompressedStream(cur.data + (0,)*len(cur.data), cur.first, cur.start, cur.last, cur.end)
            prev = None
        prev = cur

_ElementStream = namedtuple('ElementStream', [
    'cp_valid', # whether the copy element info is valid
    'cp_offs',  # the byte offset for the copy as encoded by the element header
    'cp_len',   # the length of the copy as encoded by the element header
    'li_valid', # whether the literal element info is valid
    'li_offs',  # the starting byte offset within the current li_data for the literal
    'li_len',   # the length of the literal as encoded by the element header
    'li_data',  # literal data (2*WI bytes)
    'first',    # indicator for first set of elements in chunk
    'last',     # indicator for last set of elements/literal data in chunk
])

class ElementStream(_ElementStream):
    def __repr__(self):
        return 'Element(copy=%d(o=%4d, l=%2d), lit=%d(o=%2d, l=%2d), data=|%s|, f=%d, l=%d)' % (
            self.cp_valid, self.cp_offs, self.cp_len,
            self.li_valid, self.li_offs, self.li_len,
            safe_chr(self.li_data, oneline=True),
            self.first, self.last)

def element_stream(parallelized):

    co_offs = 0
    co_valid = False

    parallelized = iter(parallelized)

    while True:

        # pull in a new half-line from the compressed stream when we need it
        first = False
        if not co_valid:
            el = next(parallelized)
            co_valid = True
            li_data = data = el.data
            if el.first:
                co_offs = el.start
                first = True

        # Handle copy element.
        co_offs_mod = co_offs & (WI-1)
        if co_offs >= WI or data[co_offs_mod] & 3 == 0:
            cp_valid = False
            cp_offs = 0
            cp_len = 0
        elif data[co_offs_mod] & 3 == 1:
            cp_valid = True
            cp_offs = (((data[co_offs_mod] >> 5) & 7) << 8) | data[co_offs_mod+1]
            cp_len = ((data[co_offs_mod] >> 2) & 7) + 4
            co_offs += 2
        elif data[co_offs_mod] & 3 == 2:
            cp_valid = True
            cp_offs = data[co_offs_mod+1] | (data[co_offs_mod+2] << 8)
            cp_len = ((data[co_offs_mod] >> 2) & 63) + 1
            co_offs += 3
        elif data[co_offs_mod] & 3 == 3:
            raise ValueError('oh_snap')

        # Handle literal header.
        co_offs_mod = co_offs & (WI-1)
        li_valid = co_offs <= el.end and data[co_offs_mod] & 3 == 0
        li_len = data[co_offs_mod] >> 2
        if li_len == 60:
            li_len = data[co_offs_mod+1]
            li_hdlen = 2
        elif li_len == 61:
            li_len = (data[co_offs_mod+2] << 8) | data[co_offs_mod+1]
            li_hdlen = 3
        elif li_len > 61:
            li_hdlen = 1
            if li_valid:
                raise ValueError('oh_snap')
        else:
            li_hdlen = 1
        li_len += 1
        li_offs = co_offs + li_hdlen

        if li_valid:
            co_offs += li_hdlen + li_len

        # Check if we need to pull in new data in the next cycle and preadjust
        # the offset accordingly.
        last = False
        if co_offs > el.end:
            co_offs -= WI
            co_valid = False
            last = el.last

        yield ElementStream(
            cp_valid, cp_offs, cp_len,
            li_valid, li_offs, li_len, li_data,
            first, last)

def test_element_stream(elements, golden):
    with open(golden, 'rb') as f:
        golden = list(reversed(f.read()))
    golden_idx = 0
    decompressed = []
    def push(b):
        #print(chr(b), end='')
        decompressed.append(b)
        assert golden.pop() == b
    li_remain = 0
    for el in elements:
        if li_remain:
            for i in range(WI, WI*2):
                if not li_remain:
                    break
                push(el.li_data[i])
                li_remain -= 1
        if el.cp_valid:
            for i in range(el.cp_len):
                push(decompressed[-el.cp_offs])
        if el.li_valid:
            li_remain = el.li_len
            for i in range(el.li_offs, WI*2):
                if not li_remain:
                    break
                push(el.li_data[i])
                li_remain -= 1
        if el.last:
            #print(''.join(map(safe_chr, decompressed)), end='')
            decompressed.clear()
            li_remain = 0

_CommandStream = namedtuple('CommandStream', [
    'cp_long',  # whether long-term history should be read
    'cp_src',   # *relative* first line index for history read (positive = further back; -1 = line we're currently writing); two lines should be read
    'cp_rol',   # rotation for copy; the two lines are rotated left by this number of bytes
    'cp_rle',   # cp_rol is a byte index instead of a rotation, for run-length encoding acceleration
    'li_data',  # literal data, two lines
    'li_rol',   # rotation for literal; the two lines are rotated left by this number of bytes
    'strb',     # byte write strobe signals for two lines; at most one (misaligned) line is written at a time
    'src',      # byte source signals; 0 for literal, 1 for copy
    'last',     # last transfer for this chunk
])

class CommandStream(_CommandStream):
    def __repr__(self):
        ss = ''
        for i in range(WI*2):
            if i == WI:
                ss += '|'
            if not self.strb[i]:
                ss += ' '
            elif self.src[i % WI]:
                ss += 'C'
            else:
                ss += 'L'
        return 'Command(cp(long=%d, s=%3d, r=%2d, rle=%d), li=(data=|%s|, r=%2d), ss=|%s|, l=%d)' % (
            self.cp_long, self.cp_src, self.cp_rol, self.cp_rle,
            safe_chr(self.li_data, oneline=True), self.li_rol,
            ss, self.last)


def command_stream(elements):

    elements = iter(elements)

    de_offs = 0
    el_valid = False

    cp_pend = False
    cp_len = 0
    cp_offs = 0

    li_pend = False
    li_len = 0
    li_offs = 0

    while True:

        # Load next element pair if we need more data.
        if not el_valid:
            el = next(elements)
            #print(el)
            el_valid = True
            if el.first:
                de_offs = 0
            cp_pend = el.cp_valid
            li_pend = el.li_valid

        # Load defaults for our output.
        cp_long = False
        cp_src = 0
        cp_rol = 0
        li_data = el.li_data
        li_rol = 0
        strb = [False] * WI*2
        src = [0] * WI

        # If we're out of stuff to do, load the next commands.
        if not cp_len and not li_len:
            if cp_pend:
                cp_len = el.cp_len
                cp_offs = el.cp_offs
                cp_pend = False
            if li_pend:
                li_len = el.li_len
                li_offs = el.li_offs
                li_pend = False

        # Amount of bytes we can write in this cycle.
        #budget = WI - de_offs
        budget = WI

        # Handle copy data.
        if cp_offs == 1:

            # Special case for single-byte repetition, since it's relatively
            # common and otherwise has worst-case 1-byte/cycle performance.
            # Requires some extra logic in the address/rotation decoders
            # though; cp_rol becomes an index rather than a rotation when
            # cp_rle is set. Can be disabled by just not taking this branch.
            cp_chunk_len = min(cp_len, budget)
            cp_chunk_src_byte = de_offs - cp_offs
            cp_chunk_src_line = cp_chunk_src_byte // WI
            cp_chunk_src_offs = cp_chunk_src_byte % WI

            cp_rle = True
            cp_src = -1 - cp_chunk_src_line
            cp_long = cp_src > 28 # TODO this number is a bit fuzzy, should probably prove that it always works
            cp_rol = cp_chunk_src_offs
            for i in range(cp_chunk_len):
                strb[de_offs + i] = True
                src[(de_offs + i) % WI] = 1

        else:
            cp_chunk_len = min(cp_len, cp_offs, budget)
            cp_chunk_src_byte = de_offs - cp_offs
            cp_chunk_src_line = cp_chunk_src_byte // WI
            cp_chunk_src_offs = cp_chunk_src_byte % WI

            cp_rle = False
            cp_src = -1 - cp_chunk_src_line
            cp_long = cp_src > 28 # TODO this number is a bit fuzzy, should probably prove that it always works
            cp_rol = (cp_chunk_src_offs - de_offs) & (WI*2-1)
            for i in range(cp_chunk_len):
                strb[de_offs + i] = True
                src[(de_offs + i) % WI] = 1

        # Update state for copy.
        de_offs += cp_chunk_len
        cp_len -= cp_chunk_len
        budget -= cp_chunk_len

        # Handle literal data.
        if not cp_len:
            li_chunk_len = min(li_len, WI*2 - li_offs, budget)
        else:
            li_chunk_len = 0

        li_rol = (li_offs - de_offs) & (WI*2-1)
        for i in range(li_chunk_len):
            strb[de_offs + i] = True

        # Update state for literal.
        de_offs += li_chunk_len
        li_offs += li_chunk_len
        li_len -= li_chunk_len

        # Wrap the destination offset. Up to this point we need a bit extra!
        de_offs &= WI - 1

        # Determine whether we still need more literal data from this element.
        ld_pend = li_len and li_offs < WI

        # Invalidate the element record when we have no more need for it, so
        # the next record can be loaded.
        last = False
        if el_valid and not (cp_pend or li_pend or ld_pend):
            el_valid = False
            last = el.last
            li_offs -= WI

        yield CommandStream(
            cp_long, cp_src, cp_rol, cp_rle,
            li_data, li_rol,
            strb, src, last)

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


def test_command_stream(cmds, golden):

    with open(golden, 'rb') as f:
        golden = list(f.read())
    golden_idx = 0

    #print(safe_chr(golden[:30], oneline=True))

    lt = [SRL(65536) for _ in range(WI)]
    st = [SRL(32) for _ in range(WI)]
    st_delta = [0] * WI
    oh_data = [0] * WI
    next_oh_data = [0] * WI
    next_oh_strb = [False] * WI
    next_muxsrc = ['???'] * WI
    push_strb = [False] * WI
    push_srcs = ['???'] * WI
    mux_data = ['???'] * WI
    mux_srcs = ['???'] * WI

    for cmd in cmds:
        #print(cmd)

        for di in range(WI):
            rol = cmd.li_rol if cmd.src[di] == 0 else cmd.cp_rol
            if cmd.cp_rle and cmd.src[di] == 1:
                si = rol
            else:
                if cmd.strb[di+WI]:
                    rol ^= WI
                si = di + rol


            si &= WI*2 - 1

            #print(si)

            if cmd.src[di] == 0:
                mux = cmd.li_data[si]
                muxsrc = 'li_data[%d]' % si
            else:
                sl = cmd.cp_src
                if si & WI:
                    sl -= 1
                    si -= WI
                if cmd.cp_long:
                    mux = lt[si][sl]
                    muxsrc = 'lt[%d][%d]' % (si, sl)
                else:
                    mux = st[si][sl + st_delta[si]]
                    muxsrc = 'st[%d][%d]' % (si, sl + st_delta[si])

            push = None
            pushsrc = '???'

            if next_oh_strb[di]:
                push = next_oh_data[di]
                pushsrc = 'prev[%d] = %s' % (di, next_muxsrc[di])
                next_oh_strb[di] = False
                assert not cmd.strb[di]

            if cmd.strb[di]:
                push = mux
                pushsrc = 'mux = %s' % muxsrc

            if push is not None:
                oh_data[di] = push
                push_strb[di] = True
                push_srcs[di] = pushsrc
            else:
                push_strb[di] = False

            next_oh_data[di] = mux
            next_oh_strb[di] = cmd.strb[di+WI]
            next_muxsrc[di] = muxsrc

            mux_data[di] = mux
            mux_srcs[di] = muxsrc

        for di in range(WI):

            if push_strb[di]:
                push = oh_data[di]
                pushsrc = push_srcs[di]

                if golden[golden_idx] != push:
                    print('expected %d = \'%s\', got %d = \'%s\' from %s' % (
                        golden[golden_idx], safe_chr(golden[golden_idx], oneline=True),
                        push, safe_chr(push, oneline=True),
                        pushsrc))
                    print('deltas', st_delta)
                assert golden[golden_idx] == push
                golden_idx += 1


            if cmd.strb[di] or cmd.strb[di + WI]:
                push = mux_data[di]
                pushsrc = mux_srcs[di]

                #print('push st[%d] = %d = %s' % (di, push, pushsrc))
                st[di].push(push)
                st_delta[di] += 1


        for di in range(WI):
            push = oh_data[di]
            pushsrc = push_srcs[di]

            if cmd.strb[WI-1]:
                #print('push lt[%d] = %d = %s' % (di, push, pushsrc))
                lt[di].push(push)
                st_delta[di] -= 1



#CommandStream = namedtuple('CommandStream', [
    #'cp_long',   # whether long-term history should be read
    #'cp_src',   # *relative* first line index for history read (positive = further back; -1 = line we're currently writing); two lines should be read
    #'cp_rol',   # rotation for copy; the two lines are rotated left by this number of bytes
    #'li_data',  # literal data, two lines
    #'li_rol',   # rotation for literal; the two lines are rotated left by this number of bytes
    #'strb',     # byte write strobe signals for two lines; at most one (misaligned) line is written at a time
    #'src',      # byte source signals; 0 for literal, 1 for copy
    #'last',     # last transfer for this chunk
#])


#ElementStream = namedtuple('ElementStream', [
    #'cp_valid', # whether the copy element data is valid
    #'cp_offs',  # the byte offset for the copy as encoded by the element
    #'cp_len',   # the length of the copy as encoded by the element
    #'li_data',  # literal data (2*WI bytes)
    #'li_rol',   # rotate left amount for literal data
    #'li_strb',  # byte strobe for literal data (relative to decompressed line)
    #'first',    # indicator for first set of elements in chunk
    #'last',     # indicator for last set of elements/literal data in chunk
#])

#def element_stream(parallelized):

    #co_offs = 0
    #co_valid = False
    #de_offs = 0
    #li_remain = 0

    #parallelized = iter(parallelized)

    #while True:

        ## pull in a new half-line from the compressed stream when we need it
        #first = False
        #if not co_valid:
            #prev, cur = next(parallelized)
            #co_valid = True
            #li_data = data = prev.data + cur.data
            #if prev.first:
                #co_offs = prev.start
                #first = True

        ## handle copy element
        #if li_remain or data[co_offs] & 3 == 0:
            #cp_valid = False
            #cp_offs = 0
            #cp_len = 0
        #elif data[co_offs] & 3 == 1:
            #cp_valid = True
            #cp_offs = (((data[co_offs] >> 5) & 7) << 8) | data[co_offs+1]
            #cp_len = ((data[co_offs] >> 2) & 7) + 4
            #co_offs += 2
        #elif data[co_offs] & 3 == 2:
            #cp_valid = True
            #cp_offs = data[co_offs+1] | (data[co_offs+2] << 8)
            #cp_len = ((data[co_offs] >> 2) & 63) + 1
            #co_offs += 3
        #elif data[co_offs] & 3 == 3:
            ## 5-byte copy (not supported)
            #raise ValueError('oh_snap')

        ## update decompressed offset for copy
        #de_offs += cp_len
        #de_offs &= WI - 1

        ## handle literal header
        #li_valid = not li_remain and co_offs <= prev.end and data[co_offs] & 3 == 0
        #li_dest = de_offs
        #li_len = data[co_offs] >> 2
        #if li_len == 60:
            #li_len = data[co_offs+1]
            #li_hdlen = 2
        #elif li_len == 61:
            #li_len = (data[co_offs+2] << 8) | data[co_offs+1]
            #li_hdlen = 3
        #elif li_len > 61:
            #if li_valid:
                #raise ValueError('oh_snap')
        #else:
            #li_hdlen = 1
        #li_len += 1

        #if li_valid:
            #print('lit el', li_len)
            #li_remain = li_len
            #co_offs += li_hdlen

        ## handle literal data
        ## TODO: some of this should probably move to the next cycle.
        #li_chunk_len = min(li_remain, WI - de_offs, WI*2 - co_offs)
        #if li_chunk_len:
            #print('lit chnk', safe_chr(li_data, oneline=True), co_offs, li_chunk_len)
        #li_rol = (co_offs - de_offs) & (WI*2-1)
        #li_strb = [False] * WI
        #for i in range(li_chunk_len):
            #li_strb[de_offs + i] = True
        #li_remain -= li_chunk_len

        ## update decompressed offset for literal
        #de_offs += li_chunk_len
        #de_offs &= WI - 1

        ## update compressed offset for literal data and check overflow
        #last = False
        #co_offs += li_chunk_len
        #if co_offs > prev.end:
            #co_offs -= WI
            #co_valid = False
            #last = prev.last

        ## reset state if invalidating last
        #if last:
            #de_offs = 0
            #li_remain = 0

        #yield ElementStream(
            #cp_valid, cp_offs, cp_len,
            #li_data, li_rol, li_strb,
            #first, last)

#def test_element_stream(element_stream, golden):
    #with open(golden, 'rb') as f:
        #golden = list(reversed(f.read()))
    #golden_idx = 0
    #decompressed = []
    #def push(b):
        ##print(chr(b), end='')
        #decompressed.append(b)
        #assert golden.pop() == b
    #for el in element_stream:
        #if el.cp_valid:
            #for i in range(el.cp_len):
                #push(decompressed[-el.cp_offs])
        #for i, strb in enumerate(el.li_strb):
            #if strb:
                #push(el.li_data[(i + el.li_rol) % (WI*2)])
        #if el.last:
            #print(''.join(map(safe_chr, decompressed)), end='')
            #decompressed.clear()

#CommandStream = namedtuple('CommandStream', [
    #'cp_long',   # whether long-term history should be read
    #'cp_src',   # *relative* first line index for history read (negative; 0 = current line); two lines should be read
    #'cp_rol',   # rotation for copy; the two lines are rotated left by this number of bytes
    #'li_data',  # literal data, two lines
    #'li_rol',   # rotation for literal; the two lines are rotated left by this number of bytes
    #'strobe',   # byte write strobe signals
    #'source',   # byte source signals; 0 for literal, 1 for copy
    #'last'])    # last transfer for this chunk

#def command_stream(compressed):

    #def parallelizer(compressed):
        #dummy = CompressedStream((0,) * WI, False, 0, False, 0)
        #compressed = iter(compressed)
        #prev = None
        #for cur in compressed:
            #if prev is not None:
                #yield prev, cur
            #if cur.last:
                #yield cur, dummy
                #prev = None
            #prev = cur

    #co_offs = None # should always be overridden in first transfer
    #de_offs = None

    #for prev, cur in parallelizer(compressed):
        #cp_long = False
        #cp_src = 0
        #cp_rol = 0
        #li_data = data = prev.data + cur.data
        #li_rol = 0
        #strobe = [False] * WI
        #source = [0] * WI
        #cmd_pend = False

        #if prev.first:
            #co_offs = prev.start
            #de_offs = 0
        #assert co_offs is not None and de_offs is not None

        #while co_offs <= prev.end:

            ## decode copy element
            #if data[co_offs] & 3 == 0:
                ## not a copy
                #cp_valid = False
                #cp_offs = 0
                #cp_len = 0

            #if data[co_offs] & 3 == 1:
                ## 2-byte copy
                #cp_valid = True
                #cp_offs = (((data[co_offs] >> 5) & 7) << 8) | data[co_offs+1]
                #cp_len = ((data[co_offs] >> 2) & 7) + 4
                #co_offs += 2

            #elif data[co_offs] & 3 == 2:
                ## 3-byte copy
                #cp_valid = True
                #cp_offs = (data[co_offs+2] << 8) | data[co_offs+1]
                #cp_len = ((data[co_offs] >> 2) & 63) + 1
                #co_offs += 3

            #elif data[co_offs] & 3 == 3:
                ## unsupported copy
                #raise ValueError('oh_snap')

            #while cp_len:
                #cp_chunk_len = min(cp_len, WI - de_offs, cp_offs)
                #cp_chunk_src = de_offs - cp_offs
                #cp_chunk_src_line = cp_chunk_src & ~(WI-1)
                #cp_chunk_src_offs = cp_chunk_src & (WI-1)
                #cp_chunk_dest_offs = de_offs
                #cp_chunk_rotate = cp_chunk_src_offs - cp_chunk_dest_offs
                #cp_chunk_rotate &= ((2*WI)-1)

                #if cmd_pend:
                    #yield CommandStream(cp_long, cp_src, cp_rol, li_data, li_rol, strobe, source, False)
                    #cmd_pend = False

                #cp_long = cp_chunk_src_line < -30
                #cp_src = cp_chunk_src_line
                #cp_rol = cp_chunk_rotate
                #for i in range(cp_chunk_len):
                    #source[de_offs] = 1
                    #strobe[de_offs] = True
                    #de_offs += 1
                #cmd_pend = True

                #cp_len -= cp_chunk_len
                #de_offs &= (WI-1)

            #if prev.last and co_offs >= prev.end and cmd_pend:
                #yield CommandStream(cp_long, cp_src, cp_rol, li_data, li_rol, strobe, source, False)
                #cmd_pend = False
                #break

            ## decode literal element
            #if data[co_offs] & 3 == 0:
                ## literal
                #li_valid = True
                #li_dest = de_offs
                #li_len = data[co_offs] >> 2
                #if li_len == 60:
                    #li_len = data[co_offs+1]
                    #co_offs += 2
                #elif li_len == 61:
                    #li_len = (data[co_offs+2] << 8) | data[co_offs+1]
                    #co_offs += 3
                #elif li_len > 61:
                    #raise ValueError('oh_snap')
                #else:
                    #co_offs += 1
                #li_len += 1
                #li_src = co_offs

            #else:
                ## not a literal
                #li_valid = False
                #li_dest = 0
                #li_src = 0
                #li_len = 0

            #while li_len:
                #li_chunk_len = min(li_len, WI - de_offs)


                #co_offs += li_chunk_len
                #if co_offs >= WI:
                    #co_offs -= WI

                #cp_chunk_src = de_offs - cp_offs
                #cp_chunk_src_line = cp_chunk_src & ~(WI-1)
                #cp_chunk_src_offs = cp_chunk_src & (WI-1)
                #cp_chunk_dest_offs = de_offs
                #cp_chunk_rotate = cp_chunk_src_offs - cp_chunk_dest_offs
                #cp_chunk_rotate &= ((2*WI)-1)

                #if cmd_pend:
                    #yield CommandStream(cp_long, cp_src, cp_rol, li_data, li_rol, strobe, source, False)
                    #cmd_pend = False

                #cp_long = cp_chunk_src_line < -30
                #cp_src = cp_chunk_src_line
                #cp_rol = cp_chunk_rotate
                #for i in range(cp_chunk_len):
                    #source[de_offs] = 1
                    #strobe[de_offs] = True
                    #de_offs += 1
                #cmd_pend = True

                #cp_len -= cp_chunk_len
                #de_offs &= (WI-1)



        #prev = cur

import os
import itertools

for fname in os.listdir('.'):
    if fname.startswith('bench-') and fname.endswith('.raw'):

        print('***', fname)

        with open(fname, 'rb') as fil:
            data = fil.read()

        compressed = list(compressed_stream(data))
        parallelized = list(parallelized_stream(compressed))

        print('checking...')
        es = element_stream(parallelized)
        #test_element_stream(es, fname[:-4] + '.bin')
        test_command_stream(command_stream(es), fname[:-4] + '.bin')
        print('\033[Achecking... correct!')

        print('calc performance...')
        es = element_stream(parallelized)
        count = accum = 0
        decomp_writes = 0
        long_term_reads = 0
        for cmd in command_stream(es):
            count += 1
            accum += sum(cmd.strb)
            decomp_writes += cmd.strb[WI-1]
            long_term_reads += cmd.cp_long
        print('\033[Aavg bytes/cycle =', accum / count)
        print('comp reads =', len(compressed))
        print('decomp writes =', count)
        print('long term reads =', long_term_reads)
        print()



#.


# Memory ports:
#   A0: even lines    A1: odd lines
#   B0: even lines    B1: odd lines
#
# Access priorities during decompression                Ports
#   1) long term memory read                            A
#   2) decompressed data/long term memory write          B
#   4) compressed data read                             A
#   3) output stream read                               AB
#
# Access priorities during buffering                    Ports
#   1) input stream write                               AB
#   2) compressed data read                             A
#
# long term read needs an even AND an odd line
# comp read needs an even OR an odd line
# decomp write needs an even OR an odd line

#for element in element_stream(parallelized_stream(compressed_stream(data))):
    #pass#print(element)
