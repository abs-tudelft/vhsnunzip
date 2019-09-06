def safe_chr(vals, oneline=False):
    if not hasattr(vals, '__iter__'):
        vals = [vals]
    s = []
    for val in vals:
        if val == ord('\n') and oneline:
            s.append('\033[32mn\033[0m')
        elif val == ord('\r') and oneline:
            s.append('\033[32mr\033[0m')
        elif val == ord('\t') and oneline:
            s.append('\033[32mt\033[0m')
        elif chr(val) in '\t\n\r' or (val >= 32 and val <= 127):
            s.append(chr(val))
        else:
            s.append('\033[31m?\033[0m')
    return ''.join(s)


from collections import namedtuple

WI = 8

CompressedStream = namedtuple('CompressedStream', [
    'data',     # chunk data (WI bytes)
    'first',    # indicator for first line in chunk
    'start',    # first valid byte index if first is set
    'last',     # indicator for last line in chunk
    'end',      # last valid byte index if last is set
])

def compressed_stream(chunk):
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
    dummy = CompressedStream((0,) * WI, False, 0, False, 0)
    compressed = iter(compressed)
    prev = None
    for cur in compressed:
        if prev is not None:
            yield prev, cur
        if cur.last:
            yield cur, dummy
            prev = None
        prev = cur

ElementStream = namedtuple('ElementStream', [
    'cp_valid', # whether the copy element data is valid
    'cp_offs',  # the byte offset for the copy as encoded by the element
    'cp_len',   # the length of the copy as encoded by the element
    'li_data',  # literal data (2*WI bytes)
    'li_rol',   # rotate left amount for literal data
    'li_strb',  # byte strobe for literal data (relative to decompressed line)
    'first',    # indicator for first set of elements in chunk
    'last',     # indicator for last set of elements/literal data in chunk
])

def element_stream(parallelized):

    co_offs = 0
    co_valid = False
    de_offs = 0
    li_remain = 0

    parallelized = iter(parallelized)

    while True:

        # pull in a new half-line from the compressed stream when we need it
        first = False
        if not co_valid:
            prev, cur = next(parallelized)
            co_valid = True
            li_data = data = prev.data + cur.data
            if prev.first:
                co_offs = prev.start
                first = True

        # handle copy element
        if li_remain or data[co_offs] & 3 == 0:
            cp_valid = False
            cp_offs = 0
            cp_len = 0
        elif data[co_offs] & 3 == 1:
            cp_valid = True
            cp_offs = (((data[co_offs] >> 5) & 7) << 8) | data[co_offs+1]
            cp_len = ((data[co_offs] >> 2) & 7) + 4
            co_offs += 2
        elif data[co_offs] & 3 == 2:
            cp_valid = True
            cp_offs = data[co_offs+1] | (data[co_offs+2] << 8)
            cp_len = ((data[co_offs] >> 2) & 63) + 1
            co_offs += 3
        elif data[co_offs] & 3 == 3:
            # 5-byte copy (not supported)
            raise ValueError('oh_snap')

        # update decompressed offset for copy
        de_offs += cp_len
        de_offs &= WI - 1

        # handle literal header
        li_valid = not li_remain and co_offs <= prev.end and data[co_offs] & 3 == 0
        li_dest = de_offs
        li_len = data[co_offs] >> 2
        if li_len == 60:
            li_len = data[co_offs+1]
            li_hdlen = 2
        elif li_len == 61:
            li_len = (data[co_offs+2] << 8) | data[co_offs+1]
            li_hdlen = 3
        elif li_len > 61:
            if li_valid:
                raise ValueError('oh_snap')
        else:
            li_hdlen = 1
        li_len += 1

        if li_valid:
            print('lit el', li_len)
            li_remain = li_len
            co_offs += li_hdlen

        # handle literal data
        # TODO: some of this should probably move to the next cycle.
        li_chunk_len = min(li_remain, WI - de_offs, WI*2 - co_offs)
        if li_chunk_len:
            print('lit chnk', safe_chr(li_data, oneline=True), co_offs, li_chunk_len)
        li_rol = (co_offs - de_offs) & (WI*2-1)
        li_strb = [False] * WI
        for i in range(li_chunk_len):
            li_strb[de_offs + i] = True
        li_remain -= li_chunk_len

        # update decompressed offset for literal
        de_offs += li_chunk_len
        de_offs &= WI - 1

        # update compressed offset for literal data and check overflow
        last = False
        co_offs += li_chunk_len
        if co_offs > prev.end:
            co_offs -= WI
            co_valid = False
            last = prev.last

        # reset state if invalidating last
        if last:
            de_offs = 0
            li_remain = 0

        yield ElementStream(
            cp_valid, cp_offs, cp_len,
            li_data, li_rol, li_strb,
            first, last)

def test_element_stream(element_stream, golden):
    with open(golden, 'rb') as f:
        golden = list(reversed(f.read()))
    golden_idx = 0
    decompressed = []
    def push(b):
        #print(chr(b), end='')
        decompressed.append(b)
        assert golden.pop() == b
    for el in element_stream:
        if el.cp_valid:
            for i in range(el.cp_len):
                push(decompressed[-el.cp_offs])
        for i, strb in enumerate(el.li_strb):
            if strb:
                push(el.li_data[(i + el.li_rol) % (WI*2)])
        if el.last:
            print(''.join(map(safe_chr, decompressed)), end='')
            decompressed.clear()

#CommandStream = namedtuple('CommandStream', [
    #'cp_ena',   # whether long-term history should be read
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
        #cp_ena = False
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
                    #yield CommandStream(cp_ena, cp_src, cp_rol, li_data, li_rol, strobe, source, False)
                    #cmd_pend = False

                #cp_ena = cp_chunk_src_line < -30
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
                #yield CommandStream(cp_ena, cp_src, cp_rol, li_data, li_rol, strobe, source, False)
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
                    #yield CommandStream(cp_ena, cp_src, cp_rol, li_data, li_rol, strobe, source, False)
                    #cmd_pend = False

                #cp_ena = cp_chunk_src_line < -30
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

with open('compressed2.raw', 'rb') as fil:
    data = fil.read()

test_element_stream(element_stream(parallelized_stream(compressed_stream(data))), 'decompressed2.raw')

#for element in element_stream(parallelized_stream(compressed_stream(data))):
    #pass#print(element)
