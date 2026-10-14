#!/usr/bin/env bash
# Live upstream check: runs the real lib/ code against what upstream serves today, as the nightly does, so a changed release asset or
# latest.json shape fails here exactly as it would fail a user. Each check prints "ok - SECTION: CHECK" or "not ok - SECTION: CHECK: REASON";
# the last line is "# N passed, M failed". Exit 0 when all passed, 1 on any failure, 2 on an unknown argument.
# Usage: bash tests/live.sh [--offline] [SECTION...]   (no section means all of them)
#   --offline   serve generated fixtures through a curl shim instead of the network; no network call is made
# Environment:
#   W3C_LIVE_RELEASE_API  replaces RELEASE_API after the libs load, so a deliberate red run needs no lib edit
#   W3C_LIVE_FIXTURES     with --offline: a directory whose files replace the default fixture of the same name
#   W3C_LIVE_CURL_LOG     with --offline: file that receives one line per curl call (default: curl.log in the temp dir)
#   TMPDIR                where the temp dir goes (default /var/tmp: the extracted Proton build is about 3 GB and /tmp is often a RAM tmpfs)
#   GITHUB_TOKEN          optional. When set it is sent only to https://api.github.com/ (the shared runner IP allows 60 unauthenticated
#                         calls an hour); curl does not forward a custom Authorization header to another host on a redirect. The token
#                         stays in a 0600 file and is never printed, which is also why this file never turns shell tracing on.
# It needs no GitHub Actions environment and runs by hand. The temp dir is the HOME of every lib call and is removed at exit.
# No errexit, so each check reports on its own. Never turn on shell tracing in this file: a token passes through it.
set -u -o pipefail

# shellcheck source-path=SCRIPTDIR

SECTIONS=(proton launcher webview2 watch)
OFFLINE=0
WANT=()
for a in "$@"; do
  case $a in
    --offline) OFFLINE=1 ;;
    *)
      case " ${SECTIONS[*]} " in
        *" $a "*) WANT+=("$a") ;;
        *)
          printf 'usage: bash tests/live.sh [--offline] [proton|launcher|webview2|watch]...\n' >&2
          exit 2 ;;
      esac ;;
  esac
done
[ "${#WANT[@]}" -gt 0 ] || WANT=("${SECTIONS[@]}")

TMP=$(mktemp -d "${TMPDIR:-/var/tmp}/w3c-live.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" || exit 1
export HOME=$TMP/home
unset XDG_STATE_HOME XDG_CACHE_HOME XDG_DATA_HOME XDG_CONFIG_HOME

# common.sh reads SELF and derives its paths from HOME when it loads; w3c-linux.sh itself cannot be sourced, so its three paths are set here.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SELF=$ROOT/w3c-linux.sh
LIB_DIR=$ROOT/lib
HELPER=$LIB_DIR/w3c_helper.py
# shellcheck source=SCRIPTDIR/../lib/common.sh
. "$LIB_DIR/common.sh" || exit 1
# shellcheck source=SCRIPTDIR/../lib/faugus.sh
. "$LIB_DIR/faugus.sh" || exit 1
# shellcheck source=SCRIPTDIR/../lib/checks.sh
. "$LIB_DIR/checks.sh" || exit 1
# shellcheck source=SCRIPTDIR/../lib/proton.sh
. "$LIB_DIR/proton.sh" || exit 1
# shellcheck source=SCRIPTDIR/../lib/prefix.sh
. "$LIB_DIR/prefix.sh" || exit 1
# shellcheck source=SCRIPTDIR/../lib/update.sh
. "$LIB_DIR/update.sh" || exit 1

CMD=live   # the prefix of the lib's own messages
# common.sh assigns RELEASE_API when it loads, so the override for a deliberate red run comes here and lib/ stays unchanged.
RELEASE_API=${W3C_LIVE_RELEASE_API:-$RELEASE_API}

PASS=0 FAIL=0

# pass NAME [DETAIL]
pass() {
  PASS=$((PASS + 1))
  printf 'ok - %s%s\n' "$1" "${2:+ ($2)}"
}

# fail NAME REASON: also a workflow annotation under GitHub Actions. The title is NAME up to its first colon (a title holds no colon or
# comma) and every % of the message is escaped; the reasons are fixed texts and lib messages built from validated tags and versions.
fail() {
  local msg
  FAIL=$((FAIL + 1))
  printf 'not ok - %s: %s\n' "$1" "$2"
  if [ "${GITHUB_ACTIONS:-}" = true ]; then
    msg="$1: $2"
    printf '::error title=live %s::%s\n' "${1%%:*}" "${msg//%/%25}"
  fi
}

# is_magic FILE HEX: the first bytes of FILE, as hex, equal HEX.
is_magic() {
  [ "$(head -c $((${#2} / 2)) -- "$1" 2> /dev/null | od -An -tx1 | tr -d ' \n')" = "$2" ]
}

# ---------- offline fixtures ----------

# --offline serves these values; they must match tests/fixtures/upstream-state.txt.
OFF_LAUNCHER=1.6.19
OFF_TAG=GE-Proton11-7-W3C
OFF_GE=GE-Proton11-9
OFF_ISSUE57=open

if [ "$OFFLINE" = 1 ]; then
  FIX=$TMP/fix
  mkdir -p "$FIX" "$TMP/bin" || exit 1
  # a file the caller put in W3C_LIVE_FIXTURES wins: each default below is written only when FIX has no file of that name
  [ -z "${W3C_LIVE_FIXTURES:-}" ] || cp -R -- "$W3C_LIVE_FIXTURES/." "$FIX/" || exit 1
  [ -e "$FIX/latest.json" ] || printf '{"version": "%s", "platforms": {"windows-x86_64-msi": {"url": "https://github.com/w3champions/launcher-e-release/releases/download/%s/W3Champions_%s_x64_en-US.msi"}}}\n' \
    "$OFF_LAUNCHER" "$OFF_LAUNCHER" "$OFF_LAUNCHER" > "$FIX/latest.json"
  for f in launcher-e launcher.msi; do
    [ -e "$FIX/$f" ] || printf '\320\317\021\340\241\261\032\341fake MSI installer\n' > "$FIX/$f"
  done
  # the release document, the tarball (the entries of a complete build) with its SHA256SUMS line, and the WebView2 stub
  [ -e "$FIX/release.json" ] || printf '{"tag_name": "%s", "draft": false, "prerelease": false, "assets": [{"name": "%s.tar.gz", "size": 1088358492, "browser_download_url": "https://github.com/davex32/proton-ge-w3c/releases/download/%s/%s.tar.gz"}, {"name": "%s.sha512sum", "size": 164, "browser_download_url": "https://github.com/davex32/proton-ge-w3c/releases/download/%s/%s.sha512sum"}, {"name": "SHA256SUMS", "size": 185, "browser_download_url": "https://github.com/davex32/proton-ge-w3c/releases/download/%s/SHA256SUMS"}]}\n' \
    "$OFF_TAG" "$OFF_TAG" "$OFF_TAG" "$OFF_TAG" "$OFF_TAG" "$OFF_TAG" "$OFF_TAG" "$OFF_TAG" > "$FIX/release.json"
  if [ ! -e "$FIX/$OFF_TAG.tar.gz" ]; then
    mkdir -p "$TMP/stage/$OFF_TAG/files/bin" || exit 1
    : > "$TMP/stage/$OFF_TAG/proton"
    chmod +x "$TMP/stage/$OFF_TAG/proton"
    printf '"compatibilitytools"\n{\n}\n' > "$TMP/stage/$OFF_TAG/compatibilitytool.vdf"
    printf '1700000000 %s\n' "$OFF_TAG" > "$TMP/stage/$OFF_TAG/version"
    : > "$TMP/stage/$OFF_TAG/files/bin/wine"
    tar -czf "$FIX/$OFF_TAG.tar.gz" -C "$TMP/stage" "$OFF_TAG" || exit 1
  fi
  [ -e "$FIX/SHA256SUMS" ] || (cd "$FIX" && sha256sum "$OFF_TAG.tar.gz" > SHA256SUMS) || exit 1
  [ -e "$FIX/webview2.exe" ] || printf 'MZfake PE installer\n' > "$FIX/webview2.exe"
  # the watch inputs; the protocol excerpt mentions limit_flags in set_job_limits too, as Wine master does, so only the get_job_info count is 0
  [ -e "$FIX/issue57.json" ] || printf '{"state": "%s"}\n' "$OFF_ISSUE57" > "$FIX/issue57.json"
  [ -e "$FIX/ge-latest.json" ] || printf '{"tag_name": "%s"}\n' "$OFF_GE" > "$FIX/ge-latest.json"
  [ -e "$FIX/protocol.def" ] || printf '%s\n' '@REQ(set_job_limits)' '    obj_handle_t handle;' '    unsigned int limit_flags;' '@END' \
    '@REQ(get_job_info)' '    obj_handle_t handle;' '@REPLY' '    int total_processes;' '    int active_processes;' '@END' > "$FIX/protocol.def"
  # the curl shim: logs its arguments, serves the fixture the URL maps to, exits 22 (curl's HTTP-error status) when there is none
  cat > "$TMP/bin/curl" <<'SH'
#!/bin/sh
printf '%s\n' "$0 $*" >> "$LIVE_LOG"
url='' out='' prev=''
for a in "$@"; do
  case $a in https://*) url=$a ;; esac
  [ "$prev" = -o ] && out=$a
  prev=$a
done
case $url in
  https://api.github.com/repos/davex32/*) f=$LIVE_FIX/release.json ;;
  https://go.microsoft.com/*) f=$LIVE_FIX/webview2.exe ;;
  https://api.github.com/repos/w3champions/w3champions-issues/issues/57) f=$LIVE_FIX/issue57.json ;;
  https://api.github.com/repos/GloriousEggroll/*) f=$LIVE_FIX/ge-latest.json ;;
  https://raw.githubusercontent.com/*) f=$LIVE_FIX/protocol.def ;;
  https://github.com/w3champions/launcher-e-release/releases/download/*) f=$LIVE_FIX/launcher.msi ;;
  *) f=$LIVE_FIX/${url##*/} ;;
esac
[ -f "$f" ] || exit 22
if [ -n "$out" ]; then cp "$f" "$out" || exit 23; else cat "$f"; fi
SH
  chmod +x "$TMP/bin/curl"
  export LIVE_FIX=$FIX LIVE_LOG=${W3C_LIVE_CURL_LOG:-$TMP/curl.log}
  PATH=$TMP/bin:$PATH
fi

# ---------- GitHub token ----------

# The wrapper sits first on PATH, after the offline shim, so in --offline mode its next curl is the shim and the log shows what real curl
# would receive. The header goes in through "-H @file" (never argv) and only when an argument is an https://api.github.com/ URL.
if [ -n "${GITHUB_TOKEN:-}" ]; then
  LIVE_REAL_CURL=$(type -P curl) || exit 1
  LIVE_AUTH_HDR=$TMP/auth.hdr
  (umask 077 && printf 'Authorization: Bearer %s\n' "$GITHUB_TOKEN" > "$LIVE_AUTH_HDR") || exit 1
  mkdir -p "$TMP/tok" || exit 1
  cat > "$TMP/tok/curl" <<'SH'
#!/bin/sh
for a in "$@"; do
  case $a in https://api.github.com/*) exec "$LIVE_REAL_CURL" -H "@$LIVE_AUTH_HDR" "$@" ;; esac
done
exec "$LIVE_REAL_CURL" "$@"
SH
  chmod +x "$TMP/tok/curl"
  export LIVE_REAL_CURL LIVE_AUTH_HDR
  PATH=$TMP/tok:$PATH
  echo '# GitHub API: authenticated with GITHUB_TOKEN'
else
  echo '# GitHub API: unauthenticated (60 requests an hour per IP)'
fi

# ---------- sections ----------

# proton: the whole path every time, no cache: release JSON, download, sha256sum -c, extract, build_complete; then the build is deleted.
live_proton() {
  if ! resolve_release; then
    fail 'proton: release JSON' "$RT_ERR"
    return
  fi
  pass 'proton: release JSON' "$RT_TAG, $RT_SIZE"
  if ! fetch_verify_extract; then
    fail 'proton: download, sha256sum -c and extract' 'fetch_verify_extract failed (its message is above)'
    return
  fi
  pass 'proton: download, sha256sum -c and extract'
  if build_complete "$COMPAT/$RT_TAG"; then
    pass 'proton: build complete'
  else
    fail 'proton: build complete' "$COMPAT/$RT_TAG lacks proton, compatibilitytool.vdf, version or files/"
  fi
  # the lib's validated delete: the 3 GB build is gone before the next section
  remove_compat_entry "$RT_TAG"
}

# webview2: the Evergreen installer through the lib, checked for the PE magic and deleted; never run.
live_webview2() {
  if ! fetch_webview2; then
    fail 'webview2: bootstrapper is a PE file' "download of $WV2_URL failed"
    return
  fi
  if is_magic "$WV2_FILE" 4d5a; then
    pass 'webview2: bootstrapper is a PE file'
  else
    fail 'webview2: bootstrapper is a PE file' "$WV2_URL did not serve a PE (MZ) file"
  fi
  rm -f -- "$WV2_FILE"
}

# launcher: latest.json through the lib, then each MSI source on its own, so a dead primary fails although latest.json's MSI passes.
# Only the file magic is checked; nothing downloaded is ever executed.
live_launcher() {
  if ! latest_launcher 30; then
    fail 'launcher: latest.json' "$L_ERR"
    return
  fi
  pass 'launcher: latest.json' "$L_LATEST"
  if curl_get "$LAUNCHER_MSI_API" "$TMP/msi" && is_magic "$TMP/msi" d0cf11e0a1b11ae1; then
    pass 'launcher: MSI from the update API'
  else
    fail 'launcher: MSI from the update API' "$LAUNCHER_MSI_API did not serve an MSI file"
  fi
  rm -f "$TMP/msi"
  if curl_get "$L_URL" "$TMP/msi" && is_magic "$TMP/msi" d0cf11e0a1b11ae1; then
    pass 'launcher: MSI from latest.json'
  else
    fail 'launcher: MSI from latest.json' "$L_URL did not serve an MSI file"
  fi
  rm -f "$TMP/msi"
}

# watch: watch_upstream's lines against tests/fixtures/upstream-state.txt. A "could not check" line is breakage, any other difference is
# news. Variables are tested with here-strings, never by piping into grep -q (an early-exiting reader can fail a pipeline under pipefail).
# Upstream text reaches the annotation only through the fixed reasons below, so it cannot form a workflow command.
live_watch() {
  local got want first
  RT_TAG=''
  resolve_release || RT_TAG=''   # without a tag watch_upstream prints its own could-not-check line
  got=$(watch_upstream "$RT_TAG" | sed -e '/^Upstream fix watch/d' -e '/GE code search/d' -e 's/^ *//')
  want=$(sed -e '/^#/d' -e '/^$/d' "$ROOT/tests/fixtures/upstream-state.txt")
  if grep -q 'could not check' <<< "$got"; then
    printf '#   %s\n' "${got//$'\n'/$'\n#   '}"
    first=$(grep -m1 'could not check' <<< "$got")
    fail 'watch: upstream state' "BROKEN, could not check: $first"
  elif [ "$got" != "$want" ]; then
    diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed 's/^/#   /'
    fail 'watch: upstream state' 'NEWS, upstream changed (diff above): act on it, then put the new lines in tests/fixtures/upstream-state.txt and the offline values in tests/live.sh'
  else
    pass 'watch: upstream state'
  fi
}

for s in "${WANT[@]}"; do "live_$s"; done

printf '# %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]
