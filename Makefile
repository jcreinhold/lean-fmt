# Building and installing lean-fmt from source.
#
# `lake` is the build system and does everything except placing the binaries; this file is only the
# conventional front end (`make`, `make test`, `make install`). The pinned toolchain comes from
# `lean-toolchain` — with elan on PATH, the first `lake` invocation installs it automatically.
#
# Install layout follows the GNU convention: `make install PREFIX=/usr/local` puts the binaries in
# /usr/local/bin, and packagers can stage with DESTDIR. The default PREFIX is per-user, no sudo.

PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin

BINARIES := lean-fmt lean-fmt-artifact-extract

build:
	lake build lean-fmt artifactExtractor

test:
	lake test

# The minutes-long suites included; what the CI workflow's manual `slow` job runs.
test-all:
	lake test -- --all

lint:
	lake lint

install: build
	install -d "$(DESTDIR)$(BINDIR)"
	for binary in $(BINARIES); do \
		install -m 755 ".lake/build/bin/$$binary" "$(DESTDIR)$(BINDIR)/$$binary"; \
	done

uninstall:
	for binary in $(BINARIES); do \
		rm -f "$(DESTDIR)$(BINDIR)/$$binary"; \
	done

clean:
	lake clean

.PHONY: build test test-all lint install uninstall clean
