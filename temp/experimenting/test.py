
with open('compressed2.raw', 'rb') as f:
    co_data = f.read()

with open('decompressed2.raw', 'rb') as f:
    de_data_exp = f.read()

print('compressed size: %d' % len(co_data))

# strip/parse the uncompressed size
i = 0
de_size = co_data[0] & 0x7F
while co_data[i] & 0x80:
    i += 1
    de_size = (co_data[i] & 0x7F) << (7 * i)
i += 1
print('decompressed size: %d' % de_size)

def get_element_info(co_data, i):
    element_type = co_data[i] & 3
    #print('type %d' % element_type)
    if element_type == 0:
        size_marker_6b = co_data[i] >> 2
        size_source = size_marker_6b
        el_hdr_size = 1
        if size_marker_6b >= 60:
            size_source = co_data[i+1]
            el_hdr_size += 1
        if size_marker_6b >= 61:
            size_source |= co_data[i+2] << 8
            el_hdr_size += 1
        if size_marker_6b >= 62:
            size_source |= co_data[i+3] << 16
            el_hdr_size += 1
        if size_marker_6b >= 63:
            size_source |= co_data[i+4] << 24
            el_hdr_size += 1
        el_de_size = size_source + 1
        el_co_size = el_de_size + el_hdr_size
        el_cp_size = None
        el_cp_offs = None
    elif element_type == 1:
        el_co_size = 2
        el_hdr_size = 2
        el_cp_size = ((co_data[i] >> 2) & 7) + 4
        el_de_size = el_cp_size
        el_cp_offs = ((co_data[i] >> 5) << 8) | co_data[i+1]
    elif element_type == 2:
        el_co_size = 3
        el_hdr_size = 3
        el_cp_size = (co_data[i] >> 2) + 1
        el_de_size = el_cp_size
        el_cp_offs = co_data[i+1] | (co_data[i+2] << 8)
    else:
        el_co_size = 5
        el_hdr_size = 5
        el_cp_size = (co_data[i] >> 2) + 1
        el_de_size = el_cp_size
        el_cp_offs = co_data[i+1] | (co_data[i+2] << 8) | (co_data[i+3] << 16) | (co_data[i+4] << 24)
    return el_co_size, el_hdr_size, el_de_size, el_cp_size, el_cp_offs

de_data = []
de_size_so_far = 0

def de_byte(b):
    #print('byte 0x%02X' % b)
    if de_data_exp[len(de_data)] != b:
        raise ValueError('%02X != %02X!' % (b, de_data_exp[len(de_data)]))

    de_data.append(b)


header_sizes = []
copy_sizes = []
rle_counts = []

copies_between_lits = []
copies = 0

while i < len(co_data):
    el_co_size, el_hdr_size, el_de_size, el_cp_size, el_cp_offs = get_element_info(co_data, i)
    #print(i, el_co_size, el_hdr_size, el_de_size, el_cp_size, el_cp_offs)
    header_sizes.append(el_hdr_size)
    copied = 0
    for b in co_data[i+el_hdr_size:i+el_co_size]:
        copied += 1
        de_byte(b)
    if copied:
        copy_sizes.append(copied)
    if el_cp_size is not None:
        assert el_cp_offs <= len(de_data)
        assert el_cp_offs >= 1
        offs = el_cp_offs
        copied = 0
        num_rle = 0
        for _ in range(el_cp_size):
            #print(offs)
            de_byte(de_data[de_size_so_far-offs])
            copied += 1
            offs -= 1
            if not offs:
                offs = el_cp_offs
                copy_sizes.append(copied)
                num_rle += 1
                copied = 0
        if copied:
            copy_sizes.append(copied)
        if num_rle:
            rle_counts.append(num_rle)
        copies += 1
    else:
        if copies:
            copies_between_lits.append(copies)
        copies = 0
    i += el_co_size
    de_size_so_far += el_de_size
    assert len(de_data) == de_size_so_far

if copies:
    copies_between_lits.append(copies)
de_data = bytes(de_data)

assert de_data == de_data_exp

print('header sizes: min', min(header_sizes), 'max', max(header_sizes), 'avg', sum(header_sizes) / len(header_sizes))
print('copy sizes: min', min(copy_sizes), 'max', max(copy_sizes), 'avg', sum(copy_sizes) / len(copy_sizes))

def hist(values):
    h = {}
    for value in values:
        if value in h:
            h[value] += 1
        else:
            h[value] = 1
    import pprint
    pprint.pprint(h)

hist(copy_sizes)

print('restarts: num', len(rle_counts), 'min', min(rle_counts), 'max', max(rle_counts), 'avg', sum(rle_counts) / len(rle_counts))
hist(rle_counts)

print('copies between lits: num', len(copies_between_lits), 'min', min(copies_between_lits), 'max', max(copies_between_lits), 'avg', sum(copies_between_lits) / len(copies_between_lits))
hist(copies_between_lits)
