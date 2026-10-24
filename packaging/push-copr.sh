#!/usr/bin/env bash
# Send the release tarball to the token owner's w3c-linux Copr project as a pinned SRPM and wait for the build (Phase 21 D-07, D-08); release.yml's push-copr job runs it after publish.
# COPR_CONFIG (the API login and token, from the package-repos Environment) arrives in the env only: it goes to a private temp file and is never printed.
# Usage: COPR_CONFIG=... push-copr.sh VER TARBALL
set -euo pipefail

[ $# -eq 2 ] || { echo 'usage: push-copr.sh VER TARBALL (COPR_CONFIG in the env)' >&2; exit 2; }
ver=$1 tarball=$2

err() {
  echo "::error::$*"
  exit 1
}

# copr_expiry CFG [NOW]: warn (never fail) when the token's '# expiration date:' line is under 30 days away or unreadable; NOW is epoch seconds (D-04)
copr_expiry() {
  local cfg=$1 now=${2:-$(date +%s)} val exp days
  val=$(sed -n '/^# *expiration date: */{s///p;q}' "$cfg")
  exp=''
  [ -z "$val" ] || exp=$(date -u -d "$val" +%s 2> /dev/null) || exp=''
  if [ -z "$exp" ]; then
    echo "::warning::cannot read the Copr token's expiry date from COPR_CONFIG; check it on the Copr API page (RELEASE.md)"
    return 0
  fi
  days=$(((exp - now / 86400 * 86400) / 86400))
  if [ "$days" -lt 30 ]; then
    echo "::warning::the Copr token expires in $days days ($val); renew it and replace COPR_CONFIG (RELEASE.md)"
  fi
  return 0
}

printf '%s' "$ver" | grep -Eqx '[0-9]+\.[0-9]+\.[0-9]+' || err "VER is '$ver', want N.N.N"
[ -n "${COPR_CONFIG:-}" ] || err 'COPR_CONFIG is empty; it lives in the package-repos Environment (RELEASE.md)'

umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cfg=$work/copr.conf
printf '%s\n' "$COPR_CONFIG" > "$cfg"
copr_expiry "$cfg"

# the token's user owns the project (the bot account, D-01), so no owner name lives in the repo
owner=$(copr-cli --config "$cfg" whoami) || err 'the Copr token was rejected; renew it and replace COPR_CONFIG (RELEASE.md)'
[ -n "$owner" ] || err 'copr-cli whoami printed no user name'

# the project is created once by hand; a recreated one gets a new signing key (D-01), so this only reads it
copr-cli --config "$cfg" get "$owner/w3c-linux" > /dev/null 2>&1 || err "Copr project $owner/w3c-linux is missing or unreadable; it is created once by hand (RELEASE.md), never from CI"

out=$work/srpm
bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mk-srpm.sh" "$ver" "$tarball" "$out"

# build waits for the result and exits non-zero on a failed or cancelled build (D-08)
copr-cli --config "$cfg" build "$owner/w3c-linux" "$out/w3c-linux-$ver-1.src.rpm" || err "the Copr build of w3c-linux $ver failed; the release is unchanged; republish after fixing it (RELEASE.md)"
