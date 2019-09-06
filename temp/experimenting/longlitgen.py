
import random
random.seed(0)

byts = []

for x in range(256):
    for y in range(128):
        byts.append(x)
        byts.append(y)

with open('bench-worst-case.bin', 'wb') as f:
    f.write(bytes(byts))


byts = []

while len(byts) < 65536:
    byts.extend([random.randint(0, 255)] * random.randint(5, 80))
byts = byts[:65536]

with open('bench-run-length.bin', 'wb') as f:
    f.write(bytes(byts))

