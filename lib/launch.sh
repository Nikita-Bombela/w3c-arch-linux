# shellcheck shell=bash
# The launch subcommand: container start, launcher run, restart guide.

# launch_stop FORMAT ARG...: a stop line on the terminal (or in launch.log), and also an error dialog without a terminal.
launch_stop() {
  local msg
  # shellcheck disable=SC2059 # the callers pass a fixed format
  printf -v msg "$@"
  say '%s' "$msg"
  desk_error "$msg"
}

# bus_up: 0 when Battle.net's container is on the bus (umu names it com.steampowered.App<md5 of the prefix>), else 1.
# The listing goes through a variable: a pipe into grep -q would return 141 under pipefail.
bus_up() {
  local out
  [ -x "$LAUNCH_CLIENT" ] && [ -n "$APPID" ] || return 1
  out=$("$LAUNCH_CLIENT" --list 2> /dev/null)
  grep -qxF -- "--bus-name=com.steampowered.App$APPID" <<< "$out"
}

# launcher_running: 0 a W3Champions.exe of this user exists, 1 none, 2 pgrep cannot tell (status in PGREP_RC).
launcher_running() {
  pgrep -u "$UID" -f 'W3Champions\.exe' > /dev/null
  PGREP_RC=$?
  case $PGREP_RC in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}

# launch_cmd MODE TARGET: fills LAUNCH_CMD, no side effects. MODE nsenter re-enters Battle.net's container, run starts a new one.
# Env order: Faugus toggles, launch_arguments, envar.json, then ours, so ours always win. GAMEID, STORE and FAUGUSID are unset
# (Faugus kills every process carrying FAUGUSID when Battle.net exits). W3C_WRAPPER_WEBVIEW_FLAGS: unset means --no-sandbox, empty or 0 means off.
launch_cmd() {
  local mode=$1 target=$2 sel=UMU_CONTAINER_NSENTER=1 norun=() web=() flags=--no-sandbox
  flags=${W3C_WRAPPER_WEBVIEW_FLAGS-$flags}
  case $flags in '' | 0) ;; *) web=("WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=$flags") ;; esac
  if [ "$mode" = run ]; then
    sel=PROTON_VERB=run
    norun=(-u UMU_CONTAINER_NSENTER)
  fi
  # UMU_USE_STEAM=1 stays in both modes: inert on the nsenter path, what Faugus itself sets for Battle.net on the run path
  LAUNCH_CMD=(env -u GAMEID -u STORE -u FAUGUSID "${norun[@]}"
    "${FAUGUS_ENV_PRE[@]}" "${BN_LAUNCH_ENV[@]}" "${FAUGUS_ENV_POST[@]}"
    "$sel" UMU_USE_STEAM=1 "WINEPREFIX=$PREFIX" "PROTONPATH=$RUNNER_PATH" W3C_SHARED_QUERY=1 "${web[@]}" "$UMU_RUN" "$target")
}

# write_bat: W3ChampionsOnLinux's four-line W3Champions.bat with CRLF line ends, through a temp file in the same directory and mv, left
# alone when the bytes already match. A plain file write; no Wine starts. 1 when it cannot be written.
write_bat() {
  local tmp
  tmp=$(mktemp "${W3C_BAT%/*}/.w3c.bat.XXXXXX" 2> /dev/null) || return 1
  if ! printf '%s\r\n' 'C:' 'start "" "C:\Program Files\W3Champions\W3Champions.exe"' 'net stop "Bonjour Service"' 'net start "Bonjour Service"' > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if cmp -s -- "$tmp" "$W3C_BAT"; then
    rm -f -- "$tmp"
  elif ! mv -f -- "$tmp" "$W3C_BAT"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# wait_enter PROMPT: returns 0 on Enter (or a zenity Yes); q, a zenity No or EOF return 1.
wait_enter() {
  local ans=''
  if use_zenity; then
    zenity --question --no-markup --title=w3c-linux --text="$1 (Yes continues, No stops)" 2> /dev/null && return 0
    say 'Stopped; W3Champions was not started.\n' >&2
    return 1
  fi
  say '%s (q to quit): ' "$1" >&2
  if ! read -r ans && [ -z "$ans" ]; then
    say 'no answer (stdin closed); run in a terminal\n' >&2
    return 1
  fi
  if [ "${ans,,}" = q ]; then
    say 'Stopped; W3Champions was not started.\n' >&2
    return 1
  fi
  return 0
}

# spawn_launcher: starts LAUNCH_CMD detached in its own session (Ctrl-C in the terminal must not reach umu, whose handler kills the
# container's process tree), without the run lock (fd 9) and the monitor lock (fd 8), output appended to WINE_LOG. Sets LAUNCHER_PID.
spawn_launcher() {
  # stale Bonjour responders and Edge updaters of earlier sessions; only reached when no W3Champions.exe runs.
  kill_updater 'mDNSResponder\.exe'
  kill_updater
  if ! { mkdir -p -- "$CACHE_DIR" && printf '\n== %s launch %s\n' "$(date '+%F %T')" "${LAUNCH_CMD[-1]}" >> "$WINE_LOG"; }; then
    launch_stop 'launch: cannot write %s\n' "$WINE_LOG"
    return 1
  fi
  setsid "${LAUNCH_CMD[@]}" 9>&- 8>&- < /dev/null >> "$WINE_LOG" 2>&1 &
  LAUNCHER_PID=$!
}

# lan_hint_scan [base]: "base" only records the current match count as LAN_BASE. Otherwise, once per session, reacts when
# w3champions.log gained an "instanceHandle:searchLanGame timed out" line since the first spawn: the same line appears when the UDP 16000 NAT
# rule is missing, so the rule comes first. When this script applied it this boot (marker equals boot_id) it says so and asks nothing; else
# the NAT offer of install (nat_offer: block, default-No question, EOF is No) pauses this tick, so the one-second stdin read waits and the
# answer is never taken for a restart request. The log is the launcher's own, untrusted output: only a fixed-string count is taken, none of
# its text is printed or evaluated. Launch never asks before a failure and never probes the rule.
lan_hint_scan() {
  local n
  [ "$LAN_HINTED" = 0 ] || return 0
  n=$(grep -cF 'instanceHandle:searchLanGame timed out' "$W3C_LOG" 2> /dev/null)
  n=${n:-0}   # a missing log prints no count
  if [ "${1:-}" = base ]; then
    LAN_BASE=$n
    return 0
  fi
  [ "$n" -ge "$LAN_BASE" ] || LAN_BASE=0   # the log was truncated or replaced
  [ "$n" -gt "$LAN_BASE" ] || return 0
  LAN_HINTED=1
  say 'LAN test failed: check the UDP 16000 NAT rule (plan.md section 5 step 9).'
  if nat_marker_ok; then
    printf ' NAT rule applied this boot (by w3c-linux); if you removed it since, delete %s.' "$NAT_MARK"
  else
    printf '\n'
    nat_offer
    if no_tty; then
      say "To retest: use the launcher's LAN test, or close W3Champions and start it again from the menu."
    else
      say "To retest: use the launcher's LAN test, or press Enter here and then close the W3Champions window; it starts again by itself."
    fi
  fi
  if [ "${W3C_LAUNCH_BAT:-}" != 1 ]; then
    printf ' If the rule is active and this is a second or later start, close the launcher and run: %sW3C_LAUNCH_BAT=1 %s launch%s' "$C_BOLD" "$BIN_NAME" "$C_RESET"
  fi
  printf '\n'
}

# follow_launcher: polls once a second. 0 W3Champions.exe was seen and is gone, 1 it never appeared within START_MAX seconds, 2 pgrep cannot tell,
# 3 it was seen and is gone after the user asked for a restart. The run lock (fd 9) is released at the first sighting so doctor works during
# play. Never signals anything. While stdin is open the tick is a one-second read: an empty line asks for a restart, other
# text is ignored and EOF falls back to sleep. ponytail: a half-typed line is dropped when the read times out.
follow_launcher() {
  local seen=0 waited=0 st eof=0 req=0 line rc
  LAUNCHER_UP=0
  # stdin is never read without a terminal, so the tick is sleep 1 and no Enter restart is offered
  ! no_tty || eof=1
  START_MAX=30
  case ${W3C_START_WAIT_SECS:-} in '' | *[!0-9]* | ?????????*) ;; *) START_MAX=$((10#$W3C_START_WAIT_SECS)) ;; esac
  while :; do
    launcher_running
    st=$?
    lan_hint_scan
    case $st in
      0)
        if [ "$seen" = 0 ]; then seen=1; exec 9>&-; fi
        LAUNCHER_UP=$((LAUNCHER_UP + 1)) ;;
      1)
        [ "$seen" = 1 ] && return $((req ? 3 : 0))
        [ "$waited" -ge "$START_MAX" ] && return 1 ;;
      *)
        printf -v line 'launch: cannot check processes (pgrep exit %s); stopped waiting, W3Champions keeps running' "$PGREP_RC"
        say '%s\n' "$line"
        desk_notify normal "$line"
        return 2 ;;
    esac
    if [ "$eof" = 0 ]; then
      line=x
      read -r -t 1 line
      rc=$?
      if [ "$rc" = 0 ] && [ -z "$line" ]; then
        req=1
        say 'Restart requested: close the W3Champions window; it starts again once it has exited (Ctrl-C here leaves it closed)\n' >&2
      elif [ "$rc" -le 128 ] && [ "$rc" != 0 ]; then
        eof=1
      fi
    fi
    [ "$eof" = 0 ] || sleep 1
    [ "$seen" = 1 ] || waited=$((waited + 1))
  done
}

# launch: runs the launcher inside Battle.net's container, starting Battle.net first when it is down; this terminal follows it.
cmd_launch() {
  local n msg mode=nsenter where="in Battle.net's container" target bat=0 log_off=0
  # a menu or dock start has no terminal: every line goes to launch.log and the user is reached through dialogs and notifications
  if no_tty; then
    # lines are appended here; the rotation waits until this run holds the lock and no launcher runs (below), so a repeat click never moves a running session's log
    # log_off is the size launch.log had on open: everything after it is this run's own output
    { mkdir -p -- "$CACHE_DIR" && exec >> "$LAUNCH_LOG" 2>&1 && log_off=$(stat -c %s -- "$LAUNCH_LOG" 2> /dev/null || echo 0); } || :
    # no escape byte or tag in the log, even when stdout was a terminal at source time
    # shellcheck disable=SC2034 # read by say and emit in lib/common.sh
    C_PASS='' C_WARN='' C_FAIL='' C_SKIP='' C_BOLD='' C_RESET='' TAG=''
    say '== %s launch (no terminal)\n' "$(date '+%F %T')"
    # every later stop is a dialog, so no usable zenity means refusing now, before any check, lock or network call
    if ! use_zenity; then
      say 'zenity is required to launch from the menu: sudo pacman -S zenity, or run %s launch from a terminal\n' "$BIN_NAME"
      desk_notify critical "zenity is required to launch from the menu: sudo pacman -S zenity, or run $BIN_NAME launch from a terminal"
      return 1
    fi
  fi
  # the target for this run only, nothing is remembered; checked before any check, lock or network call
  case ${W3C_LAUNCH_BAT:-} in
    '' | 0) ;;
    1) bat=1 ;;
    *)
      launch_stop 'launch: W3C_LAUNCH_BAT must be 0 or 1, for example: W3C_LAUNCH_BAT=1 %s launch\n' "$BIN_NAME" >&2
      return 2 ;;
  esac
  # shellcheck disable=SC2034 # CMD is read by fetch_verify_extract in lib/proton.sh, QUIET_PASS by emit in lib/common.sh
  CMD=launch FAILS=0 QUIET_PASS=1
  run_checks
  if [ "$FAILS" -gt 0 ]; then
    launch_stop 'launch: fix the failed checks above, then rerun (%s doctor shows every check)\n' "$BIN_NAME"
    return 1
  fi
  if [ ! -f "$W3C_EXE" ]; then
    launch_stop 'launch: W3Champions is not installed in the prefix: run %s install\n' "$BIN_NAME"
    return 1
  fi
  if ! type -P setsid > /dev/null; then
    launch_stop 'setsid (util-linux) is missing; install it with your package manager, then rerun\n'
    return 1
  fi
  # Launcher 1.6.x writes one log per UTC day under the user profile (seen on the 04-05 run).
  # ponytail: picked once per launch, a session across UTC midnight keeps reading the old day's file.
  W3C_LOG=$PREFIX/drive_c/users/steamuser/W3Champions/logs/w3champions.$(date -u +%F).log
  W3C_BAT="$PREFIX/drive_c/Program Files/W3Champions/W3Champions.bat"
  acquire_lock
  # the only "already running" test; it must come before any spawn, as the umu client's own command line contains W3Champions.exe
  launcher_running
  case $? in
    0)
      say 'W3Champions is already running; bring its window forward\n'
      return 0 ;;
    2)
      launch_stop 'launch: cannot check whether W3Champions is running (pgrep failed); nothing was started\n'
      return 1 ;;
  esac
  # this run starts the launcher: the earlier sessions (the first log_off bytes) become launch.log.1 and this run's lines stay in launch.log (D-09); GNU head -c reads exactly log_off bytes, so cat continues at this run's header
  # ponytail: a line another run appends between the cat and the exec is lost; the run lock keeps two rotations from overlapping
  if no_tty && [ "$log_off" -gt 0 ]; then
    { { head -c "$log_off" > "$LAUNCH_LOG.1" && cat > "$LAUNCH_LOG.new"; } < "$LAUNCH_LOG" && mv -f -- "$LAUNCH_LOG.new" "$LAUNCH_LOG" && exec >> "$LAUNCH_LOG" 2>&1; } || :
  fi
  # Launcher-update preflight under the lock: information only, never asks, never writes, never blocks beyond curl's 5 s
  if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    emit warn display 'neither DISPLAY nor WAYLAND_DISPLAY is set: Battle.net and W3Champions need a graphical session (run launch from your desktop session)'
  fi
  if ! is_w3c_runner "$BN_RUNNER" || ! build_complete "$(runner_dir "$BN_RUNNER")"; then
    emit warn runner "Battle.net runs on $(runner_label "$BN_RUNNER"), not an installed W3C build: the launcher's VerifyJob check will fail (run $BIN_NAME install)"
  fi
  launcher_status 5
  if [ "$L_NEED" = update ]; then
    printf -v msg 'newer W3Champions %s available (installed %s): run %s update' "$L_LATEST" "$L_CUR" "$BIN_NAME"
    say '%s\n' "$msg"
    desk_notify normal "$msg"
  elif [ -z "$L_LATEST" ]; then
    emit warn launcher "could not check for a newer launcher ($L_ERR)"
  fi
  if ! bus_up; then
    start_battlenet
    n=$?
    [ "$n" != 2 ] || return 1
    if [ "$n" = 1 ]; then
      emit warn bus "Battle.net container com.steampowered.App$APPID not found after $BUS_MAX s"
      # never silent, never the default
      if ! ask 'Battle.net container not found; game attach will likely fail (umu #283). Start the launcher in a separate container with PROTON_VERB=run anyway?' N; then
        if [ "$BACKEND" = umu ]; then
          launch_stop 'launch: not started; wait until Battle.net is up (started through umu-run), then rerun %s launch\n' "$BIN_NAME"
        else
          launch_stop 'launch: not started; wait until Battle.net is up in Faugus, then rerun %s launch\n' "$BIN_NAME"
        fi
        return 1
      fi
      mode=run where='in a separate container (PROTON_VERB=run)'
    fi
  fi
  wait_enter 'Sign in to Battle.net if it asks, then press Enter' || return 1
  # the launcher refuses to start without the game's user data folder, and only the game creates it
  while [ ! -d "$PREFIX/drive_c/users/steamuser/Documents/Warcraft III" ]; do
    wait_enter "Warcraft III's user data folder is missing ($PREFIX/drive_c/users/steamuser/Documents/Warcraft III). The launcher refuses to start without it and only the game creates it: start Warcraft III once from Battle.net (Battle.net -> Warcraft III -> Play), close it, then press Enter to check again" || return 1
  done
  target=$W3C_EXE
  if ! write_bat; then
    if [ "$bat" = 1 ]; then
      launch_stop 'launch: cannot write %s\n' "$W3C_BAT"
      return 1
    fi
    emit warn bat "cannot write $W3C_BAT; the .bat target is unavailable"
  fi
  [ "$bat" = 0 ] || target=$W3C_BAT
  launch_cmd "$mode" "$target"
  if [ ! -f "$PREFIX/drive_c/Program Files/Blizzard/Bonjour Service/mDNSResponder.exe" ]; then   # a file check, no state file
    msg="First run: the launcher will install Bonjour and run a LAN test ('WC3 NOT READY' until it passes). Then sign in to Battle.net inside the launcher. If sign-in crashes (ole32), see $BIN_NAME doctor."
    say '%s\n' "$msg"
    desk_notify normal "$msg"
  fi
  say "Play: use the launcher's Play button; if the game does not start, press Play in Battle.net while the launcher stays open.\n"
  lan_hint_scan base   # only log lines written from now on count
  spawn_launcher || return 1
  mon_start "$([ "$bat" = 1 ] && echo bat || echo exe)" "$mode"
  trap 'mon_stop; cleanup_staging' EXIT   # every return path and TERM; install's own cleanup_staging trap is kept
  say 'Started W3Champions %s; this terminal waits until it exits (Wine output: %s)\n' "$where" "$WINE_LOG"
  # the Enter restart is offered on a terminal only
  if ! no_tty; then
    say 'If W3Champions says it cannot find the Warcraft III user data folder: start Warcraft III once from Battle.net and close it, press Enter here, then close the W3Champions window; it starts again by itself.\n' >&2
  fi
  while :; do
    follow_launcher
    n=$?
    [ "$n" = 3 ] || break
    # the launcher is already gone; same command, same container, never a kill
    wait "$LAUNCHER_PID"
    say 'Restarting W3Champions\n'
    spawn_launcher || return 1
  done
  case $n in
    0)
      # .bat mode: the pgrep above does not see umu-run's own end, so a wait could block without bound
      n='n/a: started through W3Champions.bat'
      if [ "$bat" = 0 ]; then
        wait "$LAUNCHER_PID"
        n=$?
      fi
      say 'W3Champions exited (status %s); Wine log: %s; launcher log: %s\n' "$n" "$WINE_LOG" "$W3C_LOG"
      # ponytail: 10 ticks is about 10 s; a launcher that dies later for the same reason gets the plain exit text
      if [ "$LAUNCHER_UP" -lt 10 ]; then
        desk_notify normal "W3Champions closed right after it started (status $n): start Warcraft III once from Battle.net, close it, then start W3Champions again from the menu. Details: $LAUNCH_LOG"
      else
        case $n in '' | 0 | *[!0-9]*) ;; *) desk_notify normal "W3Champions exited (status $n); see $LAUNCH_LOG" ;; esac
      fi
      return 0 ;;
    1)
      n='n/a: started through W3Champions.bat'
      if [ "$bat" = 0 ]; then
        wait "$LAUNCHER_PID"
        n=$?
      fi
      launch_stop 'launch: W3Champions did not start within %s s (status %s); Wine log: %s\n' "$START_MAX" "$n" "$WINE_LOG"
      return 1 ;;
  esac
  return 1
}
