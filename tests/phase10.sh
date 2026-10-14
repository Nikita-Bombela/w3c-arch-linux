#!/usr/bin/env bash
# Phase 10 fixture check, the v0.2 (BFaA) suite: the umu backend, the umu-run chain and the v0.1.1 snapshot of Faugus mode (UMU-06).
# It runs on the harness of tests/phase4.sh, so the same fake HOME, shims and invariants apply; no case runs a real Wine, umu or network call.
# Usage: bash tests/phase10.sh [GLOB]   (GLOB filters on display names such as umu-chain-env)
#        W3C_RECORD_SCRIPT=<v0.1.1 checkout>/w3c-linux.sh bash tests/phase10.sh --record DIR   (rewrites the two goldens in DIR)
# The doctor golden carries one row the v0.1.1 script predates, `install location` (Phase 11 D-07); --record inserts it, so a re-record from the
# tag still reproduces the committed golden.
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=phase4.sh
source "$(dirname "${BASH_SOURCE[0]}")/phase4.sh"

# this suite has its own cases only
mapfile -t P4_CASES < <(compgen -A function t_)
unset -f "${P4_CASES[@]}"

# umu-run, pkill and the launch client are expected here; the rest must never run
FORBIDDEN=(wine wineserver faugus-launcher sudo nft iptables notify-send)

# the record seam: W3C_RECORD_SCRIPT runs the v0.1.1 tag's script on this harness (run_cmd reads SCRIPT at call time)
SCRIPT=${W3C_RECORD_SCRIPT:-$SCRIPT}
GOLDEN_DIR=$ROOT/tests/fixtures

# ---------- helpers ----------

# line STATUS LABEL VALUE and has_line: one doctor row, matched as a whole line of OUT (the same pair as tests/phase1.sh).
line() { printf '%s  %-16s  %s' "$1" "$2" "$3"; }
has_line() {
  local want
  want=$(line "$1" "$2" "$3")
  grep -qxF -- "$want" <<< "$OUT" || ERRS+=("missing line: [$want]")
}

# norm: stdin to stdout with the fixture's temp path as @T@, the repo's real path as @ROOT@ and the APPID value (the md5 of the random prefix
# path) as @APPID@.
norm() {
  sed -e "s#$(realpath "$T")#@T@#g" -e "s#$T#@T@#g" -e "s#$(realpath "$ROOT")#@ROOT@#g" -E -e 's#^(pass  APPID +)[0-9a-f]{32}$#\1@APPID@#' -e 's#^(pass  version +w3c-linux ).*#\1@VERSION@#'
}

# snap_doctor and snap_launch: run the healthy l_setup tree and leave the normalised output in SNAP (called directly, never in $(...),
# so RC and ERRS survive).
snap_doctor() {
  l_setup
  run "$T" doctor
  SNAP=$(norm <<< "$OUT")
}
snap_launch() {
  l_setup
  go
  SNAP=$(env_call 1 | norm)
}

# record_goldens DIR: prepares each scenario's tree as main does, and writes the goldens only when the run was clean.
record_goldens() {
  local d=$1 fn
  mkdir -p "$d"
  for fn in doctor launch; do
    T=$(mktemp -d "$TMPROOT/c.XXXXXX")
    mk_tree "$T"
    CASE_ENV=() ERRS=() CHANGED=() ALLOW_EXTRA=()
    unset FEED
    "snap_$fn"
    if [ "${#ERRS[@]}" -ne 0 ] || [ "$RC" != 0 ]; then
      printf 'record %s: rc=%s errors: %s\n' "$fn" "$RC" "${ERRS[*]}" >&2
      return 1
    fi
    case $fn in
      # the v0.1.1 script predates the Phase 11 install location row: add it as line 2 so the golden matches the current doctor
      doctor) printf '%s\n' "$SNAP" | sed '1a pass  install location  @ROOT@ (clone)' > "$d/v0.1.1-doctor.txt" ;;
      launch) printf '%s\n' "$SNAP" > "$d/v0.1.1-launch-env.txt" ;;
    esac
  done
}

# golden_is FILE: SNAP equals the golden FILE; the error names the first differing lines.
golden_is() {
  local d
  [ -f "$1" ] || { ERRS+=("golden missing: $1"); return 0; }
  d=$(diff <(printf '%s\n' "$SNAP") "$1" | head -n 8)
  [ -z "$d" ] || ERRS+=("differs from ${1##*/}: $(tr '\n' '|' <<< "$d")")
}

# umu_stub FILE [MODE]: an executable umu-run stub that logs "$0 ARGS" to marks/umu-run and answers --version.
#   ok (default) prints the real format, garbage prints hello, fail prints the format and exits 1, hang sleeps 30 s.
umu_stub() {
  mkdir -p "${1%/*}"
  {
    printf '#!/bin/sh\n'
    cat <<'SH'
printf '%s\n' "$0 $*" >> "$MARK/umu-run"
[ "${1-}" = --version ] || exit 0
SH
    case ${2:-ok} in
      ok) printf '%s\n' "echo 'umu-launcher version 1.4.4 (3.14.7 (main))'" ;;
      garbage) printf '%s\n' 'echo hello' ;;
      fail) printf '%s\n' "echo 'umu-launcher version 1.4.4 (3.14.7 (main))'" 'exit 1' ;;
      hang) printf '%s\n' 'exec sleep 30' ;;
    esac
  } > "$1"
  chmod +x "$1"
}

# no_bundled: Faugus has not downloaded umu-run (version.txt stays, to show it is not read for another copy).
no_bundled() { rm "$T/home/.local/share/faugus-launcher/umu-run"; }

# values_are LABEL VALUE...: the values of OUT's rows with that label are exactly these, in order (as in tests/phase1.sh).
values_are() {
  local want=$1 ln lab got=() i
  shift
  while IFS= read -r ln; do
    lab=${ln:6:16}
    lab=${lab%"${lab##*[![:space:]]}"}
    [ "$lab" = "$want" ] && got+=("${ln:24}")
  done <<< "$OUT"
  if [ "${#got[@]}" -ne "$#" ]; then
    ERRS+=("values of $want: want $# got ${#got[@]} [${got[*]-}]")
    return 0
  fi
  for ((i = 0; i < $#; i++)); do
    [ "${got[i]}" = "${*:i+1:1}" ] || ERRS+=("value $i of $want: want [${*:i+1:1}] got [${got[i]}]")
  done
}

# SKIPF: the reason every Faugus-only row carries in the umu backend.
SKIPF='needs: Faugus (backend: umu)'

# ovr_env PREFIX RUNNER: the env override for the next run (appended to CASE_ENV).
ovr_env() { CASE_ENV+=("W3C_PREFIX=$1" "W3C_PROTON=$2"); }

# labels: stdin rows to their labels (characters 7 to 22, trailing spaces trimmed, consecutive repeats collapsed).
labels() {
  local ln lab last=''
  while IFS= read -r ln; do
    lab=${ln:6:16}
    lab=${lab%"${lab##*[![:space:]]}"}
    [ "$lab" = "$last" ] || printf '%s\n' "$lab"
    last=$lab
  done
}

# no_games: the tree has no Faugus games.json (Faugus's games list is absent, not just unused).
no_games() { rm "$T/home/.local/share/faugus-launcher/games.json"; }

# ---------- UMU-06: the v0.1.1 snapshot ----------

t_snapshot_doctor() {
  snap_doctor
  rc_is 0
  golden_is "$GOLDEN_DIR/v0.1.1-doctor.txt"
}

t_snapshot_launch_env() {
  snap_launch
  rc_is 0
  golden_is "$GOLDEN_DIR/v0.1.1-launch-env.txt"
}

# ---------- UMU-01: the umu-run chain (doctor on the plain tree) ----------

# the bundled copy wins over both a UMU_RUN and a PATH umu-run, and its row keeps the bare v0.1.1 text
t_umu_chain_bundled_wins() {
  umu_stub "$T/bin/umu-run"
  umu_stub "$T/opt dir/umu-run"
  CASE_ENV=("UMU_RUN=$T/opt dir/umu-run")
  run "$T" doctor
  rc_is 0
  has_line pass umu-run "$T/home/.local/share/faugus-launcher/umu-run"
  has_line pass 'umu version' 1.4.4-patch
}

# a path with a space is used and shown verbatim
t_umu_chain_env() {
  no_bundled
  umu_stub "$T/opt dir/umu-run"
  CASE_ENV=("UMU_RUN=$T/opt dir/umu-run")
  run "$T" doctor
  rc_is 0
  has_line pass umu-run "$T/opt dir/umu-run (UMU_RUN)"
}

# a UMU_RUN that is missing fails the row, naming it, even when a PATH umu-run exists (D-02)
t_umu_chain_env_bad() {
  no_bundled
  umu_stub "$T/bin/umu-run"
  CASE_ENV=("UMU_RUN=$T/nope")
  run "$T" doctor
  rc_is 1
  has_line fail umu-run "UMU_RUN is set to $T/nope, which is missing or not executable: fix it or unset UMU_RUN"
  has_line skip 'umu version' 'needs: umu-run'
}

# an empty UMU_RUN is unset
t_umu_chain_env_empty() {
  no_bundled
  umu_stub "$T/bin/umu-run"
  CASE_ENV=(UMU_RUN=)
  run "$T" doctor
  rc_is 0
  has_line pass umu-run "$T/bin/umu-run (PATH)"
}

t_umu_chain_path() {
  no_bundled
  umu_stub "$T/bin/umu-run"
  run "$T" doctor
  rc_is 0
  has_line pass umu-run "$T/bin/umu-run (PATH)"
}

t_umu_chain_sysroot() {
  no_bundled
  umu_stub "$T/sysroot/usr/share/umu/umu-run"
  run "$T" doctor
  rc_is 0
  has_line pass umu-run "$T/sysroot/usr/share/umu/umu-run (/usr/share/umu)"
}

t_umu_chain_none() {
  no_bundled
  run "$T" doctor
  rc_is 1
  has_line fail umu-run 'Launch any game once in Faugus so it downloads umu-run, or install umu-launcher or set UMU_RUN to its path'
  has_line skip 'umu version' 'needs: umu-run'
}

# ---------- UMU-02: the umu version ----------

# umu_marks: the number of calls the umu-run stubs logged.
umu_marks() { grep -c . "$T/marks/umu-run" 2> /dev/null || true; }

# the version of a non-bundled umu-run comes from one bounded `--version` call
t_umu_version_binary() {
  no_bundled
  umu_stub "$T/bin/umu-run"
  add_link "$T" timeout
  run "$T" doctor
  rc_is 0
  has_line pass 'umu version' 1.4.4
  [ "$(umu_marks)" = 1 ] || ERRS+=("umu-run calls: want 1 got $(umu_marks)")
  case $(cat "$T/marks/umu-run" 2> /dev/null) in *' --version') ;; *) ERRS+=('the umu-run call did not end with --version') ;; esac
}

# a bundled copy without version.txt is asked too
t_umu_version_bundled_no_txt() {
  umu_stub "$T/home/.local/share/faugus-launcher/umu-run"
  rm "$T/home/.local/share/faugus-launcher/version.txt"
  add_link "$T" timeout
  run "$T" doctor
  rc_is 0
  has_line pass 'umu version' 1.4.4
}

# version.txt wins for the bundled copy and umu-run is not run
t_umu_version_txt_wins() {
  add_link "$T" timeout
  run "$T" doctor
  rc_is 0
  has_line pass 'umu version' 1.4.4-patch
  [ ! -e "$T/marks/umu-run" ] || ERRS+=('umu-run ran although version.txt applies')
}

t_umu_version_garbage() {
  no_bundled
  umu_stub "$T/bin/umu-run" garbage
  add_link "$T" timeout
  run "$T" doctor
  rc_is 0
  has_line warn 'umu version' unknown
}

t_umu_version_fail() {
  no_bundled
  umu_stub "$T/bin/umu-run" fail
  add_link "$T" timeout
  run "$T" doctor
  rc_is 0
  has_line warn 'umu version' unknown
}

# a hang is killed at 5 s and shows unknown
t_umu_version_hang() {
  no_bundled
  umu_stub "$T/bin/umu-run" hang
  add_link "$T" timeout
  run "$T" doctor
  rc_is 0
  has_line warn 'umu version' unknown
}

# no timeout on PATH: umu-run is not run at all
t_umu_version_no_timeout() {
  no_bundled
  umu_stub "$T/bin/umu-run"
  run "$T" doctor
  rc_is 0
  has_line warn 'umu version' unknown
  [ ! -e "$T/marks/umu-run" ] || ERRS+=('umu-run ran without timeout')
}

# ---------- UMU-03: the env override (W3C_PREFIX + W3C_PROTON) ----------

# no games.json: doctor passes, names the override, skips the Faugus rows, and keeps the v0.1.1 label order with `backend` in the slot
t_override_doctor() {
  local want got l
  no_games
  mk_installed "$T"
  seed_tag "$T" "$TAG"
  ovr_env "$(pfx)" "$TAG"
  run "$T" doctor
  rc_is 0
  has_line pass backend "umu: prefix and runner from W3C_PREFIX and W3C_PROTON; Faugus's games.json is not read or written"
  for l in games.json battlenet launch_arguments path config.json envar.json 'faugus env'; do has_line skip "$l" "$SKIPF"; done
  has_line pass prefix "$(pfx)"
  has_line pass runner "$TAG"
  has_line pass 'runner build' "$TAG"
  values_are 'launch env' WINE_SIMULATE_WRITECOPY=1 PROTON_ENABLE_WAYLAND=0
  lacks_text 'faugus version'
  want=$(labels < "$GOLDEN_DIR/v0.1.1-doctor.txt" | sed 's/^faugus version$/backend/')
  got=$(labels <<< "$OUT")
  [ "$want" = "$got" ] || ERRS+=("label order differs: $(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | head -n 6 | tr '\n' '|')")
}

# adjacency (D-10): a Faugus entry on another runner loses to the override, and games.json is not touched
t_override_wins_gamesjson() {
  local p
  mk_installed "$T"
  seed_tag "$T" "$TAG"
  ovr_env "$(pfx)" "$TAG"
  run "$T" doctor
  rc_is 0
  has_line pass runner "$TAG"
  has_line pass backend "umu: prefix and runner from W3C_PREFIX and W3C_PROTON; Faugus's games.json is not read or written"
  for p in "${CHANGED[@]}"; do
    case $p in *games.json*) ERRS+=("games.json changed: $p") ;; esac
  done
  unchanged_games
}

# the invariant: the umu backend on the Faugus fixture's prefix and runner builds exactly the v0.1.1 launch argv
t_override_launch_argv() {
  l_setup
  ovr_env "$(pfx)" "$TAG"
  go
  rc_is 0
  SNAP=$(env_call 1 | norm)
  golden_is "$GOLDEN_DIR/v0.1.1-launch-env.txt"
  [ ! -e "$T/marks/faugus-launcher" ] || ERRS+=('faugus-launcher ran')
  unchanged_games
}

# D-07: exactly one of the two variables stops every command with status 2 before anything changes
t_override_one_var() {
  local c v
  for c in doctor install update revert launch monitor report; do
    for v in W3C_PREFIX W3C_PROTON; do
      CASE_ENV=("$v=$T/x")
      run "$T" "$c"
      [ "$RC" = 2 ] || ERRS+=("$c with only $v: exit want 2 got $RC")
      case $ERR in *'set both W3C_PREFIX and W3C_PROTON, or neither'*) ;; *) ERRS+=("$c with only $v: no D-07 text") ;; esac
      changed_is
    done
  done
}

# both set to the empty string behave as unset
t_override_empty_pair() {
  ovr_env '' ''
  run "$T" doctor
  rc_is 0
  has_line pass 'faugus version' 2.4.2
}

# D-11: a prefix without drive_c fails its row, the derived rows skip, and nothing is created
t_override_no_drive_c() {
  mkdir -p "$T/home/empty"
  ovr_env "$T/home/empty" "$TAG"
  run "$T" doctor
  rc_is 1
  has_line fail prefix "not a Wine prefix (no drive_c): $(realpath "$T/home/empty"); set W3C_PREFIX or run w3c-linux.sh backend set umu PREFIX RUNNER with your existing Battle.net prefix"
  has_line skip PREFIX 'needs: prefix'
  has_line skip APPID 'needs: prefix'
  has_line skip W3C_EXE 'needs: prefix'
  changed_is
}

# D-15: a launch env variable the user already exported is not added again (it reaches umu through the environment)
t_override_env_inherited() {
  ovr_env "$(pfx)" "$TAG"
  CASE_ENV+=(WINE_SIMULATE_WRITECOPY=0)
  run "$T" doctor
  rc_is 0
  values_are 'launch env' PROTON_ENABLE_WAYLAND=0
  CASE_ENV+=(PROTON_ENABLE_WAYLAND=1)
  run "$T" doctor
  values_are 'launch env' '(none)'
}

# ---------- Phase 10 D-08, D-09: the runner as a name or a path, the W3C guard, umu-mode wording ----------

# a runner given as the full compatibilitytools.d path of the recorded build counts as that build
t_override_path_runner() {
  local d
  d=$(realpath "$T/home/.local/share/Steam/compatibilitytools.d")/$TAG
  mk_installed "$T"
  seed_tag "$T" "$TAG"
  ovr_env "$(pfx)" "$d"
  run "$T" doctor
  rc_is 0
  has_line pass 'runner build' "$TAG"
  has_line pass 'runner dir' "$d"
}

# a build outside compatibilitytools.d (a path with a space) is found by doctor
t_override_path_outside_doctor() {
  local d
  d="$(realpath "$T")/opt dir/$TAG"
  fill_build "$d" "$TAG"
  seed_tag "$T" "$TAG"
  ovr_env "$(pfx)" "$d"
  run "$T" doctor
  rc_is 0
  has_line pass 'runner dir' "$d"
}

# the same build reaches PROTONPATH, and the launch raises no non-W3C warning for it
t_override_path_outside_launch() {
  local d
  d="$(realpath "$T")/opt dir/$TAG"
  l_setup
  fill_build "$d" "$TAG"
  ovr_env "$(pfx)" "$d"
  go
  rc_is 0
  env_call 1 | grep -qxF -- "PROTONPATH=$d" || ERRS+=("PROTONPATH is not $d")
  lacks_text 'not an installed W3C build'
}

# D-09: a non-W3C override runner gets the same VerifyJob warning as a non-W3C Faugus runner
t_override_not_w3c() {
  l_setup
  ovr_env "$(pfx)" 'Proton-GE Latest'
  go
  rc_is 0
  out_has "Battle.net runs on Proton-GE Latest, not an installed W3C build: the launcher's VerifyJob check will fail"
}

t_override_runner_missing() {
  ovr_env "$(pfx)" GE-Proton10-1
  run "$T" doctor
  rc_is 0
  has_line warn 'runner dir' "missing: $T/home/.local/share/Steam/compatibilitytools.d/GE-Proton10-1: run w3c-linux.sh install"
}

# umu-mode rows no longer send the user to Faugus
t_override_wording() {
  rm "$T/home/.local/share/umu/steamrt4/pressure-vessel/bin/steam-runtime-launch-client"
  ovr_env "$(pfx)" "$TAG"
  run "$T" doctor
  rc_is 0
  has_line warn launch-client "absent: $T/home/.local/share/umu/steamrt4/pressure-vessel/bin/steam-runtime-launch-client (umu downloads it the first time it starts Battle.net: run w3c-linux.sh launch)"
  has_line warn 'prefix version' 'absent: start Battle.net once with w3c-linux.sh launch'
  has_line skip 'prefix runner' 'needs: config_info (start Battle.net once with w3c-linux.sh launch)'
}

# ---------- UMU-07: backend set / show / clear and the saved file (D-17 to D-19) ----------

# BF: the saved backend file of this case's fake HOME; bf_allow: the paths a case that writes it may create.
BF() { printf '%s' "$T/home/.config/w3c-linux/backend"; }
bf_allow() { ALLOW_EXTRA+=(home/.config home/.config/w3c-linux home/.config/w3c-linux/backend); }
# bf_put LINE...: a hand-made backend file, one line per argument.
bf_put() {
  mkdir -p "$T/home/.config/w3c-linux"
  printf '%s\n' "$@" > "$(BF)"
}

# set, doctor with no env vars, show, clear, show again
t_backend_set_doctor() {
  local bf want
  bf=$(BF)
  bf_allow
  no_games
  mk_installed "$T"
  seed_tag "$T" "$TAG"
  run "$T" backend set umu "$(pfx)" "$TAG"
  rc_is 0
  out_has "Saved the umu backend in $bf: prefix $(pfx), runner $TAG. Next: w3c-linux.sh doctor"
  want=$(printf 'BACKEND=umu\nPREFIX=%s\nRUNNER=%s' "$(pfx)" "$TAG")
  [ "$(cat "$bf")" = "$want" ] || ERRS+=("file content: $(tr '\n' '|' < "$bf")")
  run "$T" doctor
  rc_is 0
  has_line pass backend "umu: prefix and runner from $bf; Faugus's games.json is not read or written"
  has_line pass prefix "$(pfx)"
  has_line pass runner "$TAG"
  run "$T" backend show
  rc_is 0
  [ "$OUT" = "$(printf 'backend: umu (from %s)\nprefix: %s\nrunner: %s' "$bf" "$(pfx)" "$TAG")" ] || ERRS+=("show: $OUT")
  run "$T" backend clear
  rc_is 0
  [ ! -e "$bf" ] || ERRS+=('file still there after clear')
  run "$T" backend show
  rc_is 0
  out_has 'backend: faugus (W3C_PREFIX and W3C_PROTON are unset and '"$bf"' does not exist)'
}

# D-18: a prefix without drive_c is refused, nothing is saved or created; the runner is not checked
t_backend_refuses_non_prefix() {
  run "$T" backend set umu "$T/home/nope" "$TAG"
  rc_is 1
  err_has "$(realpath -m "$T/home/nope") is not a Wine prefix (no drive_c)"
  err_has 'Nothing was saved'
  changed_is
  [ ! -e "$(BF)" ] || ERRS+=('file was written')
}

# D-06: the env vars win over the file; the row names them and show says the file is ignored
t_backend_env_wins() {
  local bf b
  bf=$(BF)
  mk_installed "$T"
  seed_tag "$T" "$TAG"
  mkdir -p "$T/home/B/drive_c"
  b=$(realpath "$T/home/B")
  bf_put BACKEND=umu "PREFIX=$(pfx)" "RUNNER=$TAG"
  ovr_env "$b" "$TAG"
  run "$T" doctor
  # B is a bare prefix, so other rows fail; only the source rows matter here
  has_line pass prefix "$b"
  has_line pass backend "umu: prefix and runner from W3C_PREFIX and W3C_PROTON; Faugus's games.json is not read or written"
  run "$T" backend show
  rc_is 0
  out_has "backend: umu (from W3C_PREFIX and W3C_PROTON)"
  out_has "$bf is ignored while W3C_PREFIX and W3C_PROTON are set"
}

# D-19: the file is data; a command substitution in a value runs nothing and is shown literally
t_backend_not_sourced() {
  # shellcheck disable=SC2016 # the value must reach the file literally
  bf_put BACKEND=umu "PREFIX=$(pfx)" 'RUNNER=$(printf x > "$HOME/pwned")'
  run "$T" doctor
  # shellcheck disable=SC2016 # literal text, not an expansion
  out_has '$(printf x > "$HOME/pwned")'
  [ ! -e "$T/home/pwned" ] || ERRS+=('the value was executed')
}

# a directory at the backend path is a malformed file, not an absent one, and clear says when it cannot remove it (WR-03)
t_backend_not_a_file() {
  local bf
  bf=$(BF)
  mkdir -p "$bf"
  run "$T" doctor
  rc_is 2
  err_has "$bf is not a valid umu backend file"
  run "$T" backend clear
  rc_is 1
  err_has "backend: cannot remove $bf"
  lacks_text 'Removed'
}

# a present but malformed file is a hard error; set and clear still work on it
t_backend_malformed() {
  local bf
  bf=$(BF)
  bf_allow
  bf_put BACKEND=umu
  run "$T" doctor
  rc_is 2
  err_has "$bf is not a valid umu backend file"
  err_has 'w3c-linux.sh backend clear'
  run "$T" backend show
  rc_is 2
  err_has "$bf"
  run "$T" backend clear
  rc_is 0
  [ ! -e "$bf" ] || ERRS+=('file still there after clear')
  run "$T" doctor
  rc_is 0
  has_line pass 'faugus version' 2.4.2
}

# the same arguments twice give a byte-identical file; clear twice is fine
t_backend_idempotent() {
  local a b
  bf_allow
  run "$T" backend set umu "$(pfx)" "$TAG"
  rc_is 0
  a=$(sha256sum < "$(BF)")
  run "$T" backend set umu "$(pfx)" "$TAG"
  rc_is 0
  b=$(sha256sum < "$(BF)")
  [ "$a" = "$b" ] || ERRS+=('the file changed on the second set')
  run "$T" backend clear
  rc_is 0
  run "$T" backend clear
  rc_is 0
  out_has 'Nothing to clear'
}

# any key order, unknown keys ignored, the last line of a repeated key wins
t_backend_keys_order() {
  mk_installed "$T"
  seed_tag "$T" "$TAG"
  bf_put RUNNER=x "PREFIX=$(pfx)" junk=1 BACKEND=umu "RUNNER=$TAG"
  run "$T" doctor
  rc_is 0
  has_line pass runner "$TAG"
}

t_backend_usage() {
  run "$T" backend
  rc_is 2
  run "$T" backend set umu only-one
  rc_is 2
  run "$T" backend set lutris a b
  rc_is 2
  err_has 'only umu is supported'
  run "$T" backend set umu "$(pfx)" $'a\nb'
  rc_is 2
  run "$T" backend set umu "$(pfx)" ''
  rc_is 2
  changed_is
  [ ! -e "$(BF)" ] || ERRS+=('file was written')
}

t_backend_one_var() {
  local v
  for v in W3C_PREFIX W3C_PROTON; do
    CASE_ENV=("$v=$T/x")
    run "$T" backend set umu "$(pfx)" "$TAG"
    rc_is 2
    err_has 'set both W3C_PREFIX and W3C_PROTON, or neither'
    changed_is
  done
}

# no temp file is left beside the saved file
t_backend_atomic() {
  local f
  bf_allow
  run "$T" backend set umu "$(pfx)" "$TAG"
  rc_is 0
  for f in "$T"/home/.config/w3c-linux/.backend.*; do
    [ ! -e "$f" ] || ERRS+=("temp file left: $f")
  done
}

# D-21: help names the backend subcommand and the environment variables
t_backend_help() {
  local v
  run "$T" help
  rc_is 0
  for v in W3C_PREFIX W3C_PROTON UMU_RUN 'backend set umu PREFIX RUNNER' 'New here?'; do out_has "$v"; done
  case $OUT in "w3c-linux "*) ;; *) ERRS+=('help does not start with the version line') ;; esac
}

# D-21: with no Faugus games.json the row also names the second route
t_backend_no_faugus_row() {
  rm -rf "${T:?}/home"
  mkdir "$T/home"
  run "$T" doctor
  rc_is 1
  has_line fail games.json 'Install Faugus and add Battle.net (Add game -> Battle.net), or use an existing prefix: w3c-linux.sh backend set umu PREFIX RUNNER'
}

# ---------- UMU-04, D-12, D-13: install in the umu backend ----------

# games_untouched: nothing under Faugus's data directory changed and no games.json backup was made.
games_untouched() {
  local p
  for p in "${CHANGED[@]}"; do
    case $p in home/.local/share/faugus-launcher | home/.local/share/faugus-launcher/*) ERRS+=("Faugus data touched: $p") ;; esac
  done
  ! compgen -G "$T/home/.local/state/w3c-linux/games.json.*.bak" > /dev/null || ERRS+=('a games.json backup exists')
  return 0
}

# bf_is RUNNER: the saved backend file is exactly the three lines for the fixture prefix and RUNNER.
bf_is() {
  local want
  want=$(printf 'BACKEND=umu\nPREFIX=%s\nRUNNER=%s' "$(pfx)" "$1")
  [ "$(cat "$(BF)" 2> /dev/null)" = "$want" ] || ERRS+=("backend file: $(tr '\n' '|' < "$(BF)" 2> /dev/null)")
}

# the umu source line, the build installed and recorded, the W3C_PROTON line printed, no switch question, Faugus untouched
t_ovr_install_env() {
  local c=$T/$COMPAT_REL
  mk_release "$T"
  ovr_env "$(pfx)" GE-Proton10-1
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 0
  out_has "umu: prefix and runner from W3C_PREFIX and W3C_PROTON; Faugus's games.json is not read or written"
  out_has "Set W3C_PROTON=$TAG (it is GE-Proton10-1 now), then rerun w3c-linux.sh install"
  lacks_text 'Saved runner'
  case $ERR in *"Switch Faugus's"*) ERRS+=('a switch question was asked') ;; esac
  build_ok "$c/$TAG"
  tag_is "$TAG"
  games_untouched
  no_umu
}

# file origin: RUNNER is rewritten, PREFIX stays, and the run stops with the rerun line
t_ovr_install_file() {
  local c=$T/$COMPAT_REL
  mk_release "$T"
  bf_allow
  bf_put BACKEND=umu "PREFIX=$(pfx)" RUNNER=GE-Proton10-1
  FEED=$'y\ny\ny\n'
  run "$T" install
  rc_is 0
  err_has "Use $TAG as the umu backend's runner (now GE-Proton10-1)?"
  out_has "Saved runner $TAG in $(BF)"
  out_has "Rerun w3c-linux.sh install to set up the prefix on $TAG."
  lacks_text 'Install complete'
  case $ERR in *"Switch Faugus's"*) ERRS+=('a switch question was asked') ;; esac
  bf_is "$TAG"
  build_ok "$c/$TAG"
  tag_is "$TAG"
  games_untouched
  no_umu
}

# the first run saves the tag, the second runs on it, a third changes no byte of the file
t_ovr_install_twice() {
  local a b
  mk_release "$T"
  bf_allow
  bf_put BACKEND=umu "PREFIX=$(pfx)" RUNNER=GE-Proton10-1
  FEED=$'y\ny\ny\n'
  run "$T" install
  rc_is 0
  FEED=$'y\n'
  run "$T" install
  rc_is 0
  out_has "already $TAG"
  out_has "Install complete: Battle.net runs on $TAG"
  games_untouched
  a=$(sha256sum < "$(BF)")
  run "$T" install
  rc_is 0
  b=$(sha256sum < "$(BF)")
  [ "$a" = "$b" ] || ERRS+=('the file changed on the third run')
  bf_is "$TAG"
}

# the override runner is already the tag: no Set or Saved line, the in-prefix steps carry on
t_ovr_install_on_tag() {
  mk_installed "$T"
  seed_tag "$T" "$TAG"
  ovr_env "$(pfx)" "$TAG"
  FEED=$'y\n'
  run "$T" install
  rc_is 0
  out_has "already $TAG"
  out_has 'Install complete'
  lacks_text 'Set W3C_PROTON'
  lacks_text 'Saved runner'
  games_untouched
}

# file origin, the runner question answered No: the saved runner stays (WR-02)
t_ovr_install_file_decline() {
  mk_release "$T"
  bf_allow
  bf_put BACKEND=umu "PREFIX=$(pfx)" RUNNER=GE-Proton10-1
  FEED=$'y\ny\nn\n'
  run "$T" install
  rc_is 0
  out_has 'Runner not changed; rerun install when ready.'
  lacks_text 'Saved runner'
  bf_is GE-Proton10-1
  games_untouched
}

# in-prefix steps run in the override prefix once the runner is the W3C build
t_ovr_install_msi() {
  msi_setup
  ovr_env "$(pfx)" "$TAG"
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 0
  umu_count 1
  umu_env_has "WINEPREFIX=$(pfx)"
  umu_env_has "PROTONPATH=$T/$COMPAT_REL/$TAG"
  [ "$(launcher_rec)" = 1.6.16 ] || ERRS+=("launcher-version holds: $(launcher_rec)")
  games_untouched
}

# update: the newer build is installed and recorded; env origin prints the W3C_PROTON line and stops before msiexec (RESEARCH Pitfall 6)
t_ovr_install_update_env() {
  newer_both
  ovr_env "$(pfx)" "$TAG"
  FEED=$'y\ny\n'
  run "$T" update
  rc_is 0
  err_has "Install $T8 (about 1.1 GB) and use it for the umu backend? $TAG stays installed."
  case $ERR in *"Switch Faugus's"*) ERRS+=('a switch question was asked') ;; esac
  out_has "umu: prefix and runner from W3C_PREFIX and W3C_PROTON; Faugus's games.json is not read or written"
  out_has "Recorded $T8; the previous W3C build $TAG stays installed"
  lacks_text 'revert switches back'
  out_has "Set W3C_PROTON=$T8 (it is $TAG now), then rerun w3c-linux.sh update"
  lacks_text 'Update finished.'
  tag_is "$T8"
  prev_is "$TAG"
  build_ok "$T/$COMPAT_REL/$T8"
  no_umu
  [ "$(launcher_rec)" = 1.6.16 ] || ERRS+=("launcher-version holds: $(launcher_rec)")
  games_untouched
}

# update, file origin: RUNNER is rewritten before msiexec, which runs on the new build
t_ovr_install_update_file() {
  newer_both
  bf_allow
  bf_put BACKEND=umu "PREFIX=$(pfx)" "RUNNER=$TAG"
  FEED=$'y\ny\n'
  run "$T" update
  rc_is 0
  out_has "Saved runner $T8 in $(BF)"
  bf_is "$T8"
  tag_is "$T8"
  umu_count 1
  umu_env_has "PROTONPATH=$T/$COMPAT_REL/$T8"
  umu_env_has "WINEPREFIX=$(pfx)"
  [ "$(launcher_rec)" = 1.6.17 ] || ERRS+=("launcher-version holds: $(launcher_rec)")
  out_has 'Update finished.'
  games_untouched
}

# update, file origin, the backend file cannot be written: the tag is not recorded, so a rerun offers the update again (WR-01)
t_ovr_install_update_file_unwritable() {
  newer_both
  bf_allow
  bf_put BACKEND=umu "PREFIX=$(pfx)" "RUNNER=$TAG"
  chmod a-w "$T/home/.config/w3c-linux"
  FEED=$'y\ny\n'
  run "$T" update
  chmod u+w "$T/home/.config/w3c-linux"
  rc_is 1
  out_has "update: cannot write $(BF); rerun w3c-linux.sh update"
  lacks_text 'Update finished.'
  tag_is "$TAG"
  bf_is "$TAG"
  no_umu
}

# nothing newer: no write at all
t_ovr_install_update_current() {
  local a b
  mk_release "$T"
  on_w3c "$T"
  bf_put BACKEND=umu "PREFIX=$(pfx)" "RUNNER=$TAG"
  a=$(sha256sum < "$(BF)")
  run "$T" update
  rc_is 0
  out_has "patched Proton $TAG up to date"
  b=$(sha256sum < "$(BF)")
  [ "$a" = "$b" ] || ERRS+=('the backend file changed')
  no_umu
  games_untouched
}

# D-14: one line, exit 0, nothing changed
t_ovr_install_revert() {
  ovr_env "$(pfx)" "$TAG"
  run "$T" revert
  rc_is 0
  [ "$OUT" = 'revert: the umu backend has no Faugus runner to switch back; nothing to revert (set W3C_PROTON or run w3c-linux.sh backend set umu PREFIX RUNNER to change its runner)' ] || ERRS+=("revert output: $OUT")
  changed_is
}

# D-10: a running Faugus does not block the in-prefix steps of the umu backend
t_ovr_install_idle() {
  msi_setup
  add_proc "$T" 300 python3 'python3 -m faugus.tray_only'
  ovr_env "$(pfx)" "$TAG"
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 0
  case $ERR in *'Still running'*) ERRS+=('Faugus counted as running') ;; esac
  umu_count 1
  games_untouched
}

# T-10-15: the replaced build is never offered for removal in the umu backend (whether another Faugus game uses it is unknown)
t_ovr_install_no_prev_rm() {
  mk_release "$T"
  on_w3c "$T"
  mk_installed "$T" GE-Proton11-6-W3C
  printf '%s\n' GE-Proton11-6-W3C > "$T/home/.local/state/w3c-linux/proton-tag.prev"
  ovr_env "$(pfx)" "$TAG"
  FEED=$'y\ny\n'
  run "$T" update
  rc_is 0
  case $ERR in *'Remove GE-Proton11-6-W3C'*) ERRS+=('the removal was offered') ;; esac
  games_untouched
}

# ---------- UMU-05: the cold start through umu-run (D-16) ----------

# bn_exe: the Battle.net Launcher.exe the umu backend starts first; bn_launcher_make creates it in the fixture prefix.
bn_exe() { printf '%s/drive_c/Program Files (x86)/Battle.net/Battle.net Launcher.exe' "$(pfx)"; }
bn_launcher_make() {
  mkdir -p "$(dirname "$(bn_exe)")"
  : > "$(bn_exe)"
}

# the first umu-run call's environment (the cold start's), one line per variable
first_umu_env() { awk '/^== call ==$/ { c++; next } c == 1' "$T/marks/umu-run.env" 2> /dev/null; }

# bus down, Battle.net Launcher.exe through umu-run, the container comes up, the launcher re-enters it exactly as in Faugus mode
t_ovr_launch_cold() {
  local want e
  l_setup
  ovr_env "$(pfx)" "$TAG"
  bn_launcher_make
  down 3
  go
  rc_is 0
  want=(-u GAMEID -u STORE -u FAUGUSID -u PROTON_VERB WINE_SIMULATE_WRITECOPY=1 PROTON_ENABLE_WAYLAND=0
    UMU_CONTAINER_NSENTER=1 UMU_USE_STEAM=1 "WINEPREFIX=$(pfx)" "PROTONPATH=$T/home/.local/share/Steam/compatibilitytools.d/$TAG"
    "$T/home/.local/share/faugus-launcher/umu-run" "$(bn_exe)")
  [ "$(env_call 1)" = "$(printf '%s\n' "${want[@]}")" ] || ERRS+=("cold start argv: $(env_call 1 | tr '\n' ' ')")
  SNAP=$(env_call 2 | norm)
  golden_is "$GOLDEN_DIR/v0.1.1-launch-env.txt"
  [ ! -e "$T/marks/faugus-launcher" ] || ERRS+=('faugus-launcher ran')
  grep -q '^== .* umu-run Battle.net$' "$T/home/.cache/w3c-linux/wine.log" 2> /dev/null || ERRS+=('wine.log has no umu-run Battle.net header')
  out_has 'Starting Battle.net through umu-run ('
  [ ! -e "$T/marks/fd9" ] || ERRS+=("fd 9 was open in: $(tr '\n' ' ' < "$T/marks/fd9")")
  [ "$(head -n 1 "$T/marks/lock" 2> /dev/null)" = held ] || ERRS+=('the lock was not held while waiting for Battle.net')
  e=$(first_umu_env)
  for w in W3C_SHARED_QUERY WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS PROTON_VERB; do
    ! grep -q "^$w=" <<< "$e" || ERRS+=("the cold start env has $w")
  done
  grep -qxF UMU_USE_STEAM=1 <<< "$e" || ERRS+=('the cold start env lacks UMU_USE_STEAM=1')
  grep -qxF UMU_CONTAINER_NSENTER=1 <<< "$e" || ERRS+=('the cold start env lacks UMU_CONTAINER_NSENTER=1')
}

# the container is already up: nothing is started first, the launcher re-enters it (one env call)
t_ovr_launch_bus_up() {
  l_setup
  ovr_env "$(pfx)" "$TAG"
  go
  rc_is 0
  [ "$(grep -c '^== call ==$' "$T/marks/env")" = 1 ] || ERRS+=("env calls: want 1 got $(grep -c '^== call ==$' "$T/marks/env")")
  lacks_text 'Starting Battle.net'
  [ ! -e "$T/marks/faugus-launcher" ] || ERRS+=('faugus-launcher ran')
}

# Battle.net Launcher.exe is missing: stop, start nothing
t_ovr_launch_exe_missing() {
  l_setup
  ovr_env "$(pfx)" "$TAG"
  down
  go
  rc_is 1
  out_has "launch: $(bn_exe) is missing; "
  [ ! -e "$T/marks/env" ] || ERRS+=('something was started')
  no_umu
}

# the container never appears: the D-08 question, and No stops with the umu wording
t_ovr_launch_no_container() {
  l_setup
  ovr_env "$(pfx)" "$TAG"
  bn_launcher_make
  down
  CASE_ENV+=(W3C_BUS_WAIT_SECS=0)
  FEED=$'n\n'
  run "$T" launch
  rc_is 1
  err_has "$D08"
  out_has 'launch: not started; wait until Battle.net is up (started through umu-run), then rerun w3c-linux.sh launch'
  [ ! -e "$T/marks/faugus-launcher" ] || ERRS+=('faugus-launcher ran')
}

# install's last question names umu-run in the umu backend
t_ovr_launch_install_prompt() {
  mk_installed "$T"
  seed_tag "$T" "$TAG"
  ovr_env "$(pfx)" "$TAG"
  FEED=$'y\ny\n'
  run "$T" install
  err_has 'Launch now? Battle.net starts first through umu-run; sign in when it appears'
}

# ---------- main ----------

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case ${1-} in
    --record) record_goldens "${2:?--record needs a directory}" ;;
    *) main "$@" ;;
  esac
fi
