#!/usr/bin/env bash
# Phase 8 check: runs tests/live.sh --offline against the fixtures it generates, with one fixture file replaced per negative case (the
# doctor and workflow cases are added by later plans), on the harness of tests/phase2.sh. Needs python3 and tar; no network.
# Usage: bash tests/phase8.sh [GLOB]   (GLOB filters on display names such as live-launcher-ok)
#   W3C_NIGHTLY_REAL_FAUGUS=1  doctor-* reads the installed Faugus package instead of the fixture one (needs faugus-launcher installed)
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=phase2.sh
source "$(dirname "${BASH_SOURCE[0]}")/phase2.sh"

# this suite has its own cases only
mapfile -t P2_CASES < <(compgen -A function t_)
unset -f "${P2_CASES[@]}"

LIVE_ENV=()   # a case that needs extra environment declares: local LIVE_ENV=(NAME=value ...)

# ---------- helpers ----------

# live_run ARGS...: tests/live.sh --offline ARGS with its fixtures in T/live (a case writes a file there to replace the default of that
# name); sets RC OUT ERR. The GitHub Actions variables are cleared because the nightly runs this suite: a negative case must not add an
# error annotation to its run page, and the token must not reach the script.
live_run() {
  mkdir -p "$T/live"
  env -u GITHUB_ACTIONS -u GITHUB_TOKEN -u W3C_LIVE_RELEASE_API W3C_LIVE_FIXTURES="$T/live" W3C_LIVE_CURL_LOG="$T/curl.log" TMPDIR="$T" \
    "${LIVE_ENV[@]}" "$BASH_BIN" "$ROOT/tests/live.sh" --offline "$@" > "$T/live.out" 2> "$T/live.err" < /dev/null
  RC=$?
  OUT=$(< "$T/live.out")
  ERR=$(< "$T/live.err")
}

# curl_log_has TEXT: the shim's log holds TEXT.
curl_log_has() { grep -qF -- "$1" "$T/curl.log" 2> /dev/null || ERRS+=("curl log lacks: $1"); }

# line_starts TEXT: some output line begins with TEXT ("ok - x" also occurs inside "not ok - x", so out_has cannot tell them apart).
line_starts() {
  local l
  while IFS= read -r l; do
    case $l in "$1"*) return 0 ;; esac
  done < "$T/live.out"
  ERRS+=("no output line starts with: $1")
}

# no_temp_left: live.sh removed its temp dir.
no_temp_left() { ! compgen -G "$T/w3c-live.*" > /dev/null || ERRS+=('the temp dir was left behind'); }

# write_release FILE TARBALL: a releases/latest document for GE-Proton11-7-W3C whose tarball asset is named TARBALL.
write_release() {
  local base=https://github.com/davex32/proton-ge-w3c/releases/download/GE-Proton11-7-W3C
  printf '{"tag_name": "GE-Proton11-7-W3C", "draft": false, "prerelease": false, "assets": [{"name": "%s", "size": 1088358492, "browser_download_url": "%s/%s"}, {"name": "SHA256SUMS", "size": 185, "browser_download_url": "%s/SHA256SUMS"}]}\n' \
    "$2" "$base" "$2" "$base" > "$1"
}

# ---------- launcher section ----------

t_live_launcher_ok() {
  live_run launcher
  rc_is 0
  out_has 'ok - launcher: latest.json (1.6.19)'
  out_has 'ok - launcher: MSI from the update API'
  out_has 'ok - launcher: MSI from latest.json'
  out_has '# 3 passed, 0 failed'
  curl_log_has 'https://update-service.w3champions.com/api/launcher-e'
  curl_log_has 'https://github.com/w3champions/launcher-e-release/releases/download/1.6.19/W3Champions_1.6.19_x64_en-US.msi'
  no_temp_left
}

t_live_launcher_no_version() {
  mkdir -p "$T/live"
  printf '%s\n' '{"platforms": {}}' > "$T/live/latest.json"
  live_run launcher
  rc_is 1
  out_has 'not ok - launcher: latest.json: unsafe or missing version'
}

t_live_launcher_primary_dead() {
  mkdir -p "$T/live"
  printf '%s\n' '<html>not found</html>' > "$T/live/launcher-e"
  live_run launcher
  rc_is 1
  out_has 'not ok - launcher: MSI from the update API'
  line_starts 'ok - launcher: MSI from latest.json'
}

t_live_usage() {
  live_run nosuch
  rc_is 2
  err_has 'usage: bash tests/live.sh'
}

# ---------- proton section ----------

t_live_proton_ok() {
  live_run proton
  rc_is 0
  out_has 'ok - proton: release JSON (GE-Proton11-7-W3C, 1.1 GB)'
  out_has 'ok - proton: download, sha256sum -c and extract'
  out_has 'ok - proton: build complete'
  out_has 'Verified: GE-Proton11-7-W3C.tar.gz: OK (sha256sum -c)'
  no_temp_left
}

t_live_proton_renamed_asset() {
  mkdir -p "$T/live"
  write_release "$T/live/release.json" GE-Proton11-7-W3C-x86_64.tar.gz
  live_run proton
  rc_is 1
  line_starts 'ok - proton: release JSON'
  out_has 'not ok - proton: download, sha256sum -c and extract'
}

t_live_release_api_seam() {
  local LIVE_ENV=(W3C_LIVE_RELEASE_API=https://api.github.com/repos/w3c-arch-linux-uat/does-not-exist/releases/latest)
  live_run proton
  rc_is 1
  out_has 'not ok - proton: release JSON: GitHub API unreachable or rate-limited'
  curl_log_has 'https://api.github.com/repos/w3c-arch-linux-uat/does-not-exist/releases/latest'
  ! grep -qF -- 'https://api.github.com/repos/davex32/' "$T/curl.log" 2> /dev/null || ERRS+=('the default release API was called')
}

# ---------- webview2 section ----------

t_live_webview2_ok() {
  live_run webview2
  rc_is 0
  out_has 'ok - webview2: bootstrapper is a PE file'
}

t_live_webview2_not_pe() {
  mkdir -p "$T/live"
  printf '%s\n' '<html>not found</html>' > "$T/live/webview2.exe"
  live_run webview2
  rc_is 1
  out_has 'not ok - webview2: bootstrapper is a PE file'
}

# ---------- watch section ----------

t_live_watch_ok() {
  live_run watch
  rc_is 0
  out_has 'ok - watch: upstream state'
}

t_live_watch_news() {
  mkdir -p "$T/live"
  printf '%s\n' '{"state": "open"}' > "$T/live/issue57.json"
  live_run watch
  rc_is 1
  out_has 'not ok - watch: upstream state: NEWS'
  out_has 'w3champions-issues #57 is open'
}

t_live_watch_broken() {
  mkdir -p "$T/live"
  printf '%s\n' '# no requests here' > "$T/live/protocol.def"
  live_run watch
  rc_is 1
  out_has 'not ok - watch: upstream state: BROKEN'
  out_has 'could not check Wine master'
}

# ---------- GitHub token ----------

# t_token_api_only: a token given to live.sh reaches api.github.com calls (as -H @file) and nothing else, and is never printed or logged.
t_token_api_only() {
  local LIVE_ENV=(GITHUB_TOKEN=w3c-live-sentinel-0b5e1d2c) l n=0 f
  live_run
  rc_is 0
  out_has '# GitHub API: authenticated with GITHUB_TOKEN'
  out_has '# 8 passed, 0 failed'
  for f in "$T/live.out" "$T/live.err" "$T/curl.log"; do
    ! grep -qF -- w3c-live-sentinel-0b5e1d2c "$f" 2> /dev/null || ERRS+=("the token appears in ${f##*/}")
  done
  while IFS= read -r l; do
    case $l in
      *https://api.github.com/*)
        n=$((n + 1))
        case $l in *' -H @'*) ;; *) ERRS+=("api.github.com call without the header file: $l") ;; esac ;;
      *' -H '*) ERRS+=("a header went to another host: $l") ;;
    esac
  done < "$T/curl.log"
  [ "$n" -ge 4 ] || ERRS+=("only $n api.github.com calls in the log")
}

t_token_absent_no_header() {
  live_run
  rc_is 0
  out_has '# GitHub API: unauthenticated (60 requests an hour per IP)'
  ! grep -qF -- ' -H ' "$T/curl.log" || ERRS+=('a curl call carried a header without a token')
}

# ---------- doctor ----------

# W3C_NIGHTLY_REAL_FAUGUS=1 is set by the nightly's doctor step after the AUR build, so a Faugus major-version change (the proxy for a
# games.json format change) turns that step red; locally it needs faugus-launcher installed. Otherwise the harness's fixture Faugus 2.4.2.
t_doctor_fixture_home() {
  local l
  [ "${W3C_NIGHTLY_REAL_FAUGUS:-}" != 1 ] || CASE_ENV=(W3C_FAUGUS_PY_DIR=)
  run "$T" doctor
  rc_is 0
  out_has 'pass  faugus version'
  while IFS= read -r l; do
    case $l in fail*) ERRS+=("doctor: $l") ;; esac
  done <<< "$OUT"
}

# ---------- nightly workflow ----------

# t_nightly_static: the structure and token scope of .github/workflows/nightly.yml (live checks and the install path; the suites are ci.yml's). The workflow is dev-repo only (D-01), so a tree without
# it skips. Comment lines are dropped first so prose cannot satisfy or trip a check.
# shellcheck disable=SC2016  # the ${{ }} texts are searched for, not expanded
t_nightly_static() {
  local f=$ROOT/.github/workflows/nightly.yml nc s n v
  if [ ! -f "$f" ]; then
    printf '# skip: no .github/workflows/nightly.yml (the public repo carries only release.yml)\n' >&2
    return 0
  fi
  nc=$(grep -v '^[[:space:]]*#' "$f")
  for s in "cron: '23 3 * * *'" 'workflow_dispatch:' 'container: archlinux:latest' 'shell: bash' 'contents: read' \
    'persist-credentials: false' 'pacman -Syu' 'grep -vx faugus-launcher' '--prefix="w3c-linux-$v/"'; do
    grep -qF -- "$s" <<< "$nc" || ERRS+=("workflow lacks: $s")
  done
  awk '/pacman -Syu/ && !p {p = NR} /actions\/checkout@/ && !c {c = NR} END {exit !(p && c && p < c)}' <<< "$nc" \
    || ERRS+=('pacman -Syu does not come before actions/checkout')
  # every GITHUB_TOKEN line belongs to a step named 'live: ..., and there are exactly two of the exact form
  v=$(awk '/^ *- name:/ {last = $0} /GITHUB_TOKEN/ && last !~ /\x27live:/ {print "GITHUB_TOKEN outside a live: step: " $0}' <<< "$nc")
  [ -z "$v" ] || ERRS+=("$v")
  n=$(grep -cF 'GITHUB_TOKEN: ${{ github.token }}' <<< "$nc")
  [ "$n" = 2 ] || ERRS+=("want 2 GITHUB_TOKEN env lines, got $n")
  n=$(grep -c 'GITHUB_TOKEN' <<< "$nc")
  [ "$n" = 2 ] || ERRS+=("GITHUB_TOKEN appears on $n lines, want 2")
  for s in 'secrets.' 'continue-on-error' 'actions/cache' 'always()' 'for f in tests/phase' 'w3c-arch-linux-$'; do
    ! grep -qF -- "$s" <<< "$nc" || ERRS+=("workflow has forbidden: $s")
  done
  n=$(grep -cF 'if: ${{ !cancelled() }}' <<< "$nc")
  [ "$n" -ge 8 ] || ERRS+=("want at least 8 !cancelled() conditions, got $n")
  for s in 'faugus-launcher AUR build' 'w3c-linux package build and install' 'doctor on fixture home' \
    "'live: proton release'" "'live: launcher latest.json and MSI'" "'live: WebView2'"; do
    grep -qF -- "- name: $s" <<< "$nc" || ERRS+=("step missing: $s")
  done
  [ "$(grep -F -- '- name:' <<< "$nc" | tail -n 1)" = "      - name: 'live: upstream watch (fails on news too)'" ] || ERRS+=('the last step is not the upstream watch')
  n=$(grep -c '^On Arch: `sudo pacman -S --needed ' "$ROOT/README.md")
  [ "$n" = 1 ] || ERRS+=("README.md has $n 'On Arch:' package lines, want 1")
}

# t_ci_static: .github/workflows/ci.yml runs `make check` (shellcheck plus the suites) once per matrix leg (tests/phase14.sh checks the legs) on
# pull requests into main (no push trigger: work goes through PRs), in a container with
# a reaping PID 1 (--init: without it the killed monitor tail stays a zombie that phase5/phase6's kill -0 still sees), and never touches
# the network checks or a token. Dev-repo only like the nightly, so a tree without it skips.
# shellcheck disable=SC2016 # the workflow's ${{ ... }} and $SUITES are matched as literal text
t_ci_static() {
  local f=$ROOT/.github/workflows/ci.yml nc s
  if [ ! -f "$f" ]; then
    printf '# skip: no .github/workflows/ci.yml (the public repo carries only release.yml)\n' >&2
    return 0
  fi
  nc=$(grep -v '^[[:space:]]*#' "$f")
  for s in 'pull_request:' 'branches: [main]' 'image: archlinux:latest' 'options: --init' 'shell: bash' 'contents: read' \
    'persist-credentials: false' 'pacman -Syu' 'SUITES: ${{ matrix.suites }}' 'make check SUITES="$SUITES"' 'grep -vx faugus-launcher' \
    'name: ${{ matrix.name }}' 'runuser -u builder'; do
    grep -qF -- "$s" <<< "$nc" || ERRS+=("ci workflow lacks: $s")
  done
  for s in 'push:' 'schedule:' 'tests/live.sh proton' 'tests/live.sh launcher' 'tests/live.sh webview2' 'tests/live.sh watch' 'GITHUB_TOKEN' \
    'secrets.' 'continue-on-error' 'always()' 'makepkg -si' 'for f in tests/phase[0-9]*.sh' 'for f in $SUITES' 'shellcheck -x'; do
    ! grep -qF -- "$s" <<< "$nc" || ERRS+=("ci workflow has forbidden: $s")
  done
  awk '/pacman -Syu/ && !p {p = NR} /actions\/checkout@/ && !c {c = NR} END {exit !(p && c && p < c)}' <<< "$nc" \
    || ERRS+=('ci: pacman -Syu does not come before actions/checkout')
}

# ---------- all sections ----------

t_live_offline_all() {
  live_run
  rc_is 0
  out_has 'ok - watch: upstream state'
  out_has '# 8 passed, 0 failed'
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
