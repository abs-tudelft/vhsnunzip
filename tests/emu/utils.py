
def safe_chr(data, oneline=False):
    """Returns a byte or iterable of bytes as ASCII, using ANSI color codes to
    represent non-printables. If oneline is set, \n is treated as a special
    character, otherwise it is passed through unchanged. The following color
    codes are used:

     - green 'n': newline
     - green 'r': carriage return
     - green 't': horizontal tab
     - red number: control codes 0 through 9
     - red uppercase up to V: control code 10 through 31
     - dark gray dot: code 32 (space)
     - bright character: code 33 through 126 (printables)
     - red 'Y': control code 127
     - red '^': code 128 through 255
    """
    if not hasattr(data, '__iter__'):
        data = [data]
    s = ['\033[1m']
    for value in data:
        if value == ord('\n'):
            if oneline:
                s.append('\033[32mn')
            else:
                s.append('\n')
        elif value == ord('\r'):
            s.append('\033[32mr')
        elif value == ord('\t'):
            s.append('\033[32mt')
        elif value < 10:
            s.append('\033[31m%d' % value)
        elif value < 32:
            s.append('\033[31m%s' % chr(ord('A') + value))
        elif value == 32:
            s.append('\033[30m·')
        elif value < 127:
            s.append('\033[37m%s' % chr(value))
        elif value == 127:
            s.append('\033[31mY')
        else:
            s.append('\033[31m^')
    return ''.join(s) + '\033[0m'

def binary(data, bits, valid=True):
    """Returns a python integer or list of integers as a (concatenated)
    std_logic_vector string of the given bitcount per element. If valid is
    specified and false, don't-cares are returned instead."""
    if not hasattr(data, '__iter__'):
        data = [data]
    s = []
    for value in data:
        if valid:
            s.append(('{:0%db}' % bits).format(value & (2**bits-1)))
        else:
            s.append('-' * bits)
    return ''.join(s)

def is_std_logic(value):
    """Returns whether the given value is the Python equivalent of an
    std_logic."""
    return value is True or value is False

def is_unsigned(value, bits):
    """Returns whether the given value is the Python equivalent of an
    unsigned with the given length."""
    return not (value & ~(2**bits-1))

def is_signed(value, bits):
    """Returns whether the given value is the Python equivalent of an
    signed with the given length."""
    return value >= -2**(bits-1) and value < 2**(bits-1)

def is_std_logic_vector(value, bits):
    """Returns whether the given value is the Python equivalent of an
    std_logic_vector with the given length."""
    return value & ~(2**bits-1) in [0, -1]

def is_byte_array(value, count):
    """Returns whether the given value is the Python equivalent of a
    byte array."""
    return isinstance(value, tuple) and len(value) == count and all(map(lambda x: x >= 0 and x <= 255, value))

