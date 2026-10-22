#!/usr/bin/env bash
# Build the 3.0 (quilt) Debian source package of a release from its tarball (Phase 21 D-07): w3c-linux_VER.orig.tar.gz, w3c-linux_VER-1.debian.tar.xz and w3c-linux_VER-1.dsc.
# build-deb (the dry run, from the tarball) and push-obs.sh (from a checkout) both run it; debian/changelog is written as build-deb writes it (Phase 13 D-14).
# Usage: mk-dsc.sh VER TARBALL OUTDIR
set -euo pipefail

[ $# -eq 3 ] || { echo 'usage: mk-dsc.sh VER TARBALL OUTDIR' >&2; exit 2; }
ver=$1 tarball=$2 outdir=$3

err() {
  echo "::error::$*"
  exit 1
}

printf '%s' "$ver" | grep -Eqx '[0-9]+\.[0-9]+\.[0-9]+' || err "VER is '$ver', want N.N.N"
[ -f "$tarball" ] || err "the tarball $tarball does not exist"

# absolute paths first: the work below happens in a temporary directory
tarball=$(realpath "$tarball")
mkdir -p "$outdir"
outdir=$(realpath "$outdir")

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

orig=w3c-linux_$ver.orig.tar.gz
cp "$tarball" "$orig"
tar -xzf "$orig"
[ -d "w3c-linux-$ver/packaging/debian" ] || err "the tarball has no w3c-linux-$ver/packaging/debian"
cp -r "w3c-linux-$ver/packaging/debian" "w3c-linux-$ver/debian"

# the changelog trailer comes from control, so the two cannot disagree (Phase 13 D-14)
maint=$(sed -n 's/^Maintainer: //p' "w3c-linux-$ver/debian/control")
[ -n "$maint" ] || err 'debian/control has no Maintainer line'
printf 'w3c-linux (%s-1) unstable; urgency=medium\n\n  * Release %s.\n\n -- %s  %s\n' "$ver" "$ver" "$maint" "$(date -R)" > "w3c-linux-$ver/debian/changelog"

dpkg-source -b "w3c-linux-$ver" > /dev/null || err "dpkg-source -b failed for w3c-linux $ver"

dsc=w3c-linux_$ver-1.dsc
deb=w3c-linux_$ver-1.debian.tar.xz
grep -qxF 'Format: 3.0 (quilt)' "$dsc" || err "$dsc does not read 'Format: 3.0 (quilt)'"
grep -qxF "Version: $ver-1" "$dsc" || err "$dsc does not read 'Version: $ver-1'"
mkdir rt
(cd rt && dpkg-source -x "../$dsc" x > /dev/null) || err "dpkg-source -x of $dsc failed"

# exactly these three names, so a different name fails this copy
cp "$orig" "$deb" "$dsc" "$outdir/"
