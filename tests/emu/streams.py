from collections import namedtuple
from .utils import *

# The VHDL stream operators are emulated using Python generators. When popping
# from the input stream, they just call next() on the previous generator; when
# producing output, they yield the result. Note that this means that the model
# is not cycle accurate; it does not actually have a concept of cycles.

# The stream payloads are modelled as the named tuples below.

# Data width. This is fixed to 8 in the VHDL source, but can be modified to
# other powers of two here. Less than 4 definitely won't work, 4 may work,
# more than 8 should work fine but won't work in hardware with URAMs.
WI = 8
WB = WI.bit_length() - 1

_CompressedStreamSingle = namedtuple('_CompressedStreamSingle', [
    'data',     # chunk data (WI bytes)
    'last',     # indicator for last line in chunk
    'endi',     # last valid byte index if last is set
])

class CompressedStreamSingle(_CompressedStreamSingle):
    def __new__(cls, *args, **kwargs):
        cs = super(CompressedStreamSingle, cls).__new__(cls, *args, **kwargs)
        assert is_byte_array(cs.data, WI)
        assert is_std_logic(cs.last)
        assert is_unsigned(cs.endi, WB)
        assert cs.endi == WI-1 or cs.last
        return cs

    def serialize(self):
        s = []
        for idx, value in enumerate(self.data):
            s.append(binary(value, 8, idx <= self.endi))
        s.append(binary(self.last, 1))
        s.append(binary(self.endi, WB))
        return ''.join(s)

    def __repr__(self):
        return 'CS(|%s%s%s)' % (
            safe_chr(self.data[:self.endi+1], oneline=True),
            '/' * (WI-1-self.endi),
            '>' if self.last else '|')

_CompressedStreamDouble = namedtuple('_CompressedStreamDouble', [
    'data',     # chunk data (WI*2 bytes)
    'first',    # indicator for first line in chunk
    'start',    # first valid byte index if first is set
    'last',     # indicator for last line in chunk
    'endi',     # last valid byte index if last is set
    'py_endi',  # indicates how much of the linepair is actually valid, including lookahead
])

class CompressedStreamDouble(_CompressedStreamDouble):
    def __new__(cls, *args, **kwargs):
        cd = super(CompressedStreamDouble, cls).__new__(cls, *args, **kwargs)
        assert is_byte_array(cd.data, WI*2)
        assert is_std_logic(cd.first)
        assert is_unsigned(cd.start, 2)
        assert is_std_logic(cd.last)
        assert is_unsigned(cd.endi, WB)
        assert cd.endi == WI-1 or cd.last
        return cd

    def serialize(self):
        s = []
        for idx, value in enumerate(self.data):
            s.append(binary(value, 8, idx <= self.py_endi and (not self.first or idx >= self.start)))
        s.append(binary(self.first, 1))
        s.append(binary(self.start, 2, self.first))
        s.append(binary(self.last, 1))
        s.append(binary(self.endi, WB))
        return ''.join(s)

    def __repr__(self):
        start = self.start if self.first else 0
        return 'CS(%s%s%s%s%s)' % (
            '<' if self.first else '|',
            '/' * start,
            safe_chr(self.data[start:self.py_endi+1], oneline=True),
            '/' * (2*WI-1-self.py_endi),
            '>' if self.last else '|')

_ElementStream = namedtuple('_ElementStream', [
    'cp_val',   # copy element valid
    'cp_off',   # copy element offset as recorded in the element
    'cp_len',   # copy element length as recorded in the element (diminished-1)
    'li_val',   # literal element valid
    'li_off',   # offset of the literal data in the current line
    'li_len',   # literal element length as recorded in the element (diminished-1)
    'ld_pop',   # pop the literal data FIFO to advance to the next line afterwards
    'last',     # indicator for last element data in chunk
    'py_data',  # literal data that accompanies this block, doesn't exist in hardware
])

class ElementStream(_ElementStream):
    def __new__(cls, *args, **kwargs):
        el = super(ElementStream, cls).__new__(cls, *args, **kwargs)
        assert is_std_logic(el.cp_val)
        assert is_unsigned(el.cp_off, 16)
        assert is_unsigned(el.cp_len, 6)
        assert is_std_logic(el.li_val)
        assert is_unsigned(el.li_off, WB+1)
        assert is_unsigned(el.li_len, 16)
        assert is_std_logic(el.ld_pop)
        assert is_std_logic(el.last)
        assert el.ld_pop or not el.last
        return el

    def serialize(self):
        s = []
        s.append(binary(self.cp_val, 1))
        s.append(binary(self.cp_off, 16, self.cp_val))
        s.append(binary(self.cp_len, 6, self.cp_val))
        s.append(binary(self.li_val, 1))
        s.append(binary(self.li_off, WB+1, self.li_val))
        s.append(binary(self.li_len, 16, self.li_val))
        s.append(binary(self.ld_pop, 1))
        s.append(binary(self.last, 1))
        return ''.join(s)

    def __repr__(self):
        return 'EL([%s%s, cp=%-15s li=%-15s ld=%s)' % (
            safe_chr(self.py_data, oneline=True),
            '>' if self.last else ']',
            '<o=%-5d l=%d>,' % (self.cp_off, self.cp_len+1) if self.cp_val else '-,',
            '<o=%-2d l=%d>,' % (self.li_off, self.li_len+1) if self.li_val else '-,',
            'pop' if self.ld_pop else '-  ')

_CommandStream = namedtuple('_CommandStream', [
    'lt_val',   # enable long-term memory read
    'lt_adev',  # long-term memory line address for the even line/array
    'lt_adod',  # long-term memory line address for the odd line/array
    'lt_swap',  # 0: linepair = odd & even; 1: linepair = even & odd
    'st_addr',  # relative first-line index for short-term memory read; -1 = current line, +back
    'cp_rol',   # copy rotation amount for the virtual 16:8 rotator, or byte index for rle
    'cp_rle',   # indicates that the rotator should behave like a mux for run-length acceleration
    'cp_end',   # index of the last valid copy byte provided by this command + one
    'li_rol',   # literal rotation amount for the virtual 16:8 rotator
    'li_end',   # index of the last valid literal byte provided by this command + one
    'ld_pop',   # pop the literal data FIFO to advance to the next line afterwards
    'last',     # indicator for last command in chunk
    'py_data',  # literal data that accompanies this block, doesn't exist in hardware
    'py_start', # start index for valid bytes, computed from context in hardware
])

class CommandStream(_CommandStream):
    def __new__(cls, *args, **kwargs):
        cm = super(CommandStream, cls).__new__(cls, *args, **kwargs)
        assert is_std_logic(cm.lt_val)
        assert is_unsigned(cm.lt_adev, 12)
        assert is_unsigned(cm.lt_adod, 12)
        assert is_std_logic(cm.lt_swap)
        assert is_unsigned(cm.st_addr, 5)
        assert is_unsigned(cm.cp_rol, WB+1)
        assert is_std_logic(cm.cp_rle)
        assert is_unsigned(cm.cp_end, WB+1)
        assert is_unsigned(cm.li_rol, WB+1)
        assert is_unsigned(cm.li_end, WB+1)
        assert is_std_logic(cm.ld_pop)
        assert is_std_logic(cm.last)
        assert cm.ld_pop or not cm.last
        assert cm.li_end <= WI or not cm.last
        return cm

    def serialize(self):
        s = []
        cp_val = self.cp_end > self.py_start
        s.append(binary(self.lt_val, 1, cp_val))
        s.append(binary(self.lt_adev, 15-WB, self.lt_val and cp_val))
        s.append(binary(self.lt_adod, 15-WB, self.lt_val and cp_val))
        s.append(binary(self.lt_swap, 1 and cp_val))
        s.append(binary(self.st_addr, 5, not self.lt_val and cp_val))
        s.append(binary(self.cp_rol, WB+1 and cp_val))
        s.append(binary(self.cp_rle, 1 and cp_val))
        s.append(binary(self.cp_end, WB+1))
        li_val = self.li_end > self.cp_end
        s.append(binary(self.li_rol, WB+1, li_val))
        s.append(binary(self.li_end, WB+1, li_val))
        s.append(binary(self.ld_pop, 1))
        s.append(binary(self.last, 1))
        return ''.join(s)

    def __repr__(self):
        if self.cp_end > self.py_start:
            if self.lt_val:
                even = '%03Xe' % self.lt_adev
                odd = '%03Xo' % self.lt_adod
                low = odd if self.lt_swap else even
                high = even if self.lt_swap else odd
            else:
                low = '%ds' % self.st_addr
                high = '%ds' % (self.st_addr - 1)
            if self.cp_rle:
                cp = 'C=[%s](%d),' % (low, self.cp_rol)
            else:
                cp = 'C=[%s|%s] <<> %d,' % (low, high, self.cp_rol)
        else:
            cp = ''

        if self.li_end > self.cp_end:
            li_len = self.li_end - self.cp_end
            start = self.li_rol + self.cp_end
            stop = start + li_len
            a = max(0, start - WI*2)
            b = max(0, stop - WI*2)
            c = min(start, WI*2)
            d = min(stop, WI*2)
            li = 'L=|'
            li += safe_chr(self.py_data[:a], oneline=True)
            li += '\033[44m' + safe_chr(self.py_data[a:b], oneline=True)
            li += safe_chr(self.py_data[b:c], oneline=True)
            li += '\033[44m' + safe_chr(self.py_data[c:d], oneline=True)
            li += safe_chr(self.py_data[d:], oneline=True)
            li += '|,'
        else:
            li = ' ' * (WI*2+5)

        srcs = [' '] * (WI*2-1)
        for i in range(self.py_start, self.cp_end):
            srcs[i] = 'C'
        for i in range(self.cp_end, self.li_end):
            srcs[i] = 'L'
        srcs = ''.join(srcs)

        return 'CM(|%s|%s%s, %-21s %s %s)' % (
            srcs[:WI], srcs[WI:],
            '>' if self.last else '|',
            cp, li,
            'pop' if self.ld_pop else '   ')

_DecompressedStream = namedtuple('_DecompressedStream', [
    'data',     # decompressed data (WI bytes)
    'last',     # indicator for last line in chunk
    'cnt',      # number of valid data bytes if last is set; can be zero!
])

class DecompressedStream(_DecompressedStream):
    def __new__(cls, *args, **kwargs):
        de = super(DecompressedStream, cls).__new__(cls, *args, **kwargs)
        assert is_byte_array(de.data, WI)
        assert is_std_logic(de.last)
        assert is_unsigned(de.cnt, WB+1)
        assert de.cnt == WI or de.last
        return de

    def serialize(self):
        s = []
        for idx, value in enumerate(self.data):
            s.append(binary(value, 8, idx < self.cnt))
        s.append(binary(self.last, 1))
        s.append(binary(self.cnt, WB+1))
        return ''.join(s)

    def __repr__(self):
        return 'DE(|%s%s%s)' % (
            safe_chr(self.data[:self.cnt], oneline=True),
            '/' * (WI-self.cnt),
            '>' if self.last else '|')
