
TOPLEVELS = vhsnunzip_unbuffered vhsnunzip_buffered vhsnunzip_5 vhsnunzip_8

.PHONY: all
all: synth

tools/bin/snzip tools/bin/snunzip:
	$(MAKE) -C tools

.PHONY: synth
synth: $(patsubst %,synth_%,$(TOPLEVELS))

.PHONY: synth_%
synth_%:
	python3 synthesize.py $*
