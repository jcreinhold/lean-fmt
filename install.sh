#!/bin/sh
# Install a prebuilt lean-fmt release binary from GitHub:
#
#   curl -sSfL https://raw.githubusercontent.com/jcreinhold/lean-fmt/main/install.sh | sh
#
# The binaries are statically self-contained; at runtime lean-fmt needs the *target* project's
# Lean toolchain (via elan), which a Lean project has by definition.
#
# Environment knobs:
#   VERSION       release to install (default: latest); with or without the leading "v"
#   PREFIX        installation prefix (default: ~/.local); binaries land in $PREFIX/bin
#   RELEASE_BASE  download URL override, for testing against a local mirror

set -eu

REPO="jcreinhold/lean-fmt"
PREFIX="${PREFIX:-$HOME/.local}"
BINDIR="$PREFIX/bin"

# --- platform -------------------------------------------------------------
os=$(uname -s)
arch=$(uname -m)
case "$os" in
Linux)
	case "$arch" in
	x86_64) target=x86_64-unknown-linux-gnu ;;
	aarch64 | arm64) target=aarch64-unknown-linux-gnu ;;
	*)
		echo "install.sh: unsupported Linux architecture: $arch" >&2
		exit 1
		;;
	esac
	;;
Darwin)
	case "$arch" in
	x86_64) target=x86_64-apple-darwin ;;
	arm64) target=aarch64-apple-darwin ;;
	*)
		echo "install.sh: unsupported macOS architecture: $arch" >&2
		exit 1
		;;
	esac
	;;
*)
	echo "install.sh: unsupported OS: $os — on Windows, take the Lake dependency or build from source with make install" >&2
	exit 1
	;;
esac

# --- version ---------------------------------------------------------------
if [ "${VERSION:-latest}" = latest ]; then
	version=$(curl -sSfL "https://api.github.com/repos/$REPO/releases/latest" |
		sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
	if [ -z "$version" ]; then
		echo "install.sh: could not resolve the latest release tag" >&2
		exit 1
	fi
else
	version="$VERSION"
fi
case "$version" in
v*) ;;
*) version="v$version" ;;
esac

# --- download and verify -----------------------------------------------------
name="lean-fmt-${version#v}-$target"
base="${RELEASE_BASE:-https://github.com/$REPO/releases/download/$version}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "install.sh: fetching $name"
curl -sSfL "$base/$name.tar.gz" -o "$tmp/$name.tar.gz"
curl -sSfL "$base/SHA256SUMS" -o "$tmp/SHA256SUMS"
(
	cd "$tmp"
	grep " $name.tar.gz\$" SHA256SUMS >sum.txt
	# Require the OK line, not the checker's exit code: this platform's sha256sum only
	# warns and exits 0 on an improperly formatted sum line, which would verify nothing.
	if command -v sha256sum >/dev/null 2>&1; then
		out=$(sha256sum -c sum.txt 2>&1)
	else
		out=$(shasum -a 256 -c sum.txt 2>&1)
	fi
	echo "$out"
	echo "$out" | grep -q ": OK\$" || {
		echo "install.sh: checksum verification failed for $name.tar.gz" >&2
		exit 1
	}
)

# --- install -------------------------------------------------------------------
tar -xzf "$tmp/$name.tar.gz" -C "$tmp"
mkdir -p "$BINDIR"
install -m 755 "$tmp/$name/bin/lean-fmt" "$BINDIR/lean-fmt"
install -m 755 "$tmp/$name/bin/lean-fmt-artifact-extract" "$BINDIR/lean-fmt-artifact-extract"

"$BINDIR/lean-fmt" --help >/dev/null
echo "install.sh: installed lean-fmt ${version#v} to $BINDIR"
if ! command -v lake >/dev/null 2>&1; then
	echo "install.sh: note: no lake on PATH — lean-fmt needs the target project's Lean toolchain (elan) at runtime" >&2
fi
