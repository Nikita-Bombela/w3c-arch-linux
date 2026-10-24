#!/usr/bin/env bash
# Phase 23 fixture check (BACK-02): doctor and the launch command under the Faugus and the umu backend, on the healthy fixture tree and next to a
# Steam root with a Battle.net shortcut, against goldens recorded from the previous release tag's own script (tests/fixtures/v031-*.txt).
# Usage: bash tests/phase23.sh [GLOB]   (GLOB filters on display names such as snap-faugus-healthy-doctor)
# Re-record (a maintainer step; CI has no tags): extract the tag the v031 prefix names with `git archive <tag> | tar -x -C "$D"`, then
#   W3C_RECORD_SCRIPT="$D/w3c-linux.sh" bash tests/phase23.sh --record DIR
# and compare DIR with tests/fixtures. W3C_RECORD_SCRIPT is read only on the --record path, so no other run switches script.
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=phase18.sh
source "$(dirname "${BASH_SOURCE[0]}")/phase18.sh"

# this suite has its own cases only
mapfile -t P18_CASES < <(compgen -A function t_)
unset -f "${P18_CASES[@]}"

# phase18's FORBIDDEN lists umu-run, pgrep and pkill, which the launch snapshots run by design; steam proves a Faugus or umu launch never starts Steam
FORBIDDEN=(wine wineserver faugus-launcher sudo nft iptables notify-send steam)

# TAG_ADDITIONS: sed arguments --record applies to the tag's doctor output, one commented entry per deliberate post-tag addition with its
# decision ID (D-01). A new entry needs a prior decision that applies the change to every backend (D-04); anything else is a regression.
TAG_ADDITIONS=(
  # P22 D-06: the nat rule row, before the desktop entry row (the harness holds the boot marker)
  -e '/^warn  desktop entry/i pass  nat rule          applied this boot (w3c-linux)'
)

# ---------- helpers ----------

# snap_setup BACKEND SETUP: BACKEND faugus (the plain tree) or umu (the env override); SETUP healthy or steam (Steam root and Battle.net
# shortcut beside it, no backend file, so Steam is never selected).
snap_setup() {
  [ "$2" = steam ] && mk_steam
  [ "$1" = umu ] && ovr_env "$(pfx)" "$TAG"
  return 0
}

# snap_case BACKEND SETUP OUT: the case body, OUT doctor or launch.
snap_case() {
  snap_setup "$1" "$2"
  "snap_$3"
  rc_is 0
  golden_is "$GOLDEN_DIR/v031-$1-$2-$3.txt"
}

# record_goldens DIR: writes the goldens from the tag's script (SCRIPT), each only when its run was clean.
record_goldens() {
  local d=$1 b s o
  mkdir -p "$d"
  for b in faugus umu; do
    for s in healthy steam; do
      for o in doctor launch; do
        T=$(mktemp -d "$TMPROOT/c.XXXXXX")
        mk_tree "$T"
        CASE_ENV=() ERRS=() CHANGED=() ALLOW_EXTRA=()
        unset FEED
        snap_setup "$b" "$s"
        "snap_$o"
        if [ "${#ERRS[@]}" -ne 0 ] || [ "$RC" != 0 ]; then
          printf 'record %s-%s-%s: rc=%s errors: %s\n' "$b" "$s" "$o" "$RC" "${ERRS[*]}" >&2
          return 1
        fi
        case $o in
          doctor) printf '%s\n' "$SNAP" | sed "${TAG_ADDITIONS[@]}" > "$d/v031-$b-$s-$o.txt" ;;
          launch) printf '%s\n' "$SNAP" > "$d/v031-$b-$s-$o.txt" ;;
        esac
      done
    done
  done
}

# ---------- BACK-02: the snapshots ----------

t_snap_faugus_healthy_doctor() { snap_case faugus healthy doctor; }
t_snap_faugus_healthy_launch() { snap_case faugus healthy launch; }
t_snap_faugus_steam_doctor() { snap_case faugus steam doctor; }
t_snap_faugus_steam_launch() { snap_case faugus steam launch; }
t_snap_umu_healthy_doctor() { snap_case umu healthy doctor; }
t_snap_umu_healthy_launch() { snap_case umu healthy launch; }
t_snap_umu_steam_doctor() { snap_case umu steam doctor; }
t_snap_umu_steam_launch() { snap_case umu steam launch; }

# the Steam setups only mean something if the Steam tree is real: a broken mk_steam would make them silently equal the healthy ones
t_snap_steam_tree_guard() {
  mk_steam
  steam_on
  run "$T" doctor
  rc_is 0
  has_row pass 'steam root' ''
}

# ---------- D-07: the user-facing docs never name the design document ----------

# scope: README.md, CONTRIBUTING.md and docs/*.md; lib comments and two suites name the file legitimately
t_design_docs_pin() {
  local design f
  design=DESIGN.md
  for f in "$ROOT/README.md" "$ROOT/CONTRIBUTING.md" "$ROOT"/docs/*.md; do
    ! grep -qF -- "$design" "$f" || ERRS+=("${f#"$ROOT"/} names the design document")
  done
}

# ---------- main ----------

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case ${1-} in
    --record)
      SCRIPT=${W3C_RECORD_SCRIPT:?--record needs W3C_RECORD_SCRIPT, the tag\'s w3c-linux.sh}
      record_goldens "${2:?--record needs a directory}" ;;
    *) main "$@" ;;
  esac
fi
