#!/usr/bin/env bash
# w3c-linux.sh: run W3Champions inside Faugus's Battle.net prefix.
# doctor is read-only: it reads files plus one GET of latest.json to stdout; it never writes, lists processes, starts Wine or runs
# sudo. install downloads the patched Proton (curl, tar, sha256sum),
# switches Faugus's Battle.net runner in games.json, then runs installers inside the prefix only through Faugus's umu-run on the
# W3C build. revert switches the runner back. launch runs the W3Champions launcher inside Battle.net's container through
# Faugus's umu-run; when that container is absent it starts Battle.net first through `faugus-launcher --game battlenet`. The wrapper
# runs sudo only at the NAT step, in the foreground, after an explicit y and with exactly the command it printed (doctor never runs it).
# report is read-only like doctor and makes no network call: it prints a Markdown bug report for the maintainer.
# lib/ holds one file per subcommand plus the shared code; lib/w3c_helper.py holds the Python parsers.
set -u -o pipefail

# The real path of this file (symlinks resolved) locates lib/ and share/, so a symlink to w3c-linux.sh still finds them; SELF is also what the
# desktop entry's Exec names. No env or cwd override. Phase 7 changes only this rule.
SELF=$(realpath -- "${BASH_SOURCE[0]}")
LIB_DIR=${SELF%/*}/lib
SHARE_DIR=${SELF%/*}/share
HELPER=$LIB_DIR/w3c_helper.py
if [ ! -f "$HELPER" ]; then
  printf 'w3c-linux.sh: %s not found; keep the lib directory next to w3c-linux.sh\n' "$LIB_DIR" >&2
  exit 1
fi

# shellcheck source=SCRIPTDIR/lib/common.sh
. "$LIB_DIR/common.sh" || exit 1
# shellcheck source=SCRIPTDIR/lib/faugus.sh
. "$LIB_DIR/faugus.sh" || exit 1
# shellcheck source=SCRIPTDIR/lib/checks.sh
. "$LIB_DIR/checks.sh" || exit 1
# shellcheck source=SCRIPTDIR/lib/proton.sh
. "$LIB_DIR/proton.sh" || exit 1
# shellcheck source=SCRIPTDIR/lib/prefix.sh
. "$LIB_DIR/prefix.sh" || exit 1
# shellcheck source=SCRIPTDIR/lib/nat.sh
. "$LIB_DIR/nat.sh" || exit 1
# shellcheck source=SCRIPTDIR/lib/doctor.sh
. "$LIB_DIR/doctor.sh" || exit 1
# shellcheck source=SCRIPTDIR/lib/install.sh
. "$LIB_DIR/install.sh" || exit 1
# shellcheck source=SCRIPTDIR/lib/revert.sh
. "$LIB_DIR/revert.sh" || exit 1
# shellcheck source=SCRIPTDIR/lib/update.sh
. "$LIB_DIR/update.sh" || exit 1
# shellcheck source=SCRIPTDIR/lib/launch.sh
. "$LIB_DIR/launch.sh" || exit 1
# shellcheck source=SCRIPTDIR/lib/monitor.sh
. "$LIB_DIR/monitor.sh" || exit 1
# shellcheck source=SCRIPTDIR/lib/report.sh
. "$LIB_DIR/report.sh" || exit 1

[ -t 1 ] && [ "${1-}" != monitor ] && [ "${1-}" != report ] && banner

# printf, not cat: usage must work with nothing on PATH
usage() {
  local b=$C_BOLD g=$C_PASS r=$C_RESET
  printf '%s\n' "${b}usage:${r} w3c-linux.sh <subcommand>" '' \
    "  ${g}doctor${r}    read-only health check" \
    "  ${g}install${r}   guided setup from a working Faugus Battle.net to a playable W3Champions" \
    "  ${g}launch${r}    start W3Champions inside Battle.net's container; use it every session" \
    "  ${g}update${r}    check for a newer launcher and patched Proton, ask before installing either" \
    "  ${g}revert${r}    switch Faugus's Battle.net runner back" \
    "  ${g}monitor${r}   run the match monitor on its own" \
    "  ${g}report${r}    print a Markdown bug report (read-only, offline)" \
    '' \
    "${b}New here?${r} Run ${g}w3c-linux.sh install${r} once, then ${g}w3c-linux.sh launch${r} to play."
}

case "${1-}" in
  doctor) cmd_doctor; exit $? ;;
  install) cmd_install; exit $? ;;
  revert) cmd_revert; exit $? ;;
  update) cmd_update; exit $? ;;
  launch) cmd_launch; exit $? ;;
  monitor) cmd_monitor; exit $? ;;
  report) cmd_report; exit $? ;;
  ''|help|-h|--help) usage; exit 0 ;;
  *)
    printf 'unknown subcommand: %s\n' "$1" >&2
    usage >&2
    exit 2 ;;
esac
