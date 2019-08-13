# This makefile builds the snappy library and snzip command-line tool. These
# are used by the test case generator.

HERE = $(shell pwd)

bin: snzip-install/bin/snzip snzip-install/bin/snunzip
	mkdir -p bin
	cd bin && ln -fs ../snzip-install/bin/snzip
	cd bin && ln -fs ../snzip-install/bin/snunzip

snzip-install/bin/snzip snzip-install/bin/snunzip: snzip snappy-install/lib/libsnappy.a
	rm -rf snzip-install
	mkdir -p snzip-install
	cd snzip && ./autogen.sh
	cd snzip && automake
	cd snzip && ../snzip/configure \
		--prefix=$(HERE)/snzip-install \
		--with-snappy=$(HERE)/snappy-install \
		--with-static-snappy
	$(MAKE) -C snzip
	$(MAKE) -C snzip install

snappy-install/lib/libsnappy.a: snappy
	rm -rf snappy-build snappy-install
	mkdir -p snappy-build snappy-install
	cd snappy-build && cmake -DCMAKE_INSTALL_PREFIX:PATH=$(HERE)/snappy-install $(HERE)/snappy
	$(MAKE) -C snappy-build
	$(MAKE) -C snappy-build install
	-mv snappy-install/lib64 snappy-install/lib

snappy snzip:
	git submodule update --init snappy snzip

.PHONY: clean
clean:
	rm -rf snzip-install snappy-build snappy-install bin
	-$(MAKE) -C snzip distclean
