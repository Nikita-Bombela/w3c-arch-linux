# shellcheck shell=bash disable=SC2034
# Why SC2034 is off: STEAM_COLD is read by follow_launcher in lib/launch.sh, which shellcheck cannot see when it checks this file alone.
# The Steam arm of launch (Phase 20): Steam starts the shortcut through its own Play path (`steam steam://rungameid/<gameid>`), this file follows the
# real W3Champions.exe, runs the match monitor and ends with the session. It never writes a Steam file; the only processes it ends are the user's stale Bonjour responders and Edge updaters, in any prefix (steam_start).

STEAM_COLD=0   # 1 when this run had to start Steam itself; follow_launcher reads it for the longer start wait (D-02)
STEAM_WRAP_NAT_MARK=$W3C_STATE/wrap-nat-notified   # the boot id of the boot steam-wrap last sent the NAT notification in (D-11, RESEARCH A5)
STEAM_WRAP_NV_MARK=$W3C_STATE/wrap-nvidia-notified   # the boot id of the boot steam-wrap last sent the NVIDIA notification in (D-08)
STEAM_WRAP_SWAP_MARK=$W3C_STATE/wrap-swap-done   # the boot id of the boot steam-wrap last swapped W3Champions.exe for Battle.net.exe in (WR-02: one swap per boot)

# wrap_once MARKFILE: returns 0 when steam-wrap has not yet notified for MARKFILE this boot and records this boot; with no readable boot id it returns 0
# every time and records nothing.
wrap_once() {
  local b='' m=''
  [ ! -r "$PROC_DIR/sys/kernel/random/boot_id" ] || read -r b < "$PROC_DIR/sys/kernel/random/boot_id"
  [ ! -r "$1" ] || read -r m < "$1"
  if [ -z "$b" ] || [ "$b" != "$m" ]; then
    [ -z "$b" ] || write_state "$1" "$b" || :
    return 0
  fi
  return 1
}

# wrap_spent MARKFILE: returns 0 when MARKFILE holds this boot's id, the read-only half of wrap_once (it records nothing); with no readable boot id it returns 1.
wrap_spent() {
  local b='' m=''
  [ ! -r "$PROC_DIR/sys/kernel/random/boot_id" ] || read -r b < "$PROC_DIR/sys/kernel/random/boot_id"
  [ ! -r "$1" ] || read -r m < "$1"
  [ -n "$b" ] && [ "$b" = "$m" ]
}

# steam_gameid APPID: the 64-bit game id Steam's URL handler takes for a non-Steam shortcut: the appid in the high 32 bits, 0x02000000 below.
# Bash arithmetic is signed and a shortcut appid always has its top bit set, so the value overflows to negative; %u prints it unsigned.
steam_gameid() {
  printf '%u' $(( ($1 << 32) | 0x02000000 ))
}

# restart_grace: how many seconds without a launcher and without the shortcut's reaper end a Steam session (D-20: the launcher restarts itself
# after login). W3C_RESTART_GRACE_SECS when it is one to eight digits, else 20.
# ponytail: 20 s is unmeasured (RESEARCH A2); plan 20-08's live run U5 records the real gap and tunes it.
restart_grace() {
  case ${W3C_RESTART_GRACE_SECS:-} in
    '' | *[!0-9]* | ?????????*) printf '20' ;;
    *) printf '%s' $((10#$W3C_RESTART_GRACE_SECS)) ;;
  esac
}

# steam_session_up: 0 when the reaper Steam started for the shortcut's appid runs, else 1 (also when pgrep cannot tell).
steam_session_up() {
  pgrep -u "$UID" -f "$(steam_reaper_re "$ST_APPID")" > /dev/null || return 1
}

# steam_start: hands the shortcut to the user's Steam, which starts it the way the Play button does. Sets STEAM_COLD. Returns 1 after a stop line.
# Only reached when no real launcher runs, so the stale Bonjour responders and Edge updaters of earlier sessions go first, as in spawn_launcher.
# kill_updater matches the command line of every process of this user, so a Faugus or umu session's responder in another prefix ends too.
steam_start() {
  local id
  if ! type -P steam > /dev/null; then
    launch_stop 'launch: steam is not on PATH: install the native Steam package (Flatpak Steam is not supported)\n'
    return 1
  fi
  STEAM_COLD=0
  if ! steam_running; then
    STEAM_COLD=1
    say 'Steam is not running; starting it, then the shortcut\n'
  fi
  kill_updater 'mDNSResponder\.exe'
  kill_updater
  id=$(steam_gameid "$ST_APPID")
  if ! { mkdir -p -- "$CACHE_DIR" && printf '\n== %s steam steam://rungameid/%s\n' "$(date '+%F %T')" "$id" >> "$WINE_LOG"; }; then
    launch_stop 'launch: cannot write %s\n' "$WINE_LOG"
    return 1
  fi
  # Never waited on: with Steam down this process is the Steam client itself and lives as long as Steam does (RESEARCH Pitfall 7). fd 9 and 8
  # are closed so a long-lived Steam never holds the run lock or the monitor lock.
  # ponytail: a cold-started Steam client's output shares wine.log for its whole life; give it its own file if that log grows too noisy.
  setsid steam "steam://rungameid/$id" 9>&- 8>&- < /dev/null >> "$WINE_LOG" 2>&1 &
}

# steam_notify TEXT: one desktop notification, also on a terminal (D-06: by the time this fires the game is in front of the user). The timeout keeps a
# hung notification daemon from stalling the follow loop. TEXT is fixed wording plus numbers, never process or log text.
steam_notify() {
  type -P notify-send > /dev/null || return 0
  timeout 5 notify-send -u normal W3Champions "$1" < /dev/null > /dev/null 2>&1 || :
}

# steam_attach_diag: D-06, the attach check that fits the target model: the real launcher and the real game share one mount namespace, and one
# wineserver serves the prefix. Returns 1 while no real Warcraft III.exe runs (not run yet), else 0 after looking once; says nothing when all is
# well or when it cannot tell (a link or the pgrep count unreadable), else one warn row and one notification. Read-only: it never stops, signals or
# tallies anything. Namespace ids change across launches and at the launcher's self-restart, so the two live pids are compared at one moment.
steam_attach_diag() {
  local g='' w='' mw mg n why='' msg
  read -r g < <(pgrep -u "$UID" -f "$STEAM_WC3_RE")
  [ -n "$g" ] || return 1
  read -r w < <(pgrep -u "$UID" -f "$STEAM_W3C_RE")
  [ -n "$w" ] || return 0
  mw=$(readlink "$PROC_DIR/$w/ns/mnt" 2> /dev/null) || return 0
  mg=$(readlink "$PROC_DIR/$g/ns/mnt" 2> /dev/null) || return 0
  n=$(wineserver_count) || return 0
  [ "$mw" != "$mg" ] || [ "$n" != 1 ] || return 0
  [ "$mw" = "$mg" ] || why='the launcher and the game are in different mount namespaces'
  if [ "$n" != 1 ]; then
    [ -z "$why" ] || why+=' and '
    why+="$n wineservers run for this prefix"
  fi
  msg="W3Champions and Warcraft III are not in one Wine container ($why): the game may not attach to the launcher; nothing was stopped"
  emit warn attach "$msg"
  steam_notify "$msg"
  return 0
}

# steam_follow: follows the session to its end. follow_launcher returns 3 only after the Steam grace window saw neither the launcher nor the
# reaper, so on an Enter restart the shortcut is gone and the identical call runs again (D-04); the monitor started with the first start keeps
# running. Returns launch's status.
steam_follow() {
  local n
  # the Enter restart is offered on a terminal only
  if ! no_tty; then
    say 'Press Enter here, then close the W3Champions window, to start it again through Steam (Ctrl-C here leaves it closed)\n' >&2
  fi
  while :; do
    follow_launcher
    n=$?
    [ "$n" = 3 ] || break
    say 'Restarting W3Champions through Steam\n'
    steam_start || return 1
  done
  case $n in
    0)
      say 'W3Champions exited; launcher log: %s\n' "$W3C_LOG"
      # ponytail: 10 ticks is about 10 s; a launcher that dies later for the same reason gets the plain exit text
      if [ "$LAUNCHER_UP" -lt 10 ]; then
        desk_notify normal "W3Champions closed right after it started; details: $LAUNCH_LOG"
      fi
      return 0 ;;
    1)
      launch_stop 'launch: W3Champions did not start within %s s; check the shortcut in Steam and %s\n' "$START_MAX" "$WINE_LOG"
      return 1 ;;
  esac
  return 1
}

# steam_wv2_tag: W3C_WRAPPER_WEBVIEW_FLAGS cannot reach Steam's launch, which takes its environment from the shortcut's Launch Options, so a set value is
# ignored with one note. The variable then holds the shortcut's own WEBVIEW2 value (empty is `off`), which is what mon_tag records.
steam_wv2_tag() {
  if [ -n "${W3C_WRAPPER_WEBVIEW_FLAGS+x}" ]; then
    say "W3C_WRAPPER_WEBVIEW_FLAGS is ignored under the Steam backend: the shortcut's Launch Options set WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS\n"
  fi
  W3C_WRAPPER_WEBVIEW_FLAGS=$(steam_opts_wv2)
}

# steam_opts_wrapped: the stored Launch Options carry an executable steam-wrap (launch then leaves the monitor, and the outdated-WC3 Play route, to it).
steam_opts_wrapped() { steam_opts_wrap > /dev/null && [[ $(steam_opts_problems) != *"steam-wrap's command"* ]]; }

# steam_launch [attach]: the whole Steam launch after the shared preamble of cmd_launch. Without an argument the launcher is not running yet; with
# `attach` (D-03) it already is, so nothing is started but the monitor (whose own lock test prints the held line when another one runs).
steam_launch() {
  if [ "${1-}" = attach ]; then
    lan_hint_scan base   # only log lines written from now on count
    steam_wv2_tag
    mon_start exe steam
    trap 'mon_stop; cleanup_staging' EXIT
    say 'W3Champions is already running; following it until it exits\n'
    steam_follow
    return
  fi
  # D-20: the launcher refuses to start without the game's user data folder and only the game creates it; Steam is not asked until it exists
  if [ ! -d "$PREFIX/drive_c/users/steamuser/Documents/Warcraft III" ]; then
    launch_stop "launch: Warcraft III's user data folder is missing (%s); the launcher refuses to start without it: run %s install, its Steam steps start Warcraft III once\n" \
      "$PREFIX/drive_c/users/steamuser/Documents/Warcraft III" "$BIN_NAME"
    return 1
  fi
  # no first_run_note here: it tests the Bonjour path of the Battle.net prefix, which the Steam prefix never holds, so it would fire on every launch
  say "Play: use the launcher's Play button.\n"   # no Battle.net runs under Steam, so the Battle.net half of the Faugus line does not apply
  lan_hint_scan base   # only log lines written from now on count
  steam_start || return 1
  steam_wv2_tag
  # Launch Options that carry an executable steam-wrap start their own monitor on the Play path, which tallies this session too. One launched here
  # would die with Ctrl-C while steam-wrap's own was refused by the held lock (Claude's discretion, Path A), so launch leaves it to steam-wrap.
  if steam_opts_wrapped; then
    # ponytail: launch cannot see whether steam-wrap's monitor started (prefix not found, log redirect failed, tail or flock missing), so it names the log
    say 'Match monitor: steam-wrap should start it from the Launch Options; if no tally follows, check %s\n' "$LAUNCH_LOG"
  else
    mon_start exe steam
  fi
  trap 'mon_stop; cleanup_staging' EXIT   # every return path and TERM; install's own cleanup_staging trap is kept
  say 'Started the Steam shortcut (steam://rungameid/%s); this terminal waits until W3Champions exits (Steam output: %s)\n' "$(steam_gameid "$ST_APPID")" "$WINE_LOG"
  steam_follow
}

# cmd_steam_wrap COMMAND ARGS...: what Steam runs from the shortcut's Launch Options on every Play (`... steam-wrap %command%`, D-08). It finds the
# prefix from Steam's environment (D-10), runs the NAT, NTP and NVIDIA preflight without asking, logs it to launch.log, starts the match monitor in the
# background and ends by exec'ing COMMAND ARGS unchanged: Steam's own stdio, fds and exit status. Play must never be blocked (D-11), so no path
# before the exec prompts, opens a dialog, resolves a backend or runs Python, and the preflight group ends `|| :`. The only network call before the exec
# is one GET of Blizzard's Warcraft III version list capped at about 2 s (D-17); a timeout, an offline host or an unparsable answer says nothing.
# The one exception to unchanged is the documented outdated-WC3 swap (D-15): only after a successful version check that finds Warcraft III behind, the last
# argument W3Champions.exe becomes the prefix's Battle.net.exe (when that file exists) and no monitor starts.
# The group is redirected, never `exec >>`: the game keeps Steam's stdout and stderr. The variables the monitor needs are set only for the
# mon_start call, so the game's environment stays exactly Steam's.
# ponytail: only the notification is once per boot; the line and the notification apply only when w3c-linux did not apply the rule this boot and no
# active w3c-nat.service persists it, so a user who keeps the rule by other means still sees the launch.log line on every Play ("ignore this").
cmd_steam_wrap() {
  local id='' dp=${STEAM_COMPAT_DATA_PATH-} pfx='' fixes=() ntp='' body='' own8=1 own9=1 swap='' last='' bnet='' mon_off=''
  if [ "$#" -eq 0 ]; then
    printf "usage: %s steam-wrap %%command%% (set it in the Steam shortcut's Launch Options)\n" "$BIN_NAME" >&2
    return 2
  fi
  # an fd 8 or 9 already open on entry is Steam's, not ours: the monitor lock would clobber 8, and neither is closed before the exec
  { : >&8; } 2> /dev/null && own8=0
  { : >&9; } 2> /dev/null && own9=0
  if mkdir -p -- "$CACHE_DIR" 2> /dev/null; then
    {
      printf '== %s steam-wrap\n' "$(date '+%F %T')"
      id=$(steam_appid "${SteamAppId-}") || id=''
      # T-20-19: the data path must be absolute and end in the appid, and hold the prefix and the launcher, or no monitor tails it
      if [ -n "$id" ] && [[ $dp == /* ]] && [ "${dp##*/}" = "$id" ] && [ -d "$dp/pfx/drive_c" ]; then pfx=$dp/pfx; fi
      if [ -z "$pfx" ]; then
        printf "steam-wrap: the prefix was not found from Steam's environment (SteamAppId, STEAM_COMPAT_DATA_PATH); no match monitor this session\n"
        fixes+=("the match monitor is off for this session (Steam did not pass the shortcut's prefix)")
      elif [ "$own8" = 0 ]; then
        printf "steam-wrap: Steam passed its own file descriptor 8, which the monitor lock would overwrite; no match monitor this session\n"
        mon_off='the match monitor is off for this session (Steam passed file descriptor 8)'
      fi
      if ! nat_marker_ok; then
        printf 'steam-wrap: the LAN-test NAT rule was not applied by w3c-linux this boot: run %s install for the NAT rule (ignore this if you keep the rule yourself)\n' "$BIN_NAME"
        ! wrap_once "$STEAM_WRAP_NAT_MARK" || fixes+=("run $BIN_NAME install for the NAT rule")
      fi
      if type -P timedatectl > /dev/null; then
        ntp=$(timeout 2 timedatectl show -p NTP --value 2> /dev/null) || ntp=''
        if [ -n "$ntp" ] && [ "$ntp" != yes ]; then
          printf 'steam-wrap: NTP is off and the launcher checks clock skew: run sudo timedatectl set-ntp true\n'
          fixes+=('run sudo timedatectl set-ntp true')
        fi
      fi
      nvidia_state
      if [ "$NV_STATE" = mismatch ]; then
        printf 'steam-wrap: %s\n' "$NV_MSG"
        ! wrap_once "$STEAM_WRAP_NV_MARK" || fixes+=("$NV_MSG")
      fi
      if [ -n "$pfx" ]; then
        # WC3-01: one capped GET of Blizzard's list; every failure is silent (D-17). PREFIX is set for this one call only, so the game's environment stays Steam's
        WC3_DIR=$(PREFIX=$pfx wc3_install_dir)
        [ -d "$WC3_DIR" ] || WC3_DIR="$pfx/drive_c/Program Files (x86)/Warcraft III"
        wc3_buildinfo "$WC3_DIR"
        wc3_status 1 2
        if [ "$WC3_STATE" = outdated ]; then
          # D-15 (spike D, PASS): the last argument is the launcher's exe, so Battle.net.exe of the same prefix replaces it and Battle.net updates the game.
          # WR-02: once per boot, so a verdict Battle.net cannot clear never traps Play; the mark is spent only by a real swap.
          last=${!#} last=${last##*[/\\]} bnet="$pfx/drive_c/Program Files (x86)/Battle.net/Battle.net.exe"
          if [ "${last,,}" = w3champions.exe ] && [ -f "$bnet" ] && wrap_once "$STEAM_WRAP_SWAP_MARK"; then
            swap=$bnet
            printf 'steam-wrap: Warcraft III %s is outdated (current %s): starting Battle.net instead of W3Champions so it can update\n' "$WC3_BUILD" "$WC3_CURRENT"
            fixes+=('Warcraft III needs an update: update in Battle.net, quit, press Play again')
          else
            printf 'steam-wrap: %s\n' "$(wc3_msg "run $BIN_NAME update")"
            fixes+=("$(wc3_msg "run $BIN_NAME update")")
          fi
        fi
      fi
      # a swap starts no monitor anyway, so its notification does not say the monitor is off
      [ -z "$mon_off" ] || [ -n "$swap" ] || fixes=("$mon_off" "${fixes[@]}")
      if [ "${#fixes[@]}" -gt 0 ]; then
        printf -v body '%s; ' "${fixes[@]}"
        steam_notify "steam-wrap: ${body%; }"
      fi
      # a string pasted on another shortcut never tails another prefix: the launcher must be in it
      if [ -z "$swap" ] && [ -n "$pfx" ] && [ "$own8" = 1 ] && [ -f "$pfx/drive_c/Program Files/W3Champions/W3Champions.exe" ]; then
        BACKEND=steam PREFIX=$pfx ST_APPID=$id MON_POLL=10 W3C_WRAPPER_WEBVIEW_FLAGS=${WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS-} mon_start exe wrap
      fi
    } >> "$LAUNCH_LOG" 2>&1 < /dev/null || :
  fi
  # the monitor's subshell keeps its own fd 8, so only it holds the lock; the game gets neither lock, and keeps any fd Steam passed
  [ "$own8" = 0 ] || exec 8>&-
  [ "$own9" = 0 ] || exec 9>&-
  [ -z "$swap" ] || set -- "${@:1:$#-1}" "$swap"   # no cd and no variable dropped: spike D ran Battle.net as is, from the shortcut's Start In
  exec "$@"
}
