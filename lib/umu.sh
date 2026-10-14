# shellcheck shell=bash disable=SC2034
# Why SC2034 is off: the globals below are read by the other libs, which shellcheck cannot see when it checks this file alone.
# The umu backend (Phase 10): the second reader of the launch contract (NEED_*, PREFIX, BN_RUNNER, RUNNER_PATH, UMU_RUN, BN_LAUNCH_ENV).
# W3C_PREFIX and W3C_PROTON supply the prefix and runner. Faugus's files are never read here (D-10); the Faugus branch of faugus_backend
# never runs in this backend, so GAMES_JSON stays empty.

# runner_abs VALUE: a runner given as a path becomes an absolute one (realpath -m), a name stays a name (D-08).
runner_abs() {
  case $1 in
    */*) realpath -m -- "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

# backend_pair: D-07, exactly one of W3C_PREFIX and W3C_PROTON set (empty counts as unset) is an error: message on stderr, return 1.
backend_pair() {
  if [ -n "${W3C_PREFIX-}" ] || [ -n "${W3C_PROTON-}" ]; then
    if [ -z "${W3C_PREFIX-}" ] || [ -z "${W3C_PROTON-}" ]; then
      printf '%s: set both W3C_PREFIX and W3C_PROTON, or neither\n' "$BIN_NAME" >&2
      return 1
    fi
  fi
  return 0
}

# backend_file_read: sets F_BACKEND, F_PREFIX, F_RUNNER from BACKEND_FILE. Returns 1 when the file is absent, 2 when it is not a valid
# umu backend (BACKEND=umu with PREFIX and RUNNER), else 0. The file is data: read line by line, never sourced or evaluated (D-19).
backend_file_read() {
  local k v
  F_BACKEND='' F_PREFIX='' F_RUNNER=''
  [ -e "$BACKEND_FILE" ] || [ -L "$BACKEND_FILE" ] || return 1
  [ -f "$BACKEND_FILE" ] || return 2   # a directory or a dangling link is present but not a valid file (D-17, D-19)
  while IFS='=' read -r k v || [ -n "$k" ]; do
    case $k in
      BACKEND) F_BACKEND=$v ;;
      PREFIX) F_PREFIX=$v ;;
      RUNNER) F_RUNNER=$v ;;
    esac
  done < "$BACKEND_FILE"
  [ "$F_BACKEND" = umu ] && [ -n "$F_PREFIX" ] && [ -n "$F_RUNNER" ] || return 2
  return 0
}

# backend_file_write PREFIX RUNNER: the saved backend, atomically (write_state).
backend_file_write() {
  write_state "$BACKEND_FILE" "BACKEND=umu
PREFIX=$1
RUNNER=$2"
}

# backend_resolve: picks the backend once per run, before any command prints (D-06): both env vars, else the saved file, else Faugus.
# Return 1 for a half-set override (D-07) or a present but malformed file (D-17: never silently hidden).
backend_resolve() {
  local rc
  BACKEND=faugus BACKEND_SRC=faugus
  backend_pair || return 1
  if [ -n "${W3C_PREFIX-}" ]; then
    BACKEND=umu BACKEND_SRC=env
    OV_PREFIX=$(realpath -m -- "$W3C_PREFIX")
    OV_RUNNER=$(runner_abs "$W3C_PROTON")
    return 0
  fi
  backend_file_read && rc=0 || rc=$?
  case $rc in
    0)
      BACKEND=umu BACKEND_SRC=file
      OV_PREFIX=$(realpath -m -- "$F_PREFIX")
      OV_RUNNER=$(runner_abs "$F_RUNNER") ;;
    2)
      printf '%s: %s is not a valid umu backend file (it needs BACKEND=umu, PREFIX= and RUNNER= lines): fix it or run %s backend clear\n' \
        "$BIN_NAME" "$BACKEND_FILE" "$BIN_NAME" >&2
      return 1 ;;
  esac
  return 0
}

# umu_note: the umu backend's doctor row text (no newline), naming where the prefix and runner came from.
umu_note() {
  printf "umu: prefix and runner from %s; Faugus's games.json is not read or written" "$BN_SOURCE"
}

# umu_save_runner TAG CMD: records the newly installed W3C build as the umu backend's runner (D-13). File origin: rewrites RUNNER in the
# backend file and keeps PREFIX; returns 0, or 2 when the write fails. Env origin: the script cannot change the user's environment and
# never edits shell files, so it prints the W3C_PROTON line to set; returns 1.
umu_save_runner() {
  if [ "$BACKEND_SRC" = file ]; then
    if backend_file_write "$OV_PREFIX" "$1"; then
      printf 'Saved runner %s in %s\n' "$1" "$BACKEND_FILE"
      return 0
    fi
    printf '%s: cannot write %s; rerun %s %s\n' "$2" "$BACKEND_FILE" "$BIN_NAME" "$2"
    return 2
  fi
  printf 'Set W3C_PROTON=%s (it is %s now), then rerun %s %s\n' "$1" "$OV_RUNNER" "$BIN_NAME" "$2"
  return 1
}

BN_CMD=()   # the umu cold start's argv (umu_start_battlenet)

# umu_backend [runner]: the umu backend's reader. It prints nothing and sets the same contract variables faugus_backend sets.
umu_backend() {
  if [ "${1-}" = runner ]; then
    BN_RUNNER_NOW=$OV_RUNNER
    # the file may have changed since backend_resolve: re-read it (never re-resolve, so the backend cannot change mid-run)
    if [ "$BACKEND_SRC" = file ]; then
      backend_file_read || return 1
      BN_RUNNER_NOW=$(runner_abs "$F_RUNNER")
    fi
    return 0
  fi
  NEED_ENTRY='' NEED_PREFIX='' NEED_UMU='' BN_PREFIX='' BN_RUNNER='' BN_LAUNCH_ARGUMENTS='' BN_PATH='' PREFIX='' RUNNER_PATH=''
  UMU_VERSION='' FAUGUS_VERSION=''
  R=() BN_LAUNCH_ENV=() FAUGUS_ENV_PRE=() FAUGUS_ENV_POST=()
  BN_SOURCE='W3C_PREFIX and W3C_PROTON'
  [ "$BACKEND_SRC" = file ] && BN_SOURCE=$BACKEND_FILE
  BN_PREFIX=$OV_PREFIX BN_RUNNER=$OV_RUNNER
  # D-11: the prefix is checked, never created
  if [ -d "$OV_PREFIX/drive_c" ]; then PREFIX=$OV_PREFIX; else NEED_PREFIX=prefix; fi
  RUNNER_PATH=$BN_RUNNER
  if build_complete "$(runner_dir "$BN_RUNNER")"; then RUNNER_PATH=$(runner_dir "$BN_RUNNER"); fi
  # D-15: a variable the user exported reaches umu through the inherited environment instead
  [ -n "${WINE_SIMULATE_WRITECOPY+x}" ] || BN_LAUNCH_ENV+=(WINE_SIMULATE_WRITECOPY=1)
  [ -n "${PROTON_ENABLE_WAYLAND+x}" ] || BN_LAUNCH_ENV+=(PROTON_ENABLE_WAYLAND=0)
  umu_pick
  return 0
}

# umu_start_battlenet: Phase 10 D-16. The umu backend starts Battle.net itself (faugus-launcher --game battlenet would start Faugus's own
# prefix, a different container). Battle.net Launcher.exe runs through umu-run with the launcher's prefix, runner and env minus the
# launcher-only variables. UMU_CONTAINER_NSENTER=1 as Faugus sets it: umu only starts pressure-vessel's launcher service (the
# com.steampowered.App bus the wait looks for) when it is 1; with no bus yet umu's own lookup fails after a few tries and the normal start
# runs. PROTON_VERB is unset so a stray value cannot change the verb. Returns 0 started, 2 cannot start (stop line printed). The caller
# waits for the container.
umu_start_battlenet() {
  local exe="$PREFIX/drive_c/Program Files (x86)/Battle.net/Battle.net Launcher.exe"
  if [ ! -f "$exe" ]; then
    launch_stop 'launch: %s is missing; the umu backend starts Battle.net with it (check the prefix with %s doctor)\n' "$exe" "$BIN_NAME"
    return 2
  fi
  BN_CMD=(env -u GAMEID -u STORE -u FAUGUSID -u PROTON_VERB "${BN_LAUNCH_ENV[@]}"
    UMU_CONTAINER_NSENTER=1 UMU_USE_STEAM=1 "WINEPREFIX=$PREFIX" "PROTONPATH=$RUNNER_PATH" "$UMU_RUN" "$exe")
  if ! { mkdir -p -- "$CACHE_DIR" && printf '\n== %s umu-run Battle.net\n' "$(date '+%F %T')" >> "$WINE_LOG"; }; then
    launch_stop 'launch: cannot write %s\n' "$WINE_LOG"
    return 2
  fi
  # fd 9 (the run lock) closed so Battle.net, which lives for hours, never holds it
  setsid "${BN_CMD[@]}" 9>&- < /dev/null >> "$WINE_LOG" 2>&1 &
  say 'Starting Battle.net through umu-run (%s); waiting up to %s s for its container\n' "$exe" "$BUS_MAX"
}

# cmd_backend VERB...: set umu PREFIX RUNNER, show, clear (D-17). Every verb is refused for a half-set override (D-07). show resolves
# on its own so set and clear still work on a malformed file.
cmd_backend() {
  local usage="usage: $BIN_NAME backend set umu PREFIX RUNNER | backend show | backend clear" p r
  backend_pair || return 2
  case ${1-} in
    set)
      # D-17: exactly `set umu PREFIX RUNNER`
      [ "$#" = 4 ] || { printf '%s\n' "$usage" >&2; return 2; }
      [ "$2" = umu ] || { printf 'backend: unknown backend %s; only umu is supported\n' "$2" >&2; return 2; }
      # T-10-10: an empty or multi-line value would inject or lose KEY lines
      case $3 in '' | *$'\n'*) printf 'backend: PREFIX and RUNNER must be non-empty single-line values\n' >&2; return 2 ;; esac
      case $4 in '' | *$'\n'*) printf 'backend: PREFIX and RUNNER must be non-empty single-line values\n' >&2; return 2 ;; esac
      p=$(realpath -m -- "$3")
      # D-18: the prefix must exist and be a Wine prefix; nothing is created. The runner is not checked.
      if [ ! -d "$p/drive_c" ]; then
        printf 'backend: %s is not a Wine prefix (no drive_c); point it at your existing Battle.net prefix. Nothing was saved.\n' "$p" >&2
        return 1
      fi
      r=$(runner_abs "$4")
      backend_file_write "$p" "$r" || { printf 'backend: cannot write %s\n' "$BACKEND_FILE" >&2; return 1; }
      printf 'Saved the umu backend in %s: prefix %s, runner %s. Next: %s doctor\n' "$BACKEND_FILE" "$p" "$r" "$BIN_NAME"
      [ -n "${W3C_PREFIX-}" ] && printf 'W3C_PREFIX and W3C_PROTON are set and win over this file until you unset them\n'
      return 0 ;;
    show)
      [ "$#" = 1 ] || { printf '%s\n' "$usage" >&2; return 2; }
      backend_resolve || return 2
      if [ "$BACKEND" = umu ]; then
        if [ "$BACKEND_SRC" = env ]; then printf 'backend: umu (from W3C_PREFIX and W3C_PROTON)\n'
        else printf 'backend: umu (from %s)\n' "$BACKEND_FILE"; fi
        printf 'prefix: %s\nrunner: %s\n' "$OV_PREFIX" "$OV_RUNNER"
        # D-06: the env wins; say so when a file is also there
        [ "$BACKEND_SRC" = env ] && [ -e "$BACKEND_FILE" ] && printf '%s is ignored while W3C_PREFIX and W3C_PROTON are set\n' "$BACKEND_FILE"
      else
        printf 'backend: faugus (W3C_PREFIX and W3C_PROTON are unset and %s does not exist)\n' "$BACKEND_FILE"
      fi
      return 0 ;;
    clear)
      [ "$#" = 1 ] || { printf '%s\n' "$usage" >&2; return 2; }
      # T-10-12: one fixed path, no recursion or globbing; a malformed file can always be cleared
      if [ -e "$BACKEND_FILE" ] || [ -L "$BACKEND_FILE" ]; then
        rm -f -- "$BACKEND_FILE" || { printf 'backend: cannot remove %s\n' "$BACKEND_FILE" >&2; return 1; }
        printf 'Removed %s; the Faugus backend is used unless W3C_PREFIX and W3C_PROTON are set\n' "$BACKEND_FILE"
      else
        printf 'Nothing to clear: %s does not exist\n' "$BACKEND_FILE"
      fi
      return 0 ;;
    *) printf '%s\n' "$usage" >&2; return 2 ;;
  esac
}
