# shellcheck shell=bash disable=SC2034,SC2153
# Why SC2034 is off: the globals below are read by the other libs, which shellcheck cannot see when it checks this file alone.
# Why SC2153 is off: OV_PREFIX, OV_RUNNER and F_RUNNER are assigned in lib/backend.sh, which shellcheck cannot see when it checks this file alone.
# The umu backend (Phase 10): the second reader of the launch contract (NEED_*, PREFIX, BN_RUNNER, RUNNER_PATH, UMU_RUN, BN_LAUNCH_ENV).
# W3C_PREFIX and W3C_PROTON supply the prefix and runner. Faugus's files are never read here (D-10); backend_read never calls faugus_backend
# in this backend, so GAMES_JSON stays empty. Backend selection, the backend file and the backend subcommand live in lib/backend.sh.

# runner_abs VALUE: a runner given as a path becomes an absolute one (realpath -m), a name stays a name (D-08).
runner_abs() {
  case $1 in
    */*) realpath -m -- "$1" ;;
    *) printf '%s' "$1" ;;
  esac
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

# umu_backend [runner]: the umu backend's reader. It prints nothing and sets the same contract variables faugus_backend sets. backend_read calls it.
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
