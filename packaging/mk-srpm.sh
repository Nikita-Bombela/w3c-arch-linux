#!/usr/bin/env bash
# Build the pinned SRPM w3c-linux-VER-1.src.rpm from a release tarball (Phase 21 D-07); build-rpm and push-copr both run it, from the tarball and from a checkout.
# The repo spec keeps %{w3c_version}; only the copy in the temp directory gets the literal Version line, so the SRPM rebuilds with no define (D-10).
# Usage: mk-srpm.sh VER TARBALL OUTDIR
set -euo pipefail

[ $# -eq 3 ] || { echo 'usage: mk-srpm.sh VER TARBALL OUTDIR' >&2; exit 2; }
ver=$1 tarball=$2 outdir=$3

err() {
  echo "::error::$*"
  exit 1
}

printf '%s' "$ver" | grep -Eqx '[0-9]+\.[0-9]+\.[0-9]+' || err "VER is '$ver', want N.N.N"

top=$(mktemp -d)
trap 'rm -rf "$top"' EXIT
mkdir -p "$top/SOURCES"
cp "$tarball" "$top/SOURCES/w3c-linux-$ver.tar.gz"

# the spec as released, read out of the tarball; the copy is the only file that is ever rewritten
tar -xzf "$tarball" -O "w3c-linux-$ver/packaging/w3c-linux.spec" > "$top/orig.spec" || err "the tarball has no w3c-linux-$ver/packaging/w3c-linux.spec"
n=$(grep -c '^Version:' "$top/orig.spec" || true)
[ "$n" = 1 ] || err "the spec holds $n Version: lines, want exactly 1"

sed "s/^Version:.*/Version:        $ver/" "$top/orig.spec" > "$top/w3c-linux.spec"
n=$(grep -cxF "Version:        $ver" "$top/w3c-linux.spec" || true)
[ "$n" = 1 ] || err "the pinned spec does not hold the line 'Version:        $ver' exactly once"
if grep -v '^[[:space:]]*#' "$top/w3c-linux.spec" | grep -qF '%{w3c_version}'; then
  err 'the pinned spec still uses %{w3c_version} outside a comment'
fi

# no w3c_version define: an unpinned spec fails in %prep, which is the proof the pin took
rpmbuild -bs --define "_topdir $top" "$top/w3c-linux.spec"

# the exact name, so an SRPM named differently fails this copy
mkdir -p "$outdir"
cp "$top/SRPMS/w3c-linux-$ver-1.src.rpm" "$outdir/"
