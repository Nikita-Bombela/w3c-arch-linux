# shellcheck shell=bash disable=SC2034
# Why SC2034 is off: the globals below are read by the other libs, which shellcheck cannot see when it checks this file alone.
# Everything that knows Faugus's files and processes lives in this file, and faugus_backend is the only reader of them: it holds
# faugus_backend, umu_pick (the umu-run chain, whose first step and version.txt are Faugus's files), the Faugus doctor rows and version
# check, the runner switch and backups, the Battle.net start, and the idle check's Faugus processes.

DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
FLATPAK_JSON=$HOME/.var/app/io.github.Faugus.faugus-launcher/data/faugus-launcher/games.json
FAUGUS_CFG=$CONFIG_HOME/faugus-launcher/config.json
FAUGUS_ENVAR=$CONFIG_HOME/faugus-launcher/envar.json
GAMES_JSON=''
RUNNING_GAMES=$STATE_HOME/faugus-launcher/running-games.json
R=()              # NUL-delimited fields handed over by python3
BN_LAUNCH_ARGUMENTS='' BN_PATH=''   # display data only
FG_JSON='' FG_UMU='' FG_CFG='' FG_ENVAR=''   # what the Faugus reader found, for the row emitters below
FAUGUS_PY_DIR=${W3C_FAUGUS_PY_DIR-}   # test seam, like W3C_SYS_ROOT: a directory holding faugus/launcher.py; empty means the installed package is found by the helper (it ignores PYTHONPATH, so no other seam works)
FAUGUS_VERSION=''

# py_entry FILE: status-first NUL-delimited fields describing the battlenet entry.
#   ok|ok-badargs, prefix, runner, launch_arguments, path, prefix_expanded, env tokens...
#   count, N          (number of gameid == battlenet entries is not 1)
#   unreadable        (not openable, not JSON, not a list, or a value holds a NUL)
py_entry() {
  python3 -I -B "$HELPER" entry "$1" 2> /dev/null
}

# py_env CONFIG ENVAR: cfgstatus, envstatus (ok|bad; a missing file is ok), npre, PRE..., POST... (NUL-delimited).
# Mirrors Faugus 2.4.2: toggles enable only on the exact string True; envar.json entries follow load_env_from_file.
py_env() {
  python3 -I -B "$HELPER" env "$1" "$2" 2> /dev/null
}

# py_faugus_version DIR: Faugus's VERSION from faugus/launcher.py, read as text (faugus is never imported); nothing when unreadable.
# DIR empty: the installed package, found with importlib.util.find_spec. DIR set: DIR/faugus/launcher.py only. Always exits 0.
py_faugus_version() {
  python3 -I -B "$HELPER" faugus-version "$1" 2> /dev/null
}

# faugus_backend [runner]: the one reader of Faugus's files. It prints nothing and sets the contract variables (DESIGN.md lists them).
# faugus_backend runner re-reads only the runner, so a runner switched since the checks is seen; the prefix and env stay as the
# checks read them. backend_read (lib/backend.sh) is its only caller.
faugus_backend() {
  local E=() v='' f x npre
  if [ "${1-}" = runner ]; then
    BN_RUNNER_NOW=''
    mapfile -d '' -t E < <(py_entry "$GAMES_JSON")
    case ${E[0]:-pyfail} in
      ok | ok-badargs)
        BN_RUNNER_NOW=${E[2]-}
        return 0 ;;
    esac
    return 1
  fi
  NEED_ENTRY='' NEED_PREFIX='' NEED_UMU='' BN_PREFIX='' BN_RUNNER='' BN_LAUNCH_ARGUMENTS='' BN_PATH='' PREFIX='' RUNNER_PATH=''
  UMU_VERSION='' FAUGUS_VERSION=''
  R=() BN_LAUNCH_ENV=() FAUGUS_ENV_PRE=() FAUGUS_ENV_POST=()
  # games.json: the data home first, then the config home
  if [ -f "$DATA_HOME/faugus-launcher/games.json" ]; then
    GAMES_JSON=$DATA_HOME/faugus-launcher/games.json
    BN_SOURCE=$GAMES_JSON
  elif [ -f "$CONFIG_HOME/faugus-launcher/games.json" ]; then
    GAMES_JSON=$CONFIG_HOME/faugus-launcher/games.json
    BN_SOURCE=$GAMES_JSON
  else
    NEED_ENTRY=games.json
    if [ -f "$FLATPAK_JSON" ]; then FG_JSON=flatpak; else FG_JSON=none; fi
  fi
  if [ -z "$NEED_ENTRY" ]; then
    if ! type -P python3 > /dev/null; then
      FG_JSON=nopython
      NEED_ENTRY=python3
    else
      mapfile -d '' -t R < <(py_entry "$GAMES_JSON")
      case ${R[0]:-pyfail} in
        unreadable | pyfail)
          FG_JSON=unreadable
          NEED_ENTRY=games.json ;;
        *) FG_JSON=ok ;;
      esac
    fi
  fi
  # the Battle.net entry
  if [ -z "$NEED_ENTRY" ] && [ "${R[0]}" = count ]; then NEED_ENTRY='battlenet entry'; fi
  if [ -n "$NEED_ENTRY" ]; then
    NEED_PREFIX=$NEED_ENTRY
  else
    BN_PREFIX=${R[1]} BN_RUNNER=${R[2]} BN_LAUNCH_ARGUMENTS=${R[3]} BN_PATH=${R[4]}
    x=${R[5]}
    BN_LAUNCH_ENV=("${R[@]:6}")
    # ponytail: a non-W3C or Faugus-managed runner keeps its bare name; check_proton only warns about it and umu decides
    RUNNER_PATH=$BN_RUNNER
    if [ -n "$BN_RUNNER" ] && build_complete "$COMPAT/$BN_RUNNER"; then RUNNER_PATH=$COMPAT/$BN_RUNNER; fi
    if [ -z "$BN_PREFIX" ]; then
      NEED_PREFIX=prefix
    else
      # Faugus expands ~ and $VAR before use
      PREFIX=$(realpath -m -- "$x")
    fi
  fi
  umu_pick
  # Faugus's global env: the toggles and envar.json
  if ! type -P python3 > /dev/null; then
    FG_CFG=nopython FG_ENVAR=nopython
  else
    mapfile -d '' -t E < <(py_env "$FAUGUS_CFG" "$FAUGUS_ENVAR")
    # an empty or malformed read means python crashed: treat both files as unreadable
    [ "${#E[@]}" -ge 3 ] || E=(bad bad 0)
    case ${E[2]} in '' | *[!0-9]*) E=(bad bad 0) ;; esac
    npre=${E[2]}
    FAUGUS_ENV_PRE=("${E[@]:3:npre}")
    FAUGUS_ENV_POST=("${E[@]:3+npre}")
    if [ "${E[0]}" = bad ]; then FG_CFG=bad; elif [ -f "$FAUGUS_CFG" ]; then FG_CFG=ok; else FG_CFG=absent; fi
    if [ "${E[1]}" = bad ]; then FG_ENVAR=bad; elif [ -f "$FAUGUS_ENVAR" ]; then FG_ENVAR=ok; else FG_ENVAR=absent; fi
  fi
  # Faugus's own version, else the one query of the distro family's package manager (none for unknown); safe_version below vets the result
  if type -P python3 > /dev/null; then v=$(py_faugus_version "$FAUGUS_PY_DIR"); fi
  if ! safe_version "$v"; then
    v=''
    case $DISTRO_FAMILY in
      arch)
        f=$(pacman -Q faugus-launcher 2> /dev/null) || f=''
        v=${f#* } ;;
      fedora)
        # rpm prints its not-installed sentence on stdout, so only the exit status says the package is there
        v=$(rpm -q --qf '%{VERSION}\n' faugus-launcher 2> /dev/null) || v='' ;;
      debian)
        # shellcheck disable=SC2016 # dpkg-query's own format text, not a shell expansion
        f=$(dpkg-query -W -f='${db:Status-Status} ${Version}\n' faugus-launcher 2> /dev/null) || f=''
        # a removed package (config-files) is still listed: only the installed status counts
        case $f in 'installed '*) v=${f#installed } ;; esac ;;
    esac
    # drops the package or Debian revision (-1, -1~noble1), then an epoch (1:)
    v=${v%-*}
    v=${v#*:}
  fi
  if safe_version "$v"; then FAUGUS_VERSION=$v; fi
  return 0
}

# umu_pick: the umu-run chain (Phase 10 D-01 to D-03). Faugus's bundled copy wins when it is there; else the user's UMU_RUN (never
# falling through past a path the user named, D-02), then the first umu-run on PATH, then $SYS_ROOT/usr/share/umu/umu-run. Sets UMU_RUN,
# UMU_SRC, FG_UMU (ok|noexec|badenv|missing), NEED_UMU and UMU_VERSION: version.txt for the bundled copy, else `umu-run --version`.
umu_pick() {
  local b=$DATA_HOME/faugus-launcher/umu-run f p
  UMU_SRC='' UMU_VERSION='' NEED_UMU=''
  if [ -f "$b" ]; then
    UMU_RUN=$b
    if [ -x "$b" ]; then FG_UMU=ok; else FG_UMU=noexec; fi
  elif [ -n "$UMU_RUN_USER" ]; then
    UMU_RUN=$UMU_RUN_USER UMU_SRC=UMU_RUN
    if [ -f "$UMU_RUN" ] && [ -x "$UMU_RUN" ]; then FG_UMU=ok; else FG_UMU=badenv; fi
  elif p=$(type -P umu-run); then
    UMU_RUN=$p UMU_SRC=PATH FG_UMU=ok
  elif [ -f "$SYS_ROOT/usr/share/umu/umu-run" ] && [ -x "$SYS_ROOT/usr/share/umu/umu-run" ]; then
    UMU_RUN=$SYS_ROOT/usr/share/umu/umu-run UMU_SRC=/usr/share/umu FG_UMU=ok
  else
    UMU_RUN=$b FG_UMU=missing
  fi
  if [ "$FG_UMU" != ok ]; then
    NEED_UMU=umu-run
    return 0
  fi
  if [ -z "$UMU_SRC" ]; then
    f=$DATA_HOME/faugus-launcher/version.txt
    [ -r "$f" ] && { read -r UMU_VERSION < "$f" || true; }
  fi
  # doctor runs umu-run only here, with --version, bounded by timeout 5 (D-05); any failure leaves the version empty (shown as unknown)
  if [ -z "$UMU_VERSION" ] && type -P timeout > /dev/null; then
    p=$(timeout 5 "$UMU_RUN" --version < /dev/null 2> /dev/null) || p=''
    if [[ $p =~ version[[:space:]]+([0-9]+(\.[0-9]+){1,3}) ]]; then UMU_VERSION=${BASH_REMATCH[1]}; fi
  fi
  return 0
}

# faugus_row_version: doctor's version row. Faugus 2.4.2 is the tested version; it never fails.
faugus_row_version() {
  # Phase 18 D-08: under the Steam backend the slot names the source
  if [ "$BACKEND" = steam ]; then
    emit pass backend "$(steam_note)"
    return 0
  fi
  # D-21: in the umu backend the slot names the source instead
  if [ "$BACKEND" = umu ]; then
    emit pass backend "$(umu_note)"
    return 0
  fi
  case $FAUGUS_VERSION in
    '') emit warn 'faugus version' unknown ;;
    2.*) emit pass 'faugus version' "$FAUGUS_VERSION" ;;
    *) emit warn 'faugus version' "untested Faugus major ${FAUGUS_VERSION%%.*}: games.json/envar.json format may differ" ;;
  esac
}

# faugus_rows_entry: the games.json row and the Battle.net entry rows, from what faugus_backend found.
faugus_rows_entry() {
  local l
  # the Steam backend reads no Faugus entry either: the Faugus rows are skipped and the Steam rows take their place (Phase 18 D-08)
  if [ "$BACKEND" = steam ]; then
    for l in games.json battlenet; do emit skip "$l" 'needs: Faugus (backend: steam)'; done
    steam_rows_entry
    emit skip path 'needs: Faugus (backend: steam)'   # the launch options row took launch_arguments's slot
    return 0
  fi
  # the umu backend reads no Faugus entry: the Faugus rows are skipped, the prefix and runner come from the override (D-10, D-11)
  if [ "$BACKEND" = umu ]; then
    for l in games.json battlenet; do emit skip "$l" 'needs: Faugus (backend: umu)'; done
    if [ "$NEED_PREFIX" = prefix ]; then
      emit fail prefix "not a Wine prefix (no drive_c): $BN_PREFIX; set W3C_PREFIX or run $BIN_NAME backend set umu PREFIX RUNNER with your existing Battle.net prefix"
    else
      emit pass prefix "$BN_PREFIX"
    fi
    emit pass runner "$BN_RUNNER"
    for l in launch_arguments path; do emit skip "$l" 'needs: Faugus (backend: umu)'; done
    return 0
  fi
  case $FG_JSON in
    flatpak) emit fail games.json "Flatpak Faugus is unsupported: a host-side wrapper cannot re-enter the Flatpak sandbox's container ($FLATPAK_JSON)" ;;
    none) emit fail games.json "Install Faugus and add Battle.net (Add game -> Battle.net), or use an existing prefix: $BIN_NAME backend set umu PREFIX RUNNER" ;;
    unreadable) emit fail games.json "games.json unreadable: $GAMES_JSON" ;;
    *) emit pass games.json "$GAMES_JSON" ;;
  esac
  if [ "$NEED_ENTRY" = 'battlenet entry' ]; then
    if [ "${R[1]}" = 0 ]; then
      emit fail battlenet 'no Battle.net in Faugus'
    else
      emit fail battlenet "games.json has ${R[1]} entries with gameid battlenet; remove the duplicate in Faugus"
    fi
    for l in prefix runner launch_arguments path; do
      emit skip "$l" "needs: $NEED_ENTRY"
    done
  elif [ -n "$NEED_ENTRY" ]; then
    for l in battlenet prefix runner launch_arguments path; do
      emit skip "$l" "needs: $NEED_ENTRY"
    done
  else
    emit pass battlenet found
    if [ "$NEED_PREFIX" = prefix ]; then
      emit fail prefix 'Battle.net entry has no prefix'
    else
      emit pass prefix "$BN_PREFIX"
    fi
    emit pass runner "$BN_RUNNER"
    emit pass launch_arguments "$BN_LAUNCH_ARGUMENTS"
    emit pass path "$BN_PATH"
  fi
}

# faugus_rows_umu: the umu-run and umu version rows.
faugus_rows_umu() {
  # Phase 18 STEAM-05: Steam runs the shortcut itself, so no umu-run is wanted, found or run
  if [ "$BACKEND" = steam ]; then
    emit skip umu-run 'not used (backend: steam)'
    emit skip 'umu version' 'not used (backend: steam)'
    return 0
  fi
  case $FG_UMU in
    # in the umu backend the hint leaves Faugus out; the family's command comes from install_hint (Phase 15 D-03)
    missing)
      if [ "$BACKEND" = umu ]; then
        emit fail umu-run "$(install_hint umu-run), or set UMU_RUN to its path"
      else
        emit fail umu-run "Launch any game once in Faugus so it downloads umu-run, or $(install_hint umu-run), or set UMU_RUN to its path"
      fi ;;
    noexec) emit fail umu-run "not executable: $UMU_RUN" ;;
    badenv) emit fail umu-run "UMU_RUN is set to $UMU_RUN, which is missing or not executable: fix it or unset UMU_RUN" ;;
    *) emit pass umu-run "$UMU_RUN${UMU_SRC:+ ($UMU_SRC)}" ;;
  esac
  if [ -n "$NEED_UMU" ]; then
    emit skip 'umu version' "needs: $NEED_UMU"
    return 0
  fi
  if [ -n "$UMU_VERSION" ]; then
    emit pass 'umu version' "$UMU_VERSION"
  else
    emit warn 'umu version' unknown
  fi
}

# faugus_rows_env: Faugus's global env rows, then the launch env rows.
# FAUGUS_ENV_PRE (toggles minus keys envar.json sets) then FAUGUS_ENV_POST (envar.json) is Faugus's effective global env;
# later phases splice BN_LAUNCH_ENV between them. UMU_USE_STEAM, UMU_CONTAINER_NSENTER and the EAC/BattlEye vars are never added.
# BN_LAUNCH_ENV is built by Faugus's own rule in py_entry; BN_LAUNCH_ARGUMENTS is display data only.
faugus_rows_env() {
  local e
  if [ "$BACKEND" = steam ]; then
    # D-08: no Faugus file is read, and the environment lives in the shortcut's launch options, so `(none)` would mislead
    emit skip config.json 'needs: Faugus (backend: steam)'
    emit skip envar.json 'needs: Faugus (backend: steam)'
    emit skip 'faugus env' 'needs: Faugus (backend: steam)'
    emit skip 'launch env' "not used (backend: steam): the shortcut's launch options carry the environment"
    return 0
  fi
  if [ "$BACKEND" = umu ]; then
    # the umu backend reads neither Faugus file (D-10)
    emit skip config.json 'needs: Faugus (backend: umu)'
    emit skip envar.json 'needs: Faugus (backend: umu)'
    emit skip 'faugus env' 'needs: Faugus (backend: umu)'
  elif [ "$FG_CFG" = nopython ]; then
    emit skip config.json 'needs: python3'
    emit skip envar.json 'needs: python3'
    emit skip 'faugus env' 'needs: python3'
  else
    case $FG_CFG in
      bad) emit warn config.json "unreadable, toggles off: $FAUGUS_CFG" ;;
      ok) emit pass config.json "$FAUGUS_CFG" ;;
      *) emit pass config.json "absent: $FAUGUS_CFG" ;;
    esac
    case $FG_ENVAR in
      bad) emit warn envar.json "unreadable, no entries used: $FAUGUS_ENVAR" ;;
      ok) emit pass envar.json "$FAUGUS_ENVAR" ;;
      *) emit pass envar.json "absent: $FAUGUS_ENVAR" ;;
    esac
    if [ $((${#FAUGUS_ENV_PRE[@]} + ${#FAUGUS_ENV_POST[@]})) -eq 0 ]; then
      emit pass 'faugus env' '(none)'
    else
      for e in "${FAUGUS_ENV_PRE[@]}" "${FAUGUS_ENV_POST[@]}"; do emit pass 'faugus env' "$e"; done
    fi
  fi
  if [ -n "$NEED_ENTRY" ]; then
    emit skip 'launch env' "needs: $NEED_ENTRY"
  elif [ "${R[0]-}" = ok-badargs ]; then
    emit warn 'launch env' 'launch_arguments has an unbalanced quote; no env taken from it'
  elif [ "${#BN_LAUNCH_ENV[@]}" -eq 0 ]; then
    emit pass 'launch env' '(none)'
  else
    for e in "${BN_LAUNCH_ENV[@]}"; do
      emit pass 'launch env' "$e"
    done
  fi
}

# py_games OP ARGS...: games.json helpers, status-first NUL fields; argv is the only data channel.
#   running-idle PATH                     idle | busy
#   set-runner PATH OLD NEW BACKUP_DIR    ok, backup path | cas | bad
#   pick-backup BACKUP_DIR TAG            ok, path, runner | none: the newest backup (by name) whose battlenet runner is not TAG or *-W3C
#   uses-runner PATH NAME                 yes | no: some entry runs on NAME (an unreadable file counts as yes)
py_games() {
  python3 -I -B "$HELPER" games "$@" 2> /dev/null
}

# switch_runner TAG: the backed-up atomic edit of the battlenet runner.
switch_runner() {
  local tag=$1
  if ! build_complete "$COMPAT/$tag"; then
    printf '%s: %s/%s is incomplete; rerun install\n' "$CMD" "$COMPAT" "$tag"
    return 1
  fi
  mapfile -d '' -t G < <(py_games set-runner "$GAMES_JSON" "$BN_RUNNER" "$tag" "$W3C_STATE")
  case ${G[0]:-pyfail} in
    ok) printf 'Battle.net runner switched: %s -> %s (backup: %s)\n' "$BN_RUNNER" "$tag" "${G[1]:-}" ;;
    cas)
      printf '%s: games.json changed while %s was waiting; nothing was written, rerun %s\n' "$CMD" "$CMD" "$CMD"
      return 1 ;;
    *)
      printf '%s: could not write games.json; the original is unchanged\n' "$CMD"
      return 1 ;;
  esac
}

# revert_write NEW: idle re-check, then the backed-up atomic write of the battlenet runner NEW (shared by both revert paths).
revert_write() {
  if ! idle_check; then
    print_busy
    printf 'revert: something started again (listed above); games.json was not changed\n'
    return 1
  fi
  mapfile -d '' -t G < <(py_games set-runner "$GAMES_JSON" "$BN_RUNNER" "$1" "$W3C_STATE")
  case ${G[0]:-pyfail} in
    ok) printf 'Battle.net runner restored: %s -> %s (backup of the previous file: %s)\n' \
      "$(runner_label "$BN_RUNNER")" "$(runner_label "$1")" "${G[1]:-}" ;;
    cas)
      printf 'revert: games.json changed while revert was waiting; nothing was written, rerun revert\n'
      return 1 ;;
    *)
      printf 'revert: could not write games.json; the original is unchanged\n'
      return 1 ;;
  esac
}

# faugus_managed NAME: runners Faugus resolves itself, so no compatibilitytools.d entry is needed (faugus utils.py, runner.py).
faugus_managed() {
  case $1 in
    '' | 'Proton-GE Latest' | 'Proton-EM Latest' | 'DW-Proton Latest' | 'Proton-CachyOS Latest' | 'Proton-Wineland Latest' \
      | UMU-Latest | LegacyRuntime | umu-*) return 0 ;;
  esac
  return 1
}

# runner_label NAME: the name Faugus shows; the empty runner is its UMU-Proton Latest.
runner_label() {
  if [ -z "$1" ]; then printf 'UMU-Proton Latest'; else printf '%s' "$1"; fi
}

# start_battlenet: starts Battle.net and waits up to W3C_BUS_WAIT_SECS (default 120) for its container. Faugus mode starts it through
# faugus-launcher; the umu backend starts Battle.net Launcher.exe through umu-run itself (D-16, umu_start_battlenet).
# Returns 0 when the bus name appeared, 1 when it did not, 2 when it cannot be started. Never consults idle_check: a Faugus window
# or tray never blocks launch.
start_battlenet() {
  local i dots=0
  BUS_MAX=120
  case ${W3C_BUS_WAIT_SECS:-} in '' | *[!0-9]* | ?????????*) ;; *) BUS_MAX=$((10#$W3C_BUS_WAIT_SECS)) ;; esac
  if [ "$BACKEND" = umu ]; then
    umu_start_battlenet || return 2
  else
    if ! type -P faugus-launcher > /dev/null; then
      launch_stop 'launch: faugus-launcher is not on PATH; start Battle.net in Faugus, then rerun %s launch\n' "$BIN_NAME"
      return 2
    fi
    if ! { mkdir -p -- "$CACHE_DIR" && printf '\n== %s faugus-launcher --game battlenet\n' "$(date '+%F %T')" >> "$WINE_LOG"; }; then
      launch_stop 'launch: cannot write %s\n' "$WINE_LOG"
      return 2
    fi
    # fd 9 (the run lock) closed so Faugus, which lives for hours, never holds it. ponytail: Battle.net's output shares wine.log and grows
    # with every session; split it into a truncated faugus.log if that gets large.
    setsid faugus-launcher --game battlenet 9>&- < /dev/null >> "$WINE_LOG" 2>&1 &
    say 'Starting Battle.net through Faugus (faugus-launcher --game battlenet); waiting up to %s s for its container\n' "$BUS_MAX"
  fi
  for ((i = 1; i <= BUS_MAX; i++)); do
    bus_up && break
    sleep 1
    if [ $((i % 5)) = 0 ]; then
      printf .
      dots=1
    fi
  done
  [ "$dots" = 0 ] || printf '\n'
  bus_up
}

# faugus_pick_backup TAG: fills G with the newest games.json backup whose Battle.net runner is not TAG or a W3C build. Returns 0 when one was found.
faugus_pick_backup() {
  mapfile -d '' -t G < <(py_games pick-backup "$W3C_STATE" "$1")
  [ "${G[0]:-none}" = ok ]
}

# faugus_uses_runner NAME: fills G. Returns 1 only when no games.json entry runs on NAME; an unreadable file counts as used.
faugus_uses_runner() {
  mapfile -d '' -t G < <(py_games uses-runner "$GAMES_JSON" "$1")
  [ "${G[0]:-yes}" = no ] || return 0
  return 1
}

# faugus_tool_used NAME (D-12, D-21): the games.json the Faugus reader would use (data home, then config home; the first that exists decides,
# even when it is not a regular file) has an entry running on NAME. Returns 1 only when it says no, or when there is no games.json at all;
# an unreadable file counts as used. It does not touch GAMES_JSON, which only faugus_backend sets.
faugus_tool_used() {
  local f
  for f in "$DATA_HOME/faugus-launcher/games.json" "$CONFIG_HOME/faugus-launcher/games.json"; do
    [ -e "$f" ] || continue
    mapfile -d '' -t G < <(py_games uses-runner "$f" "$1")
    [ "${G[0]:-yes}" = no ] || return 0
    return 1
  done
  return 1
}

# faugus_busy: adds to BUSY what only Faugus tells us: its main window or tray, a game it started and its running-games.json.
# Faugus's backup daemon (python3 -m faugus.backup_daemon) is deliberately not matched, because it reads games.json and writes only
# backup copies and config.json.
faugus_busy() {
  proc_match 'Faugus (main window or tray icon)' -f 'faugus\.(launcher|tray_only)'
  proc_match 'a game started through Faugus (faugus.runner)' -f 'faugus\.runner'
  mapfile -d '' -t G < <(py_games running-idle "$RUNNING_GAMES")
  [ "${G[0]:-pyfail}" = idle ] || BUSY+=('a game Faugus lists as running (running-games.json)')
}
