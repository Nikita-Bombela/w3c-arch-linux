#!/usr/bin/env bash
# Commit the release's Debian source package to the bot's w3c-linux OBS package and wait until all four targets built (Phase 21 D-07, D-08); release.yml's push-obs job runs it after publish.
# OBS_USER and OBS_PASS (from the package-repos Environment) arrive in the env only: the oscrc that holds them lives in a private temporary HOME that the EXIT trap removes, and is never printed.
# Usage: OBS_USER=... OBS_PASS=... push-obs.sh VER TARBALL
set -euo pipefail

[ $# -eq 2 ] || { echo 'usage: push-obs.sh VER TARBALL (OBS_USER and OBS_PASS in the env)' >&2; exit 2; }
ver=$1 tarball=$2

err() {
  echo "::error::$*"
  exit 1
}

# obs_all_succeeded: reads 'repository arch code' lines on stdin; returns 0 only when they are exactly the four targets, each x86_64 and succeeded.
# An excluded target is not an error to osc, but D-08 wants all four, so this is the check that counts.
obs_all_succeeded() {
  local want got
  want=$(printf '%s x86_64 succeeded\n' Debian_12 Debian_13 xUbuntu_24.04 xUbuntu_26.04 | LC_ALL=C sort)
  got=$(LC_ALL=C sort)
  [ "$got" = "$want" ]
}

printf '%s' "$ver" | grep -Eqx '[0-9]+\.[0-9]+\.[0-9]+' || err "VER is '$ver', want N.N.N"
printf '%s' "${OBS_USER:-}" | grep -Eqx '[A-Za-z0-9._-]+' || err 'OBS_USER is empty or not a user name; it lives in the package-repos Environment (RELEASE.md)'
[ -n "${OBS_PASS:-}" ] || err 'OBS_PASS is empty; it lives in the package-repos Environment (RELEASE.md)'

tarball=$(realpath "$tarball")
dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

umask 077
HOME=$(mktemp -d)
export HOME
trap 'rm -rf "$HOME"' EXIT
mkdir -p "$HOME/.config/osc"
printf '[general]\napiurl = https://api.opensuse.org\n[https://api.opensuse.org]\nuser = %s\npass = %s\n' "$OBS_USER" "$OBS_PASS" > "$HOME/.config/osc/oscrc"
cd "$HOME"

# the project and package are created once by hand; a recreated project gets a new signing key for every apt user (D-01), so this only checks them out
osc co "home:$OBS_USER:w3c-linux" w3c-linux > /dev/null || err "OBS package home:$OBS_USER:w3c-linux/w3c-linux is missing or the credentials were rejected; it is created once by hand (RELEASE.md), never from CI"
cd "home:$OBS_USER:w3c-linux/w3c-linux"

# one .dsc and one orig tarball at a time; .osc/ is hidden and stays
rm -f -- *
bash "$dir/mk-dsc.sh" "$ver" "$tarball" .
osc addremove
osc ci -m "w3c-linux $ver"

# -w waits for the builds. No -F: osc counts any 'broken' it saw while watching as failed, and a fresh commit shows 'broken' until OBS's scheduler reads it (seen at the first real push, 21-06), so -F exits 1 on a build that then succeeds; obs_all_succeeded below is the failure check (D-08)
osc results -w > /dev/null || err "osc results failed while waiting for the build of w3c-linux $ver"
res=$(osc results --format '%(repository)s %(arch)s %(code)s') || err "osc results failed after the build of w3c-linux $ver"
obs_all_succeeded <<< "$res" || err "an OBS build of w3c-linux $ver failed or a target is missing; the release is unchanged; want Debian_12, Debian_13, xUbuntu_24.04 and xUbuntu_26.04 as x86_64 succeeded, got: ${res//$'\n'/; } (see the OBS package page, then republish; RELEASE.md)"
