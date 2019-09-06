
with open('hw_snappy_1000ps_int64.parquet', 'rb') as fi, open('compressed.raw', 'wb') as fo:
    fo.write(fi.read()[30:30+7733])

