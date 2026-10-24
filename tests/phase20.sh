#!/usr/bin/env bash
# Phase 20 fixture check: launch under the Steam backend (STEAM-09). It runs on the harness of tests/phase19.sh, so the same fake HOME, shims and
# invariants apply. `steam` is a recording shim here: its argv goes to marks/steam, and the sleep shim plays the shortcut coming up (the lines of
# T/fix/on-steam join the process table on the first tick after each steam call) and the timeline of T/fix/timeline. No case runs Steam, Wine or a
# network call outside the fixtures.
# Usage: bash tests/phase20.sh [GLOB]   (GLOB filters on display names such as steam-launch-tracer)
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=phase19.sh
source "$(dirname "${BASH_SOURCE[0]}")/phase19.sh"

# this suite has its own cases only
mapfile -t P19_CASES < <(compgen -A function t_)
unset -f "${P19_CASES[@]}"

# pgrep and pkill (the process rules and the Edge updater) and steam (a recording shim) are expected here; the rest must never run.
# xdg-open has a marker shim in steam_launch_setup, so a launch that opens a URL fails the case.
FORBIDDEN=(wine wineserver faugus-launcher steam-runtime-launch-client sudo umu-run nft iptables xdg-open)

# the gameid Steam's URL handler takes for appid 3389133332, computed independently of the script (3389133332 << 32 | 0x02000000)
GAMEID=14556216822757064704

# ---------- helpers ----------

# w3c_line PID and reaper_line PID: the fix/procs lines (pid|comm|cmdline) of the real launcher and of the shortcut's reaper, as the spike recorded them.
w3c_line() { printf '%s|W3Champions.exe|C:\\Program Files\\W3Champions\\W3Champions.exe\n' "$1"; }
reaper_line() { printf '%s|reaper|/x/ubuntu12_32/reaper SteamLaunch AppId=3389133332 -- /x/proton waitforexitandrun /x/W3Champions.exe\n' "$1"; }

# decoy_lines: the other processes whose command lines name W3Champions.exe or the reaper, and which must never count as the launcher or the session.
decoy_lines() {
  printf '%s\n' \
    '4101|srt-bwrap|/x/srt-bwrap --unshare-pid -- /x/pv-adverb -- /x/proton waitforexitandrun /x/W3Champions.exe' \
    '4102|python3|python3 /x/proton waitforexitandrun /x/W3Champions.exe' \
    '4103|steam.exe|c:\windows\system32\steam.exe /x/W3Champions.exe' \
    '4104|bash|bash /x/w3c-linux.sh steam-wrap /x/ubuntu12_32/steam-launch-wrapper -- /x/ubuntu12_32/reaper SteamLaunch AppId=3389133332 -- /x/W3Champions.exe'
}

# steam_shim: the recording steam command. The sleep shim brings the shortcut up (fix/on-steam), so the follow loop never races a backgrounded
# shim; only a case that reads stdin from a FIFO, where the tick is a real read and no sleep runs, lets this shim append fix/on-steam-now itself.
steam_shim() {
  cat > "$T/bin/steam" <<'SH'
#!/bin/sh
printf '%s\n' "$0 $*" >> "$MARK/steam"
[ ! -f "$FIX/on-steam-now" ] || cat "$FIX/on-steam-now" >> "$FIX/procs"
exit 0
SH
  chmod +x "$T/bin/steam"
}

# steam_up: a live Steam, as steam_running reads it: ~/.steam/steam.pid holds a pid whose comm is steam.
steam_up() {
  printf '4242\n' > "$T/home/.steam/steam.pid"
  mkdir -p "$T/proc/4242"
  printf 'steam\n' > "$T/proc/4242/comm"
}

# the session sleep shim body. n is this call's number. The shortcut comes up on the first tick after each steam call (fix/on-steam is appended to
# fix/procs and n is logged in fix/up); fix/timeline lines "REL OP LINE" then add (+) or drop (-) the exact process line REL ticks after that
# coming-up. A launch that never ends is cut at 500 ticks, so a wrong process rule fails a case instead of hanging it.
IFS= read -r -d '' SLEEP20 <<'SH' || true
cnt() { cat "$1" 2> /dev/null | awk 'END { print NR }'; }
n=$(cnt "$MARK/sleep")
[ "$n" -lt 500 ] || kill -9 "$PPID"
if [ "$(cnt "$MARK/steam")" -gt "$(cnt "$FIX/up")" ]; then
  [ ! -f "$FIX/on-steam" ] || cat "$FIX/on-steam" >> "$FIX/procs"
  printf '%s\n' "$n" >> "$FIX/up"
fi
last=$(tail -n 1 "$FIX/up" 2> /dev/null)
if [ -n "$last" ] && [ -f "$FIX/timeline" ]; then
  while read -r rel op text; do
    [ "$rel" = "$((n - last))" ] || continue
    case $op in
      +) printf '%s\n' "$text" >> "$FIX/procs" ;;
      -) grep -vxF -- "$text" "$FIX/procs" > "$FIX/procs.n"; mv "$FIX/procs.n" "$FIX/procs" ;;
    esac
  done < "$FIX/timeline"
fi
SH

# steam_launch_setup: a complete Steam shortcut with the backend selected and the release served, the recording steam, the sleep shim and the links
# the launch path needs. The restart grace is two ticks and the start wait is long, so only the cases that test them say otherwise.
steam_launch_setup() {
  sprep
  steam_shim
  add_link "$T" setsid
  add_link "$T" tail
  add_link "$T" timeout
  add_shim "$T" xdg-open
  sleep_shim "$T" "$SLEEP20"
  CASE_ENV=(W3C_RESTART_GRACE_SECS=2 W3C_START_WAIT_SECS=200)
  ALLOW_EXTRA+=(fix/procs fix/up)
}

# on_steam LINE...: the process lines Steam brings up when the shortcut starts.
on_steam() { printf '%s\n' "$@" > "$T/fix/on-steam"; }

# at REL OP LINE: one fix/timeline entry.
at() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$T/fix/timeline"; }

# steam_calls: the lines of marks/steam, nothing when steam never ran. steam_count N: steam ran exactly N times.
steam_calls() { [ ! -f "$T/marks/steam" ] || cat "$T/marks/steam"; }
steam_count() {
  local n
  n=$(steam_calls | grep -c .)
  [ "$n" = "$1" ] || ERRS+=("steam calls: want $1 got $n")
}

# only_state_paths: nothing changed outside the cache, the state directory and the fixture's own files; in particular nothing under the Steam root.
only_state_paths() {
  local p
  for p in "${CHANGED[@]}"; do
    case $p in
      home/.cache | home/.cache/* | home/.local/state | home/.local/state/* | fix/*) ;;
      *) ERRS+=("changed outside the cache and state: $p") ;;
    esac
  done
}

# game_line PID: the fix/procs line of the real game, as the spike recorded it (the launcher starts it with these arguments).
game_line() { printf '%s|Warcraft III.exe|C:\\Program Files (x86)\\Warcraft III\\_retail_\\x86_64\\Warcraft III.exe -launch -uid w3 -windowmode windowed\n' "$1"; }

# notify_shim and notify_calls: a recording notify-send (a '== call ==' line, then one argument per line) and its call count, as in tests/phase5.sh.
notify_shim() {
  cat > "$T/bin/notify-send" <<'SH'
#!/bin/sh
{ echo '== call =='; for a in "$@"; do printf '%s\n' "$a"; done; } >> "$MARK/notify-send"
SH
  chmod +x "$T/bin/notify-send"
}
notify_calls() {
  local n
  n=$(grep -c '^== call ==$' "$T/marks/notify-send" 2> /dev/null)
  printf '%s' "${n:-0}"
}

# ns_link PID ID: the mount namespace link of a fixture process, as the kernel shows it (a symlink whose text is mnt:[ID]).
ns_link() {
  mkdir -p "$T/proc/$1/ns"
  ln -s "mnt:[$2]" "$T/proc/$1/ns/mnt"
}

# diag_setup GAME_NS WINESERVERS: Steam is up, the shortcut starts the reaper, the launcher (pid 5001), the game (pid 5002) and the decoys, and
# all of them drop 5 ticks later, so the game is seen on at least three ticks. The launcher's mount namespace is 4026533041, the game's is
# GAME_NS; WINESERVERS wineservers of the Steam prefix run (pids 6001 and up).
diag_setup() {
  local i
  steam_launch_setup
  notify_shim
  steam_up
  on_steam "$(reaper_line 4400)" "$(w3c_line 5001)" "$(game_line 5002)" "$(decoy_lines)"
  for i in "$(reaper_line 4400)" "$(w3c_line 5001)" "$(game_line 5002)"; do at 5 - "$i"; done
  ns_link 5001 4026533041
  ns_link 5002 "$1"
  for ((i = 0; i < $2; i++)); do add_wineserver "$T" $((6001 + i)) "$(steam_pfx_server_name)"; done
}

# attach_rows: how many `warn  attach` rows the session printed.
attach_rows() { grep -c '^warn  attach  ' <<< "$OUT"; }

# nothing_tallied: the attach check never writes the tally.
nothing_tallied() { [ ! -s "$T/home/.local/state/w3c-linux/matches.log" ] || ERRS+=('matches.log was written'); }

# ---------- STEAM-09: launch ----------

# The tracer: Steam is up and the shortcut targets W3Champions.exe. launch runs one rungameid call, follows only the real launcher (the wrapper
# processes stay in the table the whole time and must not count), runs the monitor and ends when the launcher and the reaper are gone.
t_steam_launch_tracer() {
  steam_launch_setup
  steam_up
  on_steam "$(reaper_line 4400)" "$(w3c_line 4500)" "$(decoy_lines)"
  at 3 - "$(reaper_line 4400)"
  at 3 - "$(w3c_line 4500)"
  run "$T" launch
  rc_is 0
  [ "$(steam_calls)" = "$T/bin/steam steam://rungameid/$GAMEID" ] || ERRS+=("steam calls: $(steam_calls | tr '\n' '|')")
  out_has "Started the Steam shortcut (steam://rungameid/$GAMEID)"
  out_has "W3Champions exited; launcher log: $SR/steamapps/compatdata/3389133332/pfx/drive_c/users/steamuser/W3Champions/logs/w3champions.$(date -u +%F).log"
  out_has 'Match monitor: lost results and join bugs are tallied in'
  lacks_text 'First run:'   # WR-01: the Bonjour-path note is wrong for the Steam prefix, which never holds mDNSResponder.exe
  case $OUT$ERR in *'not available under the Steam backend yet'*) ERRS+=('the Steam guard still stops launch') ;; esac
  only_state_paths
  grep -qF 'Program Files\\W3Champions' "$T/marks/pgrep" 2> /dev/null || ERRS+=('pgrep never ran the Windows-path rule')
  ! grep -qE ' -f W3Champions\\\.exe$' "$T/marks/pgrep" 2> /dev/null || ERRS+=('pgrep ran the Faugus rule under Steam')
}

# D-05: a shortcut that does not start W3Champions stops launch before any lock, network call or Steam call.
t_steam_launch_target() {
  steam_launch_setup
  steam_up
  sc_edit "$SR/userdata/12345678/config/shortcuts.vdf" set 3389133332 Exe '"/x/Battle.net.exe"'
  run "$T" launch
  rc_is 1
  out_has 'launch: the shortcut does not start W3Champions: run w3c-linux.sh install'
  [ ! -e "$T/marks/steam" ] || ERRS+=('steam ran')
  [ ! -e "$T/marks/curl" ] || ERRS+=('a network call was made')
  changed_is
}

# D-20: the launcher restarts itself after login, with new pids. A gap with no real launcher while the reaper runs does not end launch, so the
# follow reaches the drop at tick 8 (the timeline removes the second launcher only then) and prints the exit line once. The gap is three ticks,
# longer than the two-tick grace, so only the reaper keeps the session alive.
t_steam_launch_gap() {
  steam_launch_setup
  steam_up
  on_steam "$(reaper_line 4400)" "$(w3c_line 4500)" "$(decoy_lines)"
  at 2 - "$(w3c_line 4500)"
  at 5 + "$(w3c_line 4501)"
  at 8 - "$(w3c_line 4501)"
  at 8 - "$(reaper_line 4400)"
  run "$T" launch
  rc_is 0
  steam_count 1
  [ "$(grep -c 'W3Champions exited' <<< "$OUT")" = 1 ] || ERRS+=('the exit line is not printed exactly once')
  [ "$(grep -c 'W3Champions closed; this terminal waits up to 2 s' <<< "$OUT")" = 1 ] || ERRS+=('the grace line is not printed exactly once')   # WR-02, only once neither launcher nor reaper runs
  # the timeline drops the reaper at tick 8, so it is gone from the table only when the follow lived that long
  ! grep -qF '4400|' "$T/fix/procs" || ERRS+=('the follow ended before the reaper dropped')
}

# D-02: Steam is not running (no live ~/.steam/steam.pid): the same call runs after one line saying so.
t_steam_launch_cold() {
  steam_launch_setup
  on_steam "$(reaper_line 4400)" "$(w3c_line 4500)"
  at 3 - "$(reaper_line 4400)"
  at 3 - "$(w3c_line 4500)"
  run "$T" launch
  rc_is 0
  out_has 'Steam is not running; starting it, then the shortcut'
  steam_count 1
  [ "$(steam_calls)" = "$T/bin/steam steam://rungameid/$GAMEID" ] || ERRS+=("steam calls: $(steam_calls | tr '\n' '|')")
}

# D-02: with Steam down and no W3C_START_WAIT_SECS the start wait is 120 s, not 30.
t_steam_launch_cold_wait() {
  steam_launch_setup
  CASE_ENV=(W3C_RESTART_GRACE_SECS=2)
  run "$T" launch
  rc_is 1
  out_has 'launch: W3Champions did not start within 120 s'
  steam_count 1
}

# Steam up and the launcher never appears: W3C_START_WAIT_SECS still sets the wait, and launch asked Steam once.
t_steam_launch_not_started() {
  steam_launch_setup
  steam_up
  CASE_ENV=(W3C_RESTART_GRACE_SECS=2 W3C_START_WAIT_SECS=3)
  run "$T" launch
  rc_is 1
  out_has 'launch: W3Champions did not start within 3 s'
  steam_count 1
}

# attach_setup: the launcher and the shortcut's reaper are already running (and the decoys), Steam is up, and the session ends 3 ticks in.
attach_setup() {
  steam_launch_setup
  steam_up
  { reaper_line 4400; w3c_line 4500; decoy_lines; } > "$T/fix/procs"
  printf '0\n' > "$T/fix/up"
  at 3 - "$(reaper_line 4400)"
  at 3 - "$(w3c_line 4500)"
}

# D-03: the real launcher already runs: no rungameid call, the monitor starts, and launch follows the launcher until it exits.
t_steam_launch_attach() {
  attach_setup
  run "$T" launch
  rc_is 0
  [ ! -e "$T/marks/steam" ] || ERRS+=('steam ran')
  out_has 'W3Champions is already running; following it until it exits'
  out_has 'Match monitor: lost results and join bugs are tallied in'
  out_has 'W3Champions exited; launcher log: '
}

# D-03: monitor.lock is held (another monitor runs): the held-lock line, no second monitor, and the follow still ends the session.
t_steam_launch_attach_held() {
  local fd
  attach_setup
  exec {fd}> "$T/home/.local/state/w3c-linux/monitor.lock"
  flock -n "$fd" || ERRS+=('the test could not take monitor.lock')
  run "$T" launch
  exec {fd}>&-
  rc_is 0
  out_has 'Match monitor already running ('
  out_has 'is held); not starting a second one.'
  lacks_text 'Match monitor: lost results'
  [ ! -e "$T/marks/steam" ] || ERRS+=('steam ran')
}

# D-04: Enter during the follow restarts through Steam: once the launcher and the reaper are gone, the identical call runs again and the monitor
# started with the first start keeps running (its tail child is the same process before and after).
t_steam_launch_restart() {
  local i mon1 mon2 polls
  steam_launch_setup
  steam_up
  printf '%s\n%s\n' "$(reaper_line 4400)" "$(w3c_line 4500)" > "$T/fix/on-steam-now"
  run_fifo "$T" launch
  wait_err 'Press Enter here, then close the W3Champions window, to start it again through Steam'
  for ((i = 0; i < 100; i++)); do
    grep -qF '4500|' "$T/fix/procs" 2> /dev/null && break
    sleep 0.1
  done
  mon1=$(pgrep -f -- "tail -F .*$SR/steamapps/compatdata" | head -n 1)
  [ -n "$mon1" ] || ERRS+=('no monitor tail is running after the first start')
  send $'\n'
  wait_err 'Restart requested: close the W3Champions window; it starts again once it has exited'
  grep -vxF -e "$(reaper_line 4400)" -e "$(w3c_line 4500)" "$T/fix/procs" > "$T/fix/procs.n"
  mv "$T/fix/procs.n" "$T/fix/procs"
  for ((i = 0; i < 100; i++)); do
    [ "$(steam_calls | grep -c .)" = 2 ] && grep -qF '4500|' "$T/fix/procs" && break
    sleep 0.1
  done
  # the follow must poll again, and see the launcher the second call brought up, before the session ends
  polls=$(grep -c . "$T/marks/pgrep")
  for ((i = 0; i < 100; i++)); do
    [ "$(grep -c . "$T/marks/pgrep")" -ge $((polls + 2)) ] && break
    sleep 0.1
  done
  mon2=$(pgrep -f -- "tail -F .*$SR/steamapps/compatdata" | head -n 1)
  [ "$mon1" = "$mon2" ] || ERRS+=("the monitor changed across the restart: [$mon1] then [$mon2]")
  grep -vxF -e "$(reaper_line 4400)" -e "$(w3c_line 4500)" "$T/fix/procs" > "$T/fix/procs.n"
  mv "$T/fix/procs.n" "$T/fix/procs"
  finish
  rc_is 0
  steam_count 2
  [ "$(steam_calls | sort -u | grep -c .)" = 1 ] || ERRS+=('the restart used a different steam call')
  out_has 'Restarting W3Champions through Steam'
  [ "$(grep -c 'Match monitor: lost results' <<< "$OUT")" = 1 ] || ERRS+=('the monitor was not started exactly once')
}

# ---------- STEAM-09: the attach check (D-06) ----------

# One container for the launcher and the game, one wineserver for the prefix: nothing is said and nothing is sent.
t_steam_attach_ok() {
  diag_setup 4026533041 1
  run "$T" launch
  rc_is 0
  [ "$(attach_rows)" = 0 ] || ERRS+=("attach rows: $(attach_rows)")
  [ "$(notify_calls)" = 0 ] || ERRS+=("notify-send calls: $(notify_calls)")
  grep -qE ' -f \^\[A-Za-z\]:.*Warcraft III' "$T/marks/pgrep" || ERRS+=('pgrep never ran the Warcraft III rule')
  nothing_tallied
}

# The game runs in another mount namespace: one warn row and one notification for the whole session (the game stays up for several ticks),
# even with a terminal, and nothing is stopped, signalled or tallied.
t_steam_attach_ns() {
  diag_setup 4026533043 1
  run "$T" launch
  rc_is 0
  [ "$(attach_rows)" = 1 ] || ERRS+=("attach rows: want 1 got $(attach_rows)")
  out_has 'the launcher and the game are in different mount namespaces'
  out_has 'nothing was stopped'
  [ "$(notify_calls)" = 1 ] || ERRS+=("notify-send calls: want 1 got $(notify_calls)")
  grep -qxF -- 'W3Champions' "$T/marks/notify-send" 2> /dev/null || ERRS+=('the notification is not titled W3Champions')
  nothing_tallied
}

# The same namespace but two wineservers of the Steam prefix: one warn row naming the count, one notification.
t_steam_attach_two() {
  diag_setup 4026533041 2
  run "$T" launch
  rc_is 0
  [ "$(attach_rows)" = 1 ] || ERRS+=("attach rows: want 1 got $(attach_rows)")
  out_has '2 wineservers run for this prefix'
  lacks_text 'different mount namespaces'
  [ "$(notify_calls)" = 1 ] || ERRS+=("notify-send calls: want 1 got $(notify_calls)")
  nothing_tallied
}

# No game all session (a decoy that only carries the game's path in its argv stays in the table): no attach line, and nothing was signalled
# beyond the two patterns kill_updater always ends.
t_steam_attach_none() {
  local l
  diag_setup 4026533043 2
  on_steam "$(reaper_line 4400)" "$(w3c_line 5001)" "$(decoy_lines)" '4105|python3|python3 /x/proton waitforexitandrun /x/Warcraft III.exe'
  run "$T" launch
  rc_is 0
  [ "$(attach_rows)" = 0 ] || ERRS+=("attach rows: $(attach_rows)")
  [ "$(notify_calls)" = 0 ] || ERRS+=("notify-send calls: $(notify_calls)")
  while IFS= read -r l; do
    case $l in
      *' -f mDNSResponder\.exe' | *' -f MicrosoftEdgeUpdate\.exe') ;;
      *) ERRS+=("pkill ran with: $l") ;;
    esac
  done < "$T/marks/pkill"
  nothing_tallied
}

# ---------- STEAM-09: the knobs that cannot reach Steam's launch, the user data folder and the idle gate ----------

# D-06 discretion: the shortcut's Target decides what starts, so W3C_LAUNCH_BAT=1 stops launch before any check, lock, network or Steam call.
t_steam_knobs_bat() {
  steam_launch_setup
  steam_up
  CASE_ENV+=(W3C_LAUNCH_BAT=1)
  run "$T" launch
  rc_is 2
  err_has 'launch: W3C_LAUNCH_BAT=1 does not apply under the Steam backend: the shortcut starts W3Champions.exe itself'
  [ ! -e "$T/marks/steam" ] || ERRS+=('steam ran')
  [ ! -e "$T/marks/curl" ] || ERRS+=('a network call was made')
  changed_is
}

# W3C_WRAPPER_WEBVIEW_FLAGS is ignored under Steam with one note, and the monitor's tag records the shortcut's own WEBVIEW2 value. The sleep shim
# writes the telemetry line to the launcher's daily log (again each 0.1 s until the monitor, which starts at the log's end, has tallied one) and
# holds the session open meanwhile, polling with the real sleep binary.
t_steam_knobs_wv2flags() {
  local log real extra
  steam_launch_setup
  steam_up
  log=$SR/steamapps/compatdata/3389133332/pfx/drive_c/users/steamuser/W3Champions/logs
  sc_edit "$SR/userdata/12345678/config/shortcuts.vdf" set 3389133332 LaunchOptions \
    'W3C_SHARED_QUERY=1 WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--disable-gpu PROTON_ENABLE_WAYLAND=0 WINE_SIMULATE_WRITECOPY=1 %command%'
  real=$(type -P sleep)
  # shellcheck disable=SC2016 # the shim body is written literally and expanded when the shim runs
  printf -v extra 'if [ "$n" = 2 ]; then\n  mkdir -p %q\n  i=0\n  while [ ! -s "$HOME/.local/state/w3c-linux/matches.log" ] && [ "$i" -lt 50 ]; do\n    printf "%%s\\n" "[2026-10-09T10:00:00Z INFO match_telemetry] PlayerMatchTelemetryReport emitted" >> %q\n    %q 0.1\n    i=$((i + 1))\n  done\nfi' \
    "$log" "$log/w3champions.$(date -u +%F).log" "$real"
  sleep_shim "$T" "$SLEEP20"$'\n'"$extra"
  ALLOW_EXTRA+=("$SP_REL/drive_c/users/steamuser/W3Champions" "$SP_REL/drive_c/users/steamuser/W3Champions/logs" "$SP_REL/drive_c/users/steamuser/W3Champions/logs/w3champions.$(date -u +%F).log")
  CASE_ENV+=(W3C_WRAPPER_WEBVIEW_FLAGS=0)
  on_steam "$(reaper_line 4400)" "$(w3c_line 4500)"
  at 3 - "$(reaper_line 4400)"
  at 3 - "$(w3c_line 4500)"
  run "$T" launch
  rc_is 0
  [ "$(grep -c 'W3C_WRAPPER_WEBVIEW_FLAGS is ignored under the Steam backend' <<< "$OUT")" = 1 ] || ERRS+=('the ignore note is not printed exactly once')
  out_has "the shortcut's Launch Options set WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS"
  grep -qE ' game-end target=exe mode=steam wv2flags=--disable-gpu$' "$T/home/.local/state/w3c-linux/matches.log" 2> /dev/null || ERRS+=("matches.log lacks the tagged game-end line, first line is: $(head -n 1 "$T/home/.local/state/w3c-linux/matches.log" 2> /dev/null)")
}

# D-20, Finding 5: the launcher refuses to start without Warcraft III's user data folder, so a shortcut prefix without it stops launch before Steam is asked.
t_steam_launch_no_userdata() {
  steam_launch_setup
  steam_up
  rm -rf "${SR:?}/steamapps/compatdata/3389133332/pfx/drive_c/users/steamuser/Documents/Warcraft III"
  run "$T" launch
  rc_is 1
  out_has "launch: Warcraft III's user data folder is missing ("
  out_has 'run w3c-linux.sh install'
  [ ! -e "$T/marks/steam" ] || ERRS+=('steam ran')
}

# T-20-09: a steam-wrap or proton process line that only carries the launcher's or the game's path in its argv never keeps the idle gate busy.
t_steam_busy_wrap() {
  msi_steam_setup
  add_proc "$T" 4001 bash 'bash /x/w3c-linux.sh steam-wrap /x/ubuntu12_32/steam-launch-wrapper -- /x/ubuntu12_32/reaper SteamLaunch AppId=3389133332 -- /x/W3Champions.exe'
  add_proc "$T" 4002 python3 'python3 /x/proton waitforexitandrun /x/W3Champions.exe'
  add_proc "$T" 4003 python3 'python3 /x/proton waitforexitandrun /x/Warcraft III.exe'
  FEED=$'y\n'
  run "$T" install
  rc_is 0
  proton_count 1
}

# ---------- STEAM-09: standalone monitor under Steam (D-18) ----------

# D-18: monitor resolves the shortcut's prefix through backend_read and takes the shared lock; a held lock is the plain already-running line.
t_monitor_steam_found() {
  local fd
  steam_launch_setup
  exec {fd}> "$T/home/.local/state/w3c-linux/monitor.lock"
  flock -n "$fd" || ERRS+=('the test could not take monitor.lock')
  run "$T" monitor
  exec {fd}>&-
  rc_is 0
  err_has 'monitor: already running ('
  case $ERR in *Faugus* | *'not available'*) ERRS+=("stderr: $ERR") ;; esac
  [ -z "$OUT" ] || ERRS+=("stdout: $OUT")
}

# D-18: no prefix is one stop line naming the shortcut (never the Faugus one), status 1, nothing changed.
t_monitor_steam_noprefix() {
  steam_launch_setup
  rm -rf "${SR:?}/steamapps/compatdata/3389133332/pfx"
  run "$T" monitor
  rc_is 1
  [ "$ERR" = "monitor: cannot find the Steam shortcut's prefix; run w3c-linux.sh doctor" ] || ERRS+=("stderr: $ERR")
  [ -z "$OUT" ] || ERRS+=("stdout: $OUT")
  changed_is
}

# D-18: no subcommand is guarded under Steam any more: neither monitor nor a launch that stops on its own rule says "not available".
t_monitor_steam_noguard() {
  local fd
  steam_launch_setup
  steam_up
  exec {fd}> "$T/home/.local/state/w3c-linux/monitor.lock"
  flock -n "$fd" || ERRS+=('the test could not take monitor.lock')
  run "$T" monitor
  exec {fd}>&-
  case $OUT$ERR in *'not available under the Steam backend yet'*) ERRS+=("monitor was guarded: $ERR") ;; esac
  CASE_ENV+=(W3C_LAUNCH_BAT=1)
  run "$T" launch
  case $OUT$ERR in *'not available under the Steam backend yet'*) ERRS+=("launch was guarded: $ERR") ;; esac
}

# ---------- STEAM-11: the Launch Options string and its judge (D-07, D-09) ----------

# set_opts VALUE: the shortcut's stored Launch Options.
set_opts() { sc_edit "$SR/userdata/12345678/config/shortcuts.vdf" set 3389133332 LaunchOptions "$1"; }

# D-07: the spike's string lacks steam-wrap: one warn row naming it and the string to paste, and doctor's exit status stays what it was (0 here).
t_launch_opts_spike() {
  sprep
  run "$T" doctor
  rc_is 0
  has_line warn 'launch options' "$(opts_warn 'missing steam-wrap')"
  changed_is
}

# D-07: no Launch Options at all names every part, in the order of the string.
t_launch_opts_none() {
  sprep
  set_opts ''
  run "$T" doctor
  rc_is 0
  has_line warn 'launch options' "$(opts_warn "$OPTS_ALL")"
}

# D-07: the complete default string passes and the row shows it as stored.
t_launch_opts_full() {
  sprep
  set_opts "$(default_opts)"
  run "$T" doctor
  rc_is 0
  has_line pass 'launch options' "$(default_opts)"
}

# D-07: extra variables and more WEBVIEW2 arguments are the user's own and still pass.
t_launch_opts_extra() {
  local s
  sprep
  s="DXVK_HUD=1 $(default_opts)"
  s=${s/--no-sandbox/--no-sandbox,--disable-gpu}
  set_opts "$s"
  run "$T" doctor
  rc_is 0
  has_line pass 'launch options' "$s"
}

# D-09: a steam-wrap command that is missing, relative, not a regular file or not executable warns with its own reason.
t_launch_opts_wrap_missing() {
  local c
  sprep
  for c in /x/nowhere/w3c-linux w3c-linux /etc/passwd /etc; do
    set_opts "$(default_opts "$c")"
    run "$T" doctor
    rc_is 0
    has_line warn 'launch options' "steam-wrap's command $c does not exist or is not executable; set the shortcut's Launch Options to: $(default_opts)"
  done
}

# D-07: launch prints the same warn row and still starts the shortcut, once.
t_launch_opts_launch() {
  steam_launch_setup
  steam_up
  on_steam "$(reaper_line 4400)" "$(w3c_line 4500)"
  at 3 - "$(reaper_line 4400)"
  at 3 - "$(w3c_line 4500)"
  run "$T" launch
  rc_is 0
  has_line warn 'launch options' "$(opts_warn 'missing steam-wrap')"
  steam_count 1
}

# D-09: a make install-user copy prints the per-user command, $HOME/.local/bin/w3c-linux, as the script sees HOME (never a realpath into lib/).
t_launch_opts_user_kind() {
  local d=$T/home/.local/lib/w3c-linux
  sprep
  mkdir -p "$d" "$T/home/.local/bin"
  cp "$ROOT/w3c-linux.sh" "$d/"
  cp -r "$ROOT/lib" "$ROOT/share" "$d/"
  local SCRIPT=$d/w3c-linux.sh
  run "$T" doctor
  has_line warn 'launch options' "missing steam-wrap; set the shortcut's Launch Options to: $(default_opts "$T/home/.local/bin/w3c-linux")"
}

# D-09, T-20-14: a clone path with a space or an apostrophe is single-quoted for the string to paste, each apostrophe as '\''.
t_launch_opts_space() {
  local d n want q=\' rep="'\\''"
  sprep
  for n in 'my dir' "it's"; do
    d=$T/$n
    mkdir -p "$d"
    cp "$ROOT/w3c-linux.sh" "$d/"
    cp -r "$ROOT/lib" "$ROOT/share" "$d/"
    want="$(realpath "$T")/$n/w3c-linux.sh"
    want="'${want//$q/$rep}'"
    local SCRIPT="$d/w3c-linux.sh"
    run "$T" doctor
    has_line warn 'launch options' "missing steam-wrap; set the shortcut's Launch Options to: $(default_opts "$want")"
  done
}

# D-09: every retarget back to Battle.net.exe says its Launch Options replace the current ones, so steam-wrap goes with them.
t_launch_opts_revert_note() {
  srev_full proton_experimental
  run "$T" revert
  rc_is 1
  out_line 'Step 2: Point the shortcut back at Battle.net.exe'
  out_line '    Launch Options: WINE_SIMULATE_WRITECOPY=1 PROTON_ENABLE_WAYLAND=0 %command%'
  out_line '    These Launch Options replace the current ones; steam-wrap, if it is there, goes with them.'
}

# Phase 19 D-07 left to Phase 20: a finished install warns once that the real shortcut lacks steam-wrap, writes the menu entry and asks to launch;
# EOF is No, so nothing starts and the old closing line stays.
t_launch_opts_install_finish() {
  steam_launch_setup
  FEED=''
  run "$T" install
  rc_is 0
  has_line warn 'launch options' "$(opts_warn 'missing steam-wrap')"
  err_has 'Launch now? Steam starts the shortcut [Y/n]'
  out_has 'Next: press Play on the shortcut in Steam.'
  [ -e "$T/home/.local/share/applications/w3c-linux.desktop" ] || ERRS+=('no desktop entry was written')
  [ ! -e "$T/marks/steam" ] || ERRS+=('steam ran')
}

# A yes runs launch inside install: one rungameid call, the session followed to its end, install's own exit status 0.
t_launch_opts_install_launch() {
  steam_launch_setup
  steam_up
  on_steam "$(reaper_line 4400)" "$(w3c_line 4500)"
  at 3 - "$(reaper_line 4400)"
  at 3 - "$(w3c_line 4500)"
  FEED=$'y\n'
  run "$T" install
  rc_is 0
  steam_count 1
  [ "$(steam_calls)" = "$T/bin/steam steam://rungameid/$GAMEID" ] || ERRS+=("steam calls: $(steam_calls | tr '\n' '|')")
  out_has 'W3Champions exited; launcher log: '
}

# ---------- STEAM-11: steam-wrap ----------

# stub_cmd: $T/bin/stub, the command Steam would pass as %command%. It records its argv one per line (an empty file for no arguments), whether
# it holds fd 8 or fd 9, the first stdin line when fix/stub-read exists, writes STUB-OUT and STUB-ERR, waits on stdin when fix/stub-hold exists
# and exits with the number in fix/stub-rc (default 0). Builtins only, so it also runs under the curated PATH.
stub_cmd() {
  cat > "$T/bin/stub" <<'SH'
#!/bin/sh
: >> "$MARK/stub-argv"
for a in "$@"; do printf '%s\n' "$a" >> "$MARK/stub-argv"; done
f8=no f9=no
[ -e "/proc/$$/fd/8" ] && f8=yes
[ -e "/proc/$$/fd/9" ] && f9=yes
printf 'fd8=%s fd9=%s\n' "$f8" "$f9" >> "$MARK/stub-fd"
if [ -f "$FIX/stub-read" ]; then
  read -r l
  printf '%s\n' "$l" > "$MARK/stub-in"
fi
echo STUB-OUT
echo STUB-ERR >&2
if [ -f "$FIX/stub-hold" ]; then read -r _; fi
rc=0
[ -f "$FIX/stub-rc" ] && read -r rc < "$FIX/stub-rc"
exit "$rc"
SH
  chmod +x "$T/bin/stub"
}

# wrap_env: what Steam puts in the environment of the Launch Options command for the Steam shortcut of the fixture.
wrap_env() {
  CASE_ENV+=(SteamAppId=3389133332 "STEAM_COMPAT_DATA_PATH=$SR/steamapps/compatdata/3389133332" WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--no-sandbox)
}

# timedatectl_shim ANSWER: a timedatectl that prints ANSWER for every call.
timedatectl_shim() {
  printf '#!/bin/sh\nprintf "%%s\\n" %q\n' "$1" > "$T/bin/timedatectl"
  chmod +x "$T/bin/timedatectl"
}

# lock_free: up to 5 s until monitor.lock can be taken, that is, no monitor holds it (nothing to wait for when the file was never made).
lock_free() {
  local f=$T/home/.local/state/w3c-linux/monitor.lock i
  [ -e "$f" ] || return 0
  for ((i = 0; i < 50; i++)); do
    ( exec 6> "$f" && flock -n 6 ) 2> /dev/null && return 0
    sleep 0.1
  done
  ERRS+=('monitor.lock is still held')
  return 1
}

# wrap_setup: a complete Steam shortcut whose prefix holds the launcher, the stub, the recording notify-send and the links the monitor needs,
# and the environment Steam passes.
wrap_setup() {
  sprep
  notify_shim
  add_link "$T" tail
  add_link "$T" timeout
  stub_cmd
  : > "$SR/steamapps/compatdata/3389133332/pfx/drive_c/Program Files/W3Champions/W3Champions.exe"
  wrap_env
}

# wrap_run T ARGS...: run, except that it waits for the monitor to let go of its lock before the allowlist check, so none outlives its case.
wrap_run() {
  local t=$1
  shift
  snap "$t" > "$TMPROOT/snap.before"
  if [ "${FEED+set}" = set ]; then
    printf '%s' "$FEED" | run_cmd "$t" "$@" > "$TMPROOT/out" 2> "$TMPROOT/err"
  else
    run_cmd "$t" "$@" < /dev/null > "$TMPROOT/out" 2> "$TMPROOT/err"
  fi
  RC=$?
  lock_free
  post_run "$t"
}

# wrap_finish: finish for a wrap_run_fifo-style case: closes the FIFO, waits for the script, waits for the monitor, then the allowlist check.
wrap_finish() {
  exec {FIFO_FD}>&-
  wait "$FIFO_PID"
  RC=$?
  lock_free
  post_run "$T"
}

# wrap_ran: Play must never be blocked, so every case that gets a command ran it.
wrap_ran() { [ -e "$T/marks/stub-argv" ] || ERRS+=('the stub did not run'); }

# wlog_has LINE: launch.log holds LINE as a whole line. wlog_count LINE: how many times.
wlog_has() { grep -qxF -- "$1" "$T/home/.cache/w3c-linux/launch.log" 2> /dev/null || ERRS+=("launch.log lacks the line: $1"); }
wlog_count() { grep -cxF -- "$1" "$T/home/.cache/w3c-linux/launch.log" 2> /dev/null; }

NOENV_LINE="steam-wrap: the prefix was not found from Steam's environment (SteamAppId, STEAM_COMPAT_DATA_PATH); no match monitor this session"
NAT_LINE='steam-wrap: the LAN-test NAT rule was not applied by w3c-linux this boot: run w3c-linux.sh install for the NAT rule (ignore this if you keep the rule yourself)'
NTP_LINE='steam-wrap: NTP is off and the launcher checks clock skew: run sudo timedatectl set-ntp true'

# D-10, D-11, T-20-18, T-20-21: the stub gets Steam's arguments byte for byte (an empty one and one with a space included), its own stdout and
# stderr with nothing of ours on them, and its own exit status.
t_steam_wrap_exec() {
  wrap_setup
  wrap_run "$T" steam-wrap "$T/bin/stub" a 'b c' ''
  rc_is 0
  wrap_ran
  printf 'a\nb c\n\n' | cmp -s - "$T/marks/stub-argv" || ERRS+=("stub argv: $(od -c < "$T/marks/stub-argv" | head -n 3 | tr '\n' '|')")
  [ "$OUT" = STUB-OUT ] || ERRS+=("stdout is not the stub's: [$OUT]")
  [ "$ERR" = STUB-ERR ] || ERRS+=("stderr is not the stub's: [$ERR]")
  rm "$T/marks/stub-argv"
  printf '3\n' > "$T/fix/stub-rc"
  wrap_run "$T" steam-wrap "$T/bin/stub"
  rc_is 3
  wrap_ran
}

# RESEARCH Pitfall 3, T-20-20, WR-05: the command never holds the lock fds steam-wrap opened itself (8 for the monitor, 9 for a run lock), and it
# keeps any fd 8 or 9 Steam passed: those are Steam's, so steam-wrap neither closes them nor starts a monitor that would overwrite fd 8.
t_steam_wrap_fds() {
  wrap_setup
  wrap_run "$T" steam-wrap "$T/bin/stub"
  rc_is 0
  wrap_ran
  [ "$(cat "$T/marks/stub-fd")" = 'fd8=no fd9=no' ] || ERRS+=("stub fds, none passed: $(cat "$T/marks/stub-fd")")
  wlog_has "Match monitor: lost results and join bugs are tallied in $T/home/.local/state/w3c-linux/matches.log"
  rm "$T/marks/stub-fd" "$T/home/.cache/w3c-linux/launch.log"
  snap "$T" > "$TMPROOT/snap.before"
  run_cmd "$T" steam-wrap "$T/bin/stub" 8> "$TMPROOT/fd8" 9> "$TMPROOT/fd9" < /dev/null > "$TMPROOT/out" 2> "$TMPROOT/err"
  RC=$?
  lock_free
  post_run "$T"
  rc_is 0
  [ "$(cat "$T/marks/stub-fd")" = 'fd8=yes fd9=yes' ] || ERRS+=("stub fds, both passed: $(cat "$T/marks/stub-fd")")
  wlog_has 'steam-wrap: Steam passed its own file descriptor 8, which the monitor lock would overwrite; no match monitor this session'
}

# D-10: with the prefix found, launch.log gets the header and the monitor line.
t_steam_wrap_log() {
  wrap_setup
  wrap_run "$T" steam-wrap "$T/bin/stub"
  rc_is 0
  wrap_ran
  grep -qE '^== [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} steam-wrap$' "$T/home/.cache/w3c-linux/launch.log" || ERRS+=('launch.log has no steam-wrap header')
  wlog_has "Match monitor: lost results and join bugs are tallied in $T/home/.local/state/w3c-linux/matches.log"
  [ "$(notify_calls)" = 0 ] || ERRS+=("notify-send calls: $(notify_calls)")
}

# D-10, T-20-18: no SteamAppId (the Launch Options string pasted somewhere else, or run by hand): the command still runs.
t_steam_wrap_noenv() {
  wrap_setup
  CASE_ENV=()
  wrap_run "$T" steam-wrap "$T/bin/stub" a
  rc_is 0
  wrap_ran
  wlog_has "$NOENV_LINE"
  [ "$(notify_calls)" = 1 ] || ERRS+=("notify-send calls: want 1 got $(notify_calls)")
  [ "$(grep -c '^Match monitor:' "$T/home/.cache/w3c-linux/launch.log")" = 0 ] || ERRS+=('a monitor line was logged')
}

# T-20-19: an appid that is not the last component of the data path is no prefix.
t_steam_wrap_badpath() {
  wrap_setup
  CASE_ENV+=(STEAM_COMPAT_DATA_PATH=/x/compatdata/999)
  wrap_run "$T" steam-wrap "$T/bin/stub"
  rc_is 0
  wrap_ran
  wlog_has "$NOENV_LINE"
  [ "$(notify_calls)" = 1 ] || ERRS+=("notify-send calls: want 1 got $(notify_calls)")
  [ "$(grep -c '^Match monitor:' "$T/home/.cache/w3c-linux/launch.log")" = 0 ] || ERRS+=('a monitor line was logged')
}

# D-11, A5: the NAT rule not applied this boot is a line on every Play and one notification per boot.
t_steam_wrap_nat() {
  wrap_setup
  rm "$T/home/.local/state/w3c-linux/nat-applied"
  wrap_run "$T" steam-wrap "$T/bin/stub"
  rc_is 0
  wrap_ran
  wlog_has "$NAT_LINE"
  [ "$(notify_calls)" = 1 ] || ERRS+=("notify-send calls: want 1 got $(notify_calls)")
  grep -qF 'w3c-linux.sh install for the NAT rule' "$T/marks/notify-send" || ERRS+=('the notification does not name the NAT fix')
  rm "$T/marks/stub-argv"
  wrap_run "$T" steam-wrap "$T/bin/stub"
  rc_is 0
  wrap_ran
  [ "$(wlog_count "$NAT_LINE")" = 2 ] || ERRS+=("NAT lines: want 2 got $(wlog_count "$NAT_LINE")")
  [ "$(notify_calls)" = 1 ] || ERRS+=("second run: notify-send calls: want 1 got $(notify_calls)")
  [ "$(cat "$T/home/.local/state/w3c-linux/wrap-nat-notified" 2> /dev/null)" = "$BOOT_ID" ] || ERRS+=('wrap-nat-notified does not hold the boot id')
}

# D-11: NTP off is a line and a notification naming the fix.
t_steam_wrap_ntp() {
  wrap_setup
  timedatectl_shim no
  wrap_run "$T" steam-wrap "$T/bin/stub"
  rc_is 0
  wrap_ran
  wlog_has "$NTP_LINE"
  [ "$(notify_calls)" = 1 ] || ERRS+=("notify-send calls: want 1 got $(notify_calls)")
  grep -qF 'sudo timedatectl set-ntp true' "$T/marks/notify-send" || ERRS+=('the notification does not name the NTP fix')
}

# D-11, T-20-18: with no terminal and every problem at once, nothing asks (no zenity, no question) and the command reads the caller's stdin.
t_steam_wrap_noprompt() {
  wrap_setup
  add_shim "$T" zenity
  rm "$T/home/.local/state/w3c-linux/nat-applied"
  timedatectl_shim no
  printf 'x\n' > "$T/fix/stub-read"
  CASE_ENV+=(W3C_ASSUME_TTY=)
  FEED=$'y\n'
  wrap_run "$T" steam-wrap "$T/bin/stub"
  rc_is 0
  wrap_ran
  [ ! -e "$T/marks/zenity" ] || ERRS+=('zenity ran')
  case $ERR in *'[Y/n]'*) ERRS+=('stderr has a question') ;; esac
  [ "$(cat "$T/marks/stub-in" 2> /dev/null)" = y ] || ERRS+=("the stub read: [$(cat "$T/marks/stub-in" 2> /dev/null)]")
  [ "$(notify_calls)" = 1 ] || ERRS+=("notify-send calls: want 1 got $(notify_calls)")
}

# no argument: nothing to run, the usage line and status 2.
t_steam_wrap_usage() {
  wrap_setup
  wrap_run "$T" steam-wrap
  rc_is 2
  [ "$ERR" = "usage: w3c-linux.sh steam-wrap %command% (set it in the Steam shortcut's Launch Options)" ] || ERRS+=("stderr: [$ERR]")
  [ -z "$OUT" ] || ERRS+=("stdout: [$OUT]")
  [ ! -e "$T/marks/stub-argv" ] || ERRS+=('the stub ran')
}

# D-11: a half-set override (W3C_PREFIX without W3C_PROTON) stops other subcommands before they run; it must never stop Play.
t_steam_wrap_override() {
  wrap_setup
  CASE_ENV+=(W3C_PREFIX=/x)
  wrap_run "$T" steam-wrap "$T/bin/stub"
  rc_is 0
  wrap_ran
}

# ---------- STEAM-11: the wrap monitor's lifetime and who owns the monitor ----------

WRAP_TELEMETRY='[2026-10-09T10:00:00Z INFO match_telemetry] PlayerMatchTelemetryReport emitted'

# wait_has FILE TEXT: up to 10 s until FILE holds TEXT. False after 10 s, with an error recorded.
wait_has() {
  local i
  for ((i = 0; i < 100; i++)); do
    grep -qF -- "$2" "$1" 2> /dev/null && return 0
    sleep 0.1
  done
  ERRS+=("timed out waiting for $1 to hold: $2")
  return 1
}

# wrap_allow_logs: the cases that write a launcher log in the Steam prefix allow its three new paths.
wrap_allow_logs() {
  ALLOW_EXTRA+=("$SP_REL/drive_c/users/steamuser/W3Champions" "$SP_REL/drive_c/users/steamuser/W3Champions/logs" "$SP_REL/drive_c/users/steamuser/W3Champions/logs/w3champions.$(date -u +%F).log")
}

# T-20-22, T-20-24: the session ends (the held stub is released) after the monitor tallied a game-end: the monitor tags it mode=wrap with the
# WEBVIEW2 value from Steam's environment, lets go of its lock, and never writes MONITOR-DOWN.
t_steam_wrap_session_end() {
  local log mlog=$T/home/.local/state/w3c-linux/matches.log i
  wrap_setup
  wrap_allow_logs
  printf 'x\n' > "$T/fix/stub-hold"
  log=$SR/steamapps/compatdata/3389133332/pfx/drive_c/users/steamuser/W3Champions/logs
  run_fifo "$T" steam-wrap "$T/bin/stub"
  wait_has "$T/home/.cache/w3c-linux/launch.log" 'Match monitor:'
  mkdir -p "$log"
  # the monitor starts at the log's end, so the line is written again until it has tallied one
  for ((i = 0; i < 100; i++)); do
    grep -qF 'game-end target=exe mode=wrap wv2flags=--no-sandbox' "$mlog" 2> /dev/null && break
    printf '%s\n' "$WRAP_TELEMETRY" >> "$log/w3champions.$(date -u +%F).log"
    sleep 0.1
  done
  grep -qF 'game-end target=exe mode=wrap wv2flags=--no-sandbox' "$mlog" 2> /dev/null || ERRS+=("no wrap game-end in matches.log: $(cat "$mlog" 2> /dev/null)")
  wrap_finish
  rc_is 0
  wrap_ran
  ! grep -qF MONITOR-DOWN "$mlog" 2> /dev/null || ERRS+=('MONITOR-DOWN was tallied at the session end')
}

# RESEARCH A3, Pitfall 8: the real launcher, once seen, is gone for the grace window while the session (the held stub) still runs: the monitor
# ends by itself, so it can never be what keeps the shortcut marked as running.
t_steam_wrap_hedge() {
  local mlog=$T/home/.local/state/w3c-linux/matches.log
  wrap_setup
  CASE_ENV+=(W3C_MONITOR_POLL_SECS=1 W3C_RESTART_GRACE_SECS=1)
  w3c_line 5001 > "$T/fix/procs"
  ALLOW_EXTRA+=(fix/procs)
  printf 'x\n' > "$T/fix/stub-hold"
  run_fifo "$T" steam-wrap "$T/bin/stub"
  wait_has "$T/home/.cache/w3c-linux/launch.log" 'Match monitor:'
  wait_has "$T/marks/pgrep" 'Program Files'
  : > "$T/fix/procs"
  lock_free
  kill -0 "$FIFO_PID" 2> /dev/null || ERRS+=('the session ended before the monitor did')
  wrap_finish
  rc_is 0
  wrap_ran
  ! grep -qF MONITOR-DOWN "$mlog" 2> /dev/null || ERRS+=('MONITOR-DOWN was tallied')
}

# Claude's discretion (Path A): launch under Steam with the Launch Options that carry an executable steam-wrap starts no monitor of its own,
# since steam-wrap's tallies the session and a launch-owned one would die with Ctrl-C; the attach arm still starts one when the lock is free.
t_steam_wrap_owner() {
  local n
  steam_launch_setup
  steam_up
  sc_edit "$SR/userdata/12345678/config/shortcuts.vdf" set 3389133332 LaunchOptions "$(default_opts "$ROOT/w3c-linux.sh")"
  on_steam "$(reaper_line 4400)" "$(w3c_line 4500)"
  at 3 - "$(reaper_line 4400)"
  at 3 - "$(w3c_line 4500)"
  run "$T" launch
  rc_is 0
  steam_count 1
  out_has "Match monitor: steam-wrap should start it from the Launch Options; if no tally follows, check $T/home/.cache/w3c-linux/launch.log"   # WR-03
  lacks_text 'Match monitor: lost results'
  # the attach arm: the same Launch Options, the launcher already runs and monitor.lock is free
  { reaper_line 4400; w3c_line 4500; } > "$T/fix/procs"
  n=$(grep -c . "$T/marks/sleep")
  printf '%s\n' "$n" >> "$T/fix/up"
  run "$T" launch
  rc_is 0
  steam_count 1
  out_has 'W3Champions is already running; following it until it exits'
  out_has 'Match monitor: lost results and join bugs are tallied in'
}

# ---------- DEBT-04: the Battle.net sign-in signal ----------

# The signal is the last `Account manager state has changed to:` line of Battle.net's newest log. The fixtures are synthetic lines in the real
# format (CRLF line ends); no real log, account id or e-mail is committed.

# bn_logdir: Battle.net's log directory in the prefix BN_PFX (the Faugus fixture's prefix when unset).
bn_logdir() { printf '%s/drive_c/users/steamuser/AppData/Local/Battle.net/Logs' "${BN_PFX:-$T/home/Faugus/battlenet}"; }

# bn_log NAME LINE...: writes battle.net-NAME.log with CRLF line ends, as Battle.net does. A LINE may hold several lines. bn_log_lf: LF line ends.
bn_log() {
  local f
  f=$(bn_logdir)/battle.net-$1.log
  shift
  mkdir -p "${f%/*}"
  printf '%s\n' "$@" | sed 's/$/\r/' > "$f"
}
bn_log_lf() {
  local f
  f=$(bn_logdir)/battle.net-$1.log
  shift
  mkdir -p "${f%/*}"
  printf '%s\n' "$@" > "$f"
}

# bn_ready_lines: a saved-credential start. bn_out_lines: a signed-out start, no AccountManager line at all.
bn_ready_lines() {
  printf '%s\n' \
    'I 2026-10-16 22:25:52.900648 [AccountManager] {Main} Account manager state has changed to: Loading' \
    'I 2026-10-16 22:25:53.423381 [AccountManager] {Main} Account manager state has changed to: Ready'
}
bn_out_lines() {
  printf '%s\n' \
    'I 2026-10-16 21:20:05.100000 [UAuth] {Main} UAuth: browser state changed: Login' \
    'I 2026-10-16 21:20:06.200000 [UAuth] {Main} UAuth: browser state changed: Login'
}

# the log stamps (the names sort by start time): a killed session's old log and the newer one
BN_OLD=20261016T212001.121922 BN_NEW=20261016T222548.649030

# the D-15 line, and today's prompt (the can't-tell variant, byte for byte)
SI_WAIT='Sign in to Battle.net; launch continues once you are signed in (Enter continues now, q quits)'
SI_TODAY='Sign in to Battle.net if it asks, then press Enter (q to quit): '

# the Faugus and umu cases run umu-run and the launch client; the rest of the suite forbids both, so each of these cases narrows the list for itself
FB_BN=(wine wineserver faugus-launcher sudo nft iptables notify-send xdg-open steam)

# err_lacks TEXT: stderr does not hold TEXT.
err_lacks() { case $ERR in *"$1"*) ERRS+=("stderr unexpectedly has: $1") ;; esac; }

# D-14: a signed-in Battle.net (CRLF log) asks nothing, says so once and goes on to the launcher.
t_signin_in() {
  local FORBIDDEN=("${FB_BN[@]}")
  l_setup
  bn_log "$BN_NEW" "$(bn_ready_lines)"
  unset FEED
  run "$T" launch
  rc_is 0
  out_has 'Battle.net is signed in'
  err_lacks 'Sign in to Battle.net'
  umu_count 1
}

# the same with LF line ends
t_signin_in_lf() {
  local FORBIDDEN=("${FB_BN[@]}")
  l_setup
  bn_log_lf "$BN_NEW" "$(bn_ready_lines)"
  unset FEED
  run "$T" launch
  rc_is 0
  out_has 'Battle.net is signed in'
  err_lacks 'Sign in to Battle.net'
  umu_count 1
}

# D-15: started but not signed in, Enter continues
t_signin_out_enter() {
  local FORBIDDEN=("${FB_BN[@]}")
  l_setup
  bn_log "$BN_NEW" "$(bn_out_lines)"
  go
  rc_is 0
  err_has "$SI_WAIT"
  lacks_text 'Battle.net is signed in'
  err_lacks "$SI_TODAY"
  umu_count 1
}

# q stops exactly as wait_enter does
t_signin_out_quit() {
  local FORBIDDEN=("${FB_BN[@]}")
  l_setup
  bn_log "$BN_NEW" "$(bn_out_lines)"
  FEED=$'q\n'
  run "$T" launch
  rc_is 1
  err_has "$SI_WAIT"
  err_has 'Stopped; W3Champions was not started.'
  no_umu
}

# so does EOF
t_signin_out_eof() {
  local FORBIDDEN=("${FB_BN[@]}")
  l_setup
  bn_log "$BN_NEW" "$(bn_out_lines)"
  unset FEED
  run "$T" launch
  rc_is 1
  err_has "$SI_WAIT"
  err_has 'no answer (stdin closed); run in a terminal'
  no_umu
}

# D-16: no Logs directory means the signal cannot tell, and today's prompt shows byte for byte with no timed hint
t_signin_nolog() {
  local FORBIDDEN=("${FB_BN[@]}")
  l_setup
  go
  rc_is 0
  err_has "$SI_TODAY"
  err_lacks "$SI_WAIT"
  err_lacks 'no sign-in yet'
  lacks_text 'Battle.net is signed in'
  umu_count 1
}

# D-16: a log that cannot be read cannot tell either
t_signin_unreadable() {
  local FORBIDDEN=("${FB_BN[@]}")
  l_setup
  bn_log "$BN_NEW" "$(bn_ready_lines)"
  if [ "$(id -u)" = 0 ]; then
    printf '# skip: running as root, chmod cannot hide a file\n'
    return 0
  fi
  chmod 000 "$(bn_logdir)/battle.net-$BN_NEW.log"
  # snap cannot hash the hidden file; its error text is not the case's output
  go 2> /dev/null
  chmod 644 "$(bn_logdir)/battle.net-$BN_NEW.log"
  rc_is 0
  err_has "$SI_TODAY"
  err_lacks "$SI_WAIT"
  lacks_text 'Battle.net is signed in'
}

# the umu backend reads the same log in its own prefix
t_signin_umu_in() {
  local FORBIDDEN=("${FB_BN[@]}")
  l_setup
  ovr_env "$(pfx)" "$TAG"
  bn_log "$BN_NEW" "$(bn_ready_lines)"
  unset FEED
  run "$T" launch
  rc_is 0
  out_has 'Battle.net is signed in'
  err_lacks 'Sign in to Battle.net'
  umu_count 1
}

# D-13: under Steam no Battle.net runs, so a signed-out Battle.net log in the shortcut's prefix shows no prompt and no signed-in line
t_signin_steam_none() {
  steam_launch_setup
  steam_up
  on_steam "$(reaper_line 4400)" "$(w3c_line 4500)"
  at 3 - "$(reaper_line 4400)"
  at 3 - "$(w3c_line 4500)"
  BN_PFX=$SR/steamapps/compatdata/3389133332/pfx bn_log "$BN_NEW" "$(bn_out_lines)"
  run "$T" launch
  rc_is 0
  err_lacks 'Sign in to Battle.net'
  lacks_text 'Sign in to Battle.net'
  lacks_text 'Battle.net is signed in'
}

# wait_out TEXT: waits up to 5 s until stdout holds TEXT (wait_err only reads stderr).
wait_out() {
  local i
  for ((i = 0; i < 50; i++)); do
    grep -qF -- "$1" "$TMPROOT/out" && return 0
    sleep 0.1
  done
  ERRS+=("timed out waiting for stdout: $1")
}

# D-15: while the prompt waits, the log gaining its Ready line continues launch by itself, with no Enter.
t_signin_flip() {
  local FORBIDDEN=("${FB_BN[@]}") f
  l_setup
  bn_log "$BN_NEW" "$(bn_out_lines)"
  f=$(bn_logdir)/battle.net-$BN_NEW.log
  ALLOW_EXTRA+=("${f#"$T"/}")
  run_fifo "$T" launch
  wait_err "$SI_WAIT"
  bn_ready_lines | sed 's/$/\r/' >> "$f"
  wait_out 'Battle.net is signed in'
  finish
  rc_is 0
  umu_count 1
}

# T-20-27: a killed session's old log ends on Ready; a run that has to start Battle.net must not take it for its own sign-in. Only a newer log
# (a later start stamp) with Ready counts.
t_signin_stale() {
  local FORBIDDEN=(wine wineserver sudo nft iptables notify-send xdg-open steam)
  l_setup
  down 1
  bn_log "$BN_OLD" "$(bn_ready_lines)"
  ALLOW_EXTRA+=("home/Faugus/battlenet/drive_c/users/steamuser/AppData/Local/Battle.net/Logs/battle.net-$BN_NEW.log")
  run_fifo "$T" launch
  wait_err "$SI_WAIT"
  ! grep -qF 'Battle.net is signed in' "$TMPROOT/out" || ERRS+=('the old log was taken for this run')
  bn_log "$BN_NEW" "$(bn_ready_lines)"
  wait_out 'Battle.net is signed in'
  finish
  rc_is 0
  faugus_once
  umu_count 1
}

# D-16 (clarified): in the polling wait, after W3C_SIGNIN_HINT_SECS, one hint line about the GPU driver, and the wait goes on.
t_signin_hint() {
  local FORBIDDEN=("${FB_BN[@]}") hint='no sign-in yet: if no Battle.net window appeared, check the GPU driver (reboot after a driver update) and run w3c-linux.sh doctor'
  l_setup
  CASE_ENV+=(W3C_SIGNIN_HINT_SECS=1)
  bn_log "$BN_NEW" "$(bn_out_lines)"
  run_fifo "$T" launch
  wait_err "$hint"
  sleep 3
  [ "$(grep -cxF -- "$hint" "$TMPROOT/err")" = 1 ] || ERRS+=("the hint was not printed exactly once: $(grep -cF 'no sign-in yet' "$TMPROOT/err")")
  [ "$(grep -cF 'Battle.net is signed in' "$TMPROOT/out")" = 0 ] || ERRS+=('the wait ended before Enter')
  send $'\n'
  finish
  rc_is 0
  umu_count 1
}

# T-20-25: none of the account details in a signed-in log reaches the output, launch.log, matches.log, a command line or anything else launch writes.
t_signin_privacy() {
  local FORBIDDEN=("${FB_BN[@]}") w
  l_setup
  bn_log "$BN_NEW" "I 2026-10-16 22:25:52.100000 [Account] {Main} account player@example.com BattleTag Fake#1234 accountId 98765" "$(bn_ready_lines)"
  unset FEED
  run "$T" launch
  rc_is 0
  out_has 'Battle.net is signed in'
  for w in 'player@example.com' 'Fake#1234' '98765'; do
    case $OUT$ERR in *"$w"*) ERRS+=("the output has $w") ;; esac
    ! grep -rqF -- "$w" "$T/home/.cache" "$T/home/.local/state" "$T/marks" 2> /dev/null || ERRS+=("launch wrote or sent $w")
  done
}

# ---------- STEAM-10: the inject arm is documented as not built (D-12) ----------

# the README's `## With Steam` section states the inject facts, the steam-wrap string and the overlay wording, and the public README names neither
# the planning directory nor the design document
t_inject_doc_readme() {
  local sec design=DESIGN.md s
  sec=$(awk '$0 == "## With Steam" { on = 1; next } on && /^## / { exit } on' "$ROOT/README.md")
  [ -n "$sec" ] || { ERRS+=('README.md has no ## With Steam section'); return 0; }
  for s in 'STEAM_COMPAT_LAUNCHER_SERVICE=proton' 'com.steampowered.App0' 'steam-wrap %command%' 'overlay'; do
    grep -qF -- "$s" <<< "$sec" || ERRS+=("With Steam lacks: $s")
  done
  grep -qF '](#with-steam)' "$ROOT/README.md" || ERRS+=('README.md has no link to #with-steam')
  ! grep -qF -- '.planning' "$ROOT/README.md" || ERRS+=('README.md names the planning directory')
  ! grep -qF -- "$design" "$ROOT/README.md" || ERRS+=('README.md names the design document')
}

# no code holds the inject arm: the launch option and the App0 bus name appear in no file of lib/ or in w3c-linux.sh
t_inject_doc_nocode() {
  local hits
  hits=$(grep -nE 'STEAM_COMPAT_LAUNCHER_SERVICE|App0' "$ROOT/w3c-linux.sh" "$ROOT"/lib/* 2> /dev/null)
  [ -z "$hits" ] || ERRS+=("the inject arm is not built, but code names it: $hits")
}

# ---------- main ----------

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
