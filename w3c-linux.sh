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

# The release tag is v plus this value; packaging/PKGBUILD pkgver must equal it (its check() and tests/phase7.sh compare them).
W3C_LINUX_VERSION=0.1.0
case "${1-}" in
  --version | -V | version) printf 'w3c-linux %s\n' "$W3C_LINUX_VERSION"; exit 0 ;;
esac

# The real path of this file (symlinks resolved) locates lib/ and share/. The one rule serves a clone, a symlink to it and the package's
# /usr/bin/w3c-linux symlink into /usr/lib/w3c-linux. SELF is also what the desktop entry's Exec names. No env or cwd override.
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

# usage: the version line, the subcommands and the first-run hint; printf only so it works with no coreutils on PATH.
usage() {
  local b=$C_BOLD g=$C_PASS r=$C_RESET
  printf '%s\n' "${b}w3c-linux $W3C_LINUX_VERSION${r}" \
    "${b}usage:${r} $BIN_NAME <subcommand>" \
    "  ${g}install${r}   set up the patched Proton and the Battle.net prefix" \
    "  ${g}launch${r}    start W3Champions" \
    "  ${g}update${r}    update the patched Proton" \
    "  ${g}doctor${r}    check the setup (read-only)" \
    "  ${g}revert${r}    switch Faugus back to its own runner" \
    "  ${g}monitor${r}   tally matches and hint the LAN-test NAT rule" \
    "  ${g}report${r}    print a bug report" \
    "  ${g}version${r}   print the version (also --version, -V)" \
    "New here? Run $BIN_NAME install once, then $BIN_NAME launch to play."
}

case "${1-}" in
  '' | help | -h | --help) usage; exit 0 ;;
  doctor) cmd_doctor; exit $? ;;
  install) cmd_install; exit $? ;;
  revert) cmd_revert; exit $? ;;
  update) cmd_update; exit $? ;;
  launch) cmd_launch; exit $? ;;
  monitor) cmd_monitor; exit $? ;;
  report) cmd_report; exit $? ;;
  *)
    printf 'unknown subcommand: %s\n' "$1" >&2
    usage >&2
    exit 2 ;;
esac
