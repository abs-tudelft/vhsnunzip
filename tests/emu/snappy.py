import sys
import os
from os.path import join as pjoin
import tempfile
import subprocess
import random

def compress(data, bindir=None, snzip_args=None, verify=False,
             chunk_size=65536, max_chunk_size=None, min_chunk_size=None, max_prob=0.0):
    """Compresses data using the snzip command-line tool located in bindir (or
    ont the system path if not specified), with the specified chunk sizes.
    If verify is set, snunzip is called to check that the chunk decompresses
    correctly using the snappy library."""

    # Parse arguments.
    if bindir is None:
        snzip = ['snzip']
        snunzip = ['snunzip']
    else:
        snzip = [pjoin(bindir, 'snzip')]
        snunzip = [pjoin(bindir, 'snunzip')]
    if snzip_args:
        snzip.extend(snzip_args)
    if max_chunk_size is None:
        max_chunk_size = chunk_size
    if min_chunk_size is None:
        min_chunk_size = chunk_size

    # Split the data up into chunks.
    offset = 0
    uncompressed_chunks = []
    compressed_chunks = []
    if data:
        while offset < len(data):
            if random.random() < max_prob:
                size = max_chunk_size
            else:
                size = random.randint(min_chunk_size, max_chunk_size)
            chunk = data[offset:offset + size]
            uncompressed_chunks.append(chunk)
            offset += len(chunk)
    else:
        uncompressed_chunks.append(b'')

    # Compress the chunks.
    with tempfile.TemporaryDirectory() as tempdir:

        for chunk in uncompressed_chunks:
            with open(pjoin(tempdir, 'data'), 'wb') as fout:
                fout.write(chunk)
            subprocess.check_call(snzip + ['-traw', pjoin(tempdir, 'data')])
            with open(pjoin(tempdir, 'data.raw'), 'rb') as fin:
                chunk = fin.read()
            os.unlink(pjoin(tempdir, 'data.raw'))
            compressed_chunks.append(chunk)

        if verify:
            for uncomp, comp in zip(uncompressed_chunks, compressed_chunks):
                with open(pjoin(tempdir, 'data.raw'), 'wb') as fout:
                    fout.write(comp)
                subprocess.check_call(['tools/bin/snunzip', '-traw', pjoin(tempdir, 'data.raw')])
                with open(pjoin(tempdir, 'data'), 'rb') as fin:
                    if fin.read() != uncomp:
                        raise ValueError('verify failed!')
                os.unlink(pjoin(tempdir, 'data'))

    return compressed_chunks, uncompressed_chunks
