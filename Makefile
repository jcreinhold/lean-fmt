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

# The Linux repro, one command. The 22.04 userland is where platform-shaped failures have
# surfaced twice (mtime granularity, the cache-epoch contamination), and it is what the release
# legs run. The working tree is archived, never mounted: macOS build outputs must not mix with
# Linux ones. The `lf-elan` volume caches the toolchain and `lf-lake-build` the build outputs,
# so repeat runs are minutes, not tens of minutes. First repro for any failure that smells
# platform-dependent; not part of the default flow.
test-linux:
	@command -v docker >/dev/null || { echo "test-linux needs docker"; exit 1; }
	@docker info >/dev/null 2>&1 || { echo "test-linux needs the docker daemon running"; exit 1; }
	$(eval WORK := $(shell mktemp -d /tmp/lean-fmt-linux.XXXXXX))
	git archive HEAD | tar -x -C "$(WORK)"
	@git diff HEAD --name-only -z | xargs -0 -I{} sh -c 'mkdir -p "$(WORK)/$$(dirname {})" && cp "{}" "$(WORK)/{}"'
	docker run --rm --cpus=2 --memory=8g -e LEAN_NUM_THREADS=2 \
	  -v "$(WORK)":/w -v lf-elan:/root/.elan -v lf-lake-build:/w/.lake -w /w \
	  ubuntu:22.04 bash -c '\
	  export PATH=/root/.elan/bin:$$PATH; \
	  apt-get update -qq >/dev/null 2>&1; \
	  apt-get install -y -qq curl git ca-certificates python3 binutils >/dev/null 2>&1; \
	  if ! which lake >/dev/null 2>&1; then \
	    curl -sL https://elan.lean-lang.org/elan-init.sh -o /tmp/elan.sh && \
	    bash /tmp/elan.sh -y --default-toolchain none >/dev/null 2>&1; \
	  fi; \
	  export PATH=/root/.elan/bin:$$PATH; \
	  git init -q .; git -c user.email=t@t -c user.name=t add -A >/dev/null; \
	  git -c user.email=t@t -c user.name=t commit -qm init >/dev/null; \
	  lake build test-suites && lake test -- --skip-unit --jobs 2'
	rm -rf "$(WORK)"

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

.PHONY: build test test-all test-linux lint install uninstall clean
