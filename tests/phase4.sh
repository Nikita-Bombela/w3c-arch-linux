#!/usr/bin/env bash
# Phase 4 fixture check: runs the real w3c-linux.sh launch under env -i against a fake HOME per case, on the harness of tests/phase2.sh
# and tests/phase3.sh. The Battle.net container is a launch-client shim that lists (or not) the bus name; umu-run is the recording shim,
# its hook adds the W3Champions.exe process line and the session sleep shim drives the process list second by second.
# No case runs a real Wine, umu, Faugus or network call.
# Usage: bash tests/phase4.sh [GLOB]   (GLOB filters on display names such as sess-reenter)
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=phase3.sh
source "$(dirname "${BASH_SOURCE[0]}")/phase3.sh"

# this suite has its own cases only
mapfile -t P3_CASES < <(compgen -A function t_)
unset -f "${P3_CASES[@]}"

# umu-run, pkill, faugus-launcher and the launch client are expected here; the rest must never run
FORBIDDEN=(wine wineserver sudo nft iptables notify-send)
ENV_BIN=$(type -P env)   # resolved before any PATH narrowing

# ---------- helpers ----------

# bus_line T: the line the launch client prints while Battle.net runs, computed here without the script.
bus_line() {
  local p
  p=$(realpath "$1/home/Faugus/battlenet")
  printf -- '--bus-name=com.steampowered.App%s' "$(printf %s "$p" | md5sum | cut -d' ' -f1)"
}

# what the umu-run shim sources: fd 9 check, then the launcher's process line when the target is the launcher
IFS= read -r -d '' LAUNCH_HOOK <<'SH' || true
[ -e /proc/$$/fd/9 ] && echo umu >> "$MARK/fd9"
for a; do last=$a; done
case $last in
  *W3Champions.exe | *W3Champions.bat)
    : > "$FIX/armed"
    printf '%s\n' '4500|W3Champions.exe|C:\Program Files\W3Champions\W3Champions.exe' >> "$FIX/procs" ;;
esac
SH

# the session sleep shim body: Battle.net coming up after N sleeps, the launcher exiting two seconds after it appeared, the lock state per sleep
IFS= read -r -d '' SLEEP_BODY <<'SH' || true
if [ -f "$FIX/bus-after" ] && [ ! -f "$FIX/bus" ]; then
  read -r n < "$FIX/bus-after"
  [ "$(grep -c . "$MARK/sleep")" -ge "$n" ] && cp "$FIX/bus-line" "$FIX/bus"
fi
if [ -f "$FIX/appear" ] && [ "$(grep -c . "$MARK/sleep")" -ge 1 ]; then
  : > "$FIX/armed"
  cat "$FIX/appear" >> "$FIX/procs"
  rm -f "$FIX/appear"
fi
if [ -f "$FIX/armed" ]; then
  if [ -s "$FIX/armed" ]; then
    grep -v 'W3Champions\.exe' "$FIX/procs" > "$FIX/procs.n"
    mv "$FIX/procs.n" "$FIX/procs"
  else
    echo 1 > "$FIX/armed"
  fi
fi
if flock -n "$HOME/.local/state/w3c-linux/lock" true; then echo free; else echo held; fi >> "$MARK/lock"
SH

# l_setup: Battle.net on the W3C build and up, the launcher installed; shims for env, the launch client, faugus-launcher, umu-run and sleep.
l_setup() {
  local t=$T
  on_w3c "$t"
  add_link "$t" setsid
  add_link "$t" true
  rm -f "$t/bin/env"
  {
    cat <<'SH'
#!/bin/sh
if [ $# -gt 0 ]; then
  echo '== call ==' >> "$MARK/env"
  for a in "$@"; do printf '%s\n' "$a" >> "$MARK/env"; done
fi
SH
    printf 'exec %s "$@"\n' "$ENV_BIN"
  } > "$t/bin/env"
  chmod +x "$t/bin/env"
  cat > "$t/home/.local/share/umu/steamrt4/pressure-vessel/bin/steam-runtime-launch-client" <<'SH'
#!/bin/sh
printf '%s\n' "$0 $*" >> "$MARK/steam-runtime-launch-client"
echo --bus-name=org.freedesktop.portal.Flatpak
[ -f "$FIX/bus" ] && cat "$FIX/bus"
exit 0
SH
  cat > "$t/bin/faugus-launcher" <<'SH'
#!/bin/sh
printf '%s\n' "$0 $*" >> "$MARK/faugus-launcher"
{ echo '== call =='; env; } >> "$MARK/faugus-launcher.env"
[ -e /proc/$$/fd/9 ] && echo faugus >> "$MARK/fd9"
exit 0
SH
  chmod +x "$t/home/.local/share/umu/steamrt4/pressure-vessel/bin/steam-runtime-launch-client" "$t/bin/faugus-launcher"
  bus_line "$t" > "$t/fix/bus-line"
  printf '\n' >> "$t/fix/bus-line"
  cp "$t/fix/bus-line" "$t/fix/bus"
  umu_hook "$t" "$LAUNCH_HOOK"
  sleep_shim "$t" "$SLEEP_BODY"
  ALLOW_EXTRA+=(fix/procs fix/armed fix/bus fix/appear 'home/Faugus/battlenet/drive_c/Program Files/W3Champions/W3Champions.bat')
}

# go: one launch answered with Enter.
go() {
  FEED=$'\n'
  run "$T" launch
}

# env_call N: the argv lines of the N-th env call the script made.
env_call() { awk -v n="$1" '/^== call ==$/ { c++; next } c == n' "$T/marks/env" 2> /dev/null; }

# pfx: the realpath of the Battle.net prefix.
pfx() { realpath "$T/home/Faugus/battlenet"; }

# ---------- cases ----------

# The tracer: Battle.net is up, one Enter, the launcher starts inside its container and the session ends with the launcher.
t_sess_reenter() {
  local p
  p=$(pfx)
  l_setup
  go
  rc_is 0
  err_has 'Sign in to Battle.net if it asks, then press Enter'
  [ ! -e "$T/marks/faugus-launcher" ] || ERRS+=('faugus-launcher ran')
  grep -qF -- '--list' "$T/marks/steam-runtime-launch-client" 2> /dev/null || ERRS+=('the launch client was not asked --list')
  umu_count 1
  case $(cat "$T/marks/umu-run" 2> /dev/null) in
    *" $p/drive_c/Program Files/W3Champions/W3Champions.exe") ;;
    *) ERRS+=("umu-run does not end with the host launcher path: $(cat "$T/marks/umu-run" 2> /dev/null)") ;;
  esac
  umu_env_has UMU_CONTAINER_NSENTER=1
  umu_env_has UMU_USE_STEAM=1
  umu_env_has W3C_SHARED_QUERY=1
  umu_env_has WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--no-sandbox
  umu_env_has "WINEPREFIX=$p"
  umu_env_has "PROTONPATH=$T/home/.local/share/Steam/compatibilitytools.d/$TAG"
  umu_env_lacks '^PROTON_VERB='
  out_has "W3Champions exited (status 0); Wine log: $T/home/.cache/w3c-linux/wine.log; launcher log: $p/drive_c/users/steamuser/W3Champions/logs/w3champions.$(date -u +%F).log"
  grep -q '^== .* launch ' "$T/home/.cache/w3c-linux/wine.log" 2> /dev/null || ERRS+=('wine.log has no launch header')
  [ ! -e "$T/marks/fd9" ] || ERRS+=('a child holds fd 9')
}

# pos KV: the line number of the exact line KV in the first env call, empty when absent.
pos() { env_call 1 | grep -nxF -m1 -- "$1" | cut -d: -f1; }

# before A B: both lines are in the first env call and A comes first.
before() {
  local a b
  a=$(pos "$1") b=$(pos "$2")
  { [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; } || ERRS+=("env order: [$1] (line ${a:-none}) is not before [$2] (line ${b:-none})")
}

# between runs of one case: the launcher is gone and may start again
rearm() { rm -f "$T/fix/armed"; : > "$T/fix/procs"; }

# no_start_hook: umu-run starts but W3Champions.exe never shows up.
# shellcheck disable=SC2016 # the hook text is written literally and expanded when umu-run sources it
no_start_hook() { umu_hook "$T" '[ -e /proc/$$/fd/9 ] && echo umu >> "$MARK/fd9"'; }

# ---------- command contract (LCH-03) ----------

t_cmd_exact() {
  local p want
  p=$(pfx)
  l_setup
  go
  rc_is 0
  want=(-u GAMEID -u STORE -u FAUGUSID WINE_SIMULATE_WRITECOPY=1 PROTON_ENABLE_WAYLAND=0 UMU_CONTAINER_NSENTER=1 UMU_USE_STEAM=1
    "WINEPREFIX=$p" "PROTONPATH=$T/home/.local/share/Steam/compatibilitytools.d/$TAG" W3C_SHARED_QUERY=1
    WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--no-sandbox "$T/home/.local/share/faugus-launcher/umu-run"
    "$p/drive_c/Program Files/W3Champions/W3Champions.exe")
  [ "$(printf '%s\n' "${want[@]}")" = "$(env_call 1)" ] || ERRS+=("env argv differs: $(env_call 1 | tr '\n' ' ')")
  ! env_call 1 | grep -q -e '^C:' -e '~' || ERRS+=('env argv holds a Windows path or a tilde')
}

t_cmd_inherited() {
  l_setup
  CASE_ENV=(GAMEID=x STORE=y FAUGUSID=z)
  go
  rc_is 0
  umu_count 1
  umu_env_lacks '^GAMEID='
  umu_env_lacks '^STORE='
  umu_env_lacks '^FAUGUSID='
}

t_cmd_env_order() {
  l_setup
  printf '%s\n' '{"wayland-driver": "False", "wow64-enabled": "False", "discrete-gpu": "True"}' > "$T/home/.config/faugus-launcher/config.json"
  printf '%s\n' '["WINE_SIMULATE_WRITECOPY=7"]' > "$T/home/.config/faugus-launcher/envar.json"
  bn_set4 "$T" launch_arguments 'WINE_SIMULATE_WRITECOPY=1 PROTON_ENABLE_WAYLAND=0 WINEPREFIX=/evil W3C_SHARED_QUERY=0 UMU_CONTAINER_NSENTER=0'
  go
  rc_is 0
  umu_count 1
  before DRI_PRIME=1 WINE_SIMULATE_WRITECOPY=1
  before PROTON_ENABLE_WAYLAND=0 WINE_SIMULATE_WRITECOPY=7
  before WINE_SIMULATE_WRITECOPY=7 UMU_CONTAINER_NSENTER=1
  umu_env_has DRI_PRIME=1
  umu_env_has WINE_SIMULATE_WRITECOPY=7
  umu_env_has W3C_SHARED_QUERY=1
  umu_env_has UMU_CONTAINER_NSENTER=1
  umu_env_has "WINEPREFIX=$(pfx)"
  umu_env_lacks '/evil'
}

t_cmd_env_empty() {
  l_setup
  bn_set4 "$T" launch_arguments ''
  printf '%s\n' '[]' > "$T/home/.config/faugus-launcher/envar.json"
  go
  rc_is 0
  [ "$(pos UMU_CONTAINER_NSENTER=1)" = 7 ] || ERRS+=("UMU_CONTAINER_NSENTER=1 is not directly after FAUGUSID: $(env_call 1 | tr '\n' ' ')")
}

t_cmd_idempotent() {
  l_setup
  go
  rc_is 0
  rearm
  go
  rc_is 0
  umu_count 2
  [ -n "$(env_call 1)" ] && [ "$(env_call 1)" = "$(env_call 2)" ] || ERRS+=('the two launches recorded different env argv')
  [ ! -e "$T/marks/faugus-launcher" ] || ERRS+=('faugus-launcher ran')
}

# ---------- WebView2 toggle (LCH-05) ----------

t_web_override() {
  l_setup
  CASE_ENV=('W3C_WRAPPER_WEBVIEW_FLAGS=--no-sandbox --in-process-gpu')
  go
  rc_is 0
  env_call 1 | grep -qxF 'WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--no-sandbox --in-process-gpu' || ERRS+=('the flags are not one env element')
  [ "$(env_call 1 | grep -c '^WEBVIEW2_')" = 1 ] || ERRS+=('not exactly one WEBVIEW2 element')
  ! env_call 1 | grep -qxF -e '--in-process-gpu' || ERRS+=('the flags were split')
  umu_env_has 'WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--no-sandbox --in-process-gpu'
}

t_web_off_empty() {
  l_setup
  CASE_ENV=(W3C_WRAPPER_WEBVIEW_FLAGS=)
  go
  rc_is 0
  umu_count 1
  umu_env_lacks '^WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS='
}

t_web_off_zero() {
  l_setup
  CASE_ENV=(W3C_WRAPPER_WEBVIEW_FLAGS=0)
  go
  rc_is 0
  umu_count 1
  umu_env_lacks '^WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS='
}

t_web_order() {
  l_setup
  bn_set4 "$T" launch_arguments 'WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--x'
  go
  rc_is 0
  before WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--x WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--no-sandbox
  umu_env_has WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--no-sandbox
}

t_web_not_remembered() {
  l_setup
  CASE_ENV=(W3C_WRAPPER_WEBVIEW_FLAGS=--x)
  go
  rc_is 0
  rearm
  CASE_ENV=()
  go
  rc_is 0
  env_call 1 | grep -qxF 'WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--x' || ERRS+=('the first run did not use --x')
  env_call 2 | grep -qxF 'WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--no-sandbox' || ERRS+=('the second run did not return to --no-sandbox')
  ! grep -rqF -e '--x' "$T/home/.local/state/w3c-linux" || ERRS+=('the flags were written to the state dir')
}

# ---------- run lock (D-03) ----------

# The launcher shows up after the first sleep: the lock is held while waiting for it and free once it runs.
t_lock_released() {
  l_setup
  no_start_hook
  printf '%s\n' '4500|W3Champions.exe|C:\Program Files\W3Champions\W3Champions.exe' > "$T/fix/appear"
  go
  rc_is 0
  [ "$(head -n 1 "$T/marks/lock" 2> /dev/null)" = held ] || ERRS+=("the lock was not held while the launcher was starting: $(tr '\n' ' ' < "$T/marks/lock")")
  [ "$(tail -n 1 "$T/marks/lock" 2> /dev/null)" = free ] || ERRS+=("the lock was not free while the launcher ran: $(tr '\n' ' ' < "$T/marks/lock")")
  flock -n "$T/home/.local/state/w3c-linux/lock" true || ERRS+=('the lock is still held after the run')
}

t_lock_no_fd9() {
  l_setup
  go
  rc_is 0
  umu_count 1
  [ ! -e "$T/marks/fd9" ] || ERRS+=("fd 9 was open in: $(tr '\n' ' ' < "$T/marks/fd9")")
}

# ---------- session edges (D-01, D-02, D-04, D-06) ----------

t_sess_wine_log() {
  l_setup
  umu_hook "$T" "$LAUNCH_HOOK"$'\necho umu-output-marker'
  go
  rc_is 0
  grep -qF umu-output-marker "$T/home/.cache/w3c-linux/wine.log" 2> /dev/null || ERRS+=('wine.log lacks the umu output')
  lacks_text umu-output-marker
  case $ERR in *umu-output-marker*) ERRS+=('umu output reached stderr') ;; esac
}

t_sess_never_started() {
  l_setup
  no_start_hook
  CASE_ENV=(W3C_START_WAIT_SECS=3)
  go
  rc_is 1
  out_has 'W3Champions did not start within 3 s'
  [ "$(grep -c . "$T/marks/sleep" 2> /dev/null)" = 3 ] || ERRS+=("sleeps: want 3 got $(grep -c . "$T/marks/sleep" 2> /dev/null)")
}

t_sess_signin_quit() {
  l_setup
  FEED=$'q\n'
  run "$T" launch
  rc_is 1
  no_umu
  err_has 'Stopped; W3Champions was not started.'
}

t_sess_signin_eof() {
  l_setup
  unset FEED
  run "$T" launch
  rc_is 1
  no_umu
  err_has 'no answer (stdin closed); run in a terminal'
}

t_sess_not_installed() {
  l_setup
  rm -f "$T/home/Faugus/battlenet/drive_c/Program Files/W3Champions/W3Champions.exe"
  go
  rc_is 1
  out_has 'run w3c-linux.sh install'
  no_umu
  [ ! -e "$T/marks/curl" ] || ERRS+=('curl ran')
  [ ! -e "$T/home/.local/state/w3c-linux/lock" ] || ERRS+=('the lock file was created')
}

# ---------- Battle.net bring-up (LCH-02, D-06, D-07) ----------

# down N: Battle.net is not running; with N the sleep shim brings its container up after N sleeps.
down() {
  rm -f "$T/fix/bus"
  [ -z "${1:-}" ] || echo "$1" > "$T/fix/bus-after"
}

# sleeps: how many times the sleep shim ran.
sleeps() { if [ -f "$T/marks/sleep" ]; then wc -l < "$T/marks/sleep"; else echo 0; fi; }

# faugus_once: the Faugus shim ran exactly once, with --game battlenet.
faugus_once() {
  [ "$(grep -c . "$T/marks/faugus-launcher" 2> /dev/null)" = 1 ] || ERRS+=("faugus-launcher calls: want 1 got $(grep -c . "$T/marks/faugus-launcher" 2> /dev/null)")
  case $(cat "$T/marks/faugus-launcher" 2> /dev/null) in *' --game battlenet') ;; *) ERRS+=('faugus-launcher was not started with --game battlenet') ;; esac
}

# the D-08 question, word for word
D08='Battle.net container not found; game attach will likely fail (umu #283). Start the launcher in a separate container with PROTON_VERB=run anyway? [y/N]'

t_bus_faugus_start() {
  l_setup
  down 3
  CASE_ENV=(W3C_WRAPPER_WEBVIEW_FLAGS=--x)
  go
  rc_is 0
  faugus_once
  ! grep -q '^WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=' "$T/marks/faugus-launcher.env" || ERRS+=('Faugus got the WebView2 flags')
  [ ! -e "$T/marks/fd9" ] || ERRS+=("fd 9 was open in: $(tr '\n' ' ' < "$T/marks/fd9")")
  [ "$(head -n 1 "$T/marks/lock" 2> /dev/null)" = held ] || ERRS+=('the lock was not held while waiting for Battle.net')
  err_has 'Sign in to Battle.net if it asks, then press Enter'
  no_err 'umu #283'
  out_has 'Starting Battle.net through Faugus (faugus-launcher --game battlenet); waiting up to 120 s for its container'
  umu_count 1
  umu_env_has UMU_CONTAINER_NSENTER=1
  grep -q '^== .*faugus-launcher --game battlenet' "$T/home/.cache/w3c-linux/wine.log" 2> /dev/null || ERRS+=('wine.log has no faugus-launcher header')
}

t_bus_tray_open() {
  l_setup
  printf '%s\n' '4501|python3|python3 -m faugus.tray_only' '4502|Battle.net.exe|C:\Program Files (x86)\Battle.net\Battle.net.exe' >> "$T/fix/procs"
  go
  rc_is 0
  umu_count 1
  no_err 'Still running'
}

t_bus_exact_line() {
  l_setup
  printf '%s0\n' "$(bus_line "$T")" > "$T/fix/bus"
  CASE_ENV=(W3C_BUS_WAIT_SECS=0)
  FEED=n
  run "$T" launch
  faugus_once
  err_has "$D08"
  rc_is 1
  no_umu
}

t_bus_order() {
  l_setup
  { bus_line "$T"; printf '\n--bus-name=org.example.Other\n'; } > "$T/fix/bus"
  go
  rc_is 0
  [ ! -e "$T/marks/faugus-launcher" ] || ERRS+=('faugus-launcher ran')
  umu_count 1
}

t_bus_client_absent() {
  l_setup
  rm -f "$T/home/.local/share/umu/steamrt4/pressure-vessel/bin/steam-runtime-launch-client"
  CASE_ENV=(W3C_BUS_WAIT_SECS=0)
  FEED=n
  run "$T" launch
  faugus_once
  err_has "$D08"
  rc_is 1
}

t_bus_symlink_prefix() {
  l_setup
  mkdir -p "$T/home/Spiele ä"
  ln -s "$(pfx)" "$T/home/Spiele ä/bn"
  bn_set4 "$T" prefix "$T/home/Spiele ä/bn"
  go
  rc_is 0
  [ ! -e "$T/marks/faugus-launcher" ] || ERRS+=('faugus-launcher ran')
  umu_count 1
  umu_env_has "WINEPREFIX=$(pfx)"
}

# fb_run ANSWER: Battle.net never appears; two seconds of waiting.
fb_run() {
  l_setup
  down
  CASE_ENV=(W3C_BUS_WAIT_SECS=2)
  FEED=$1
  run "$T" launch
  rc_is 1
  no_umu
  faugus_once
  no_err 'Sign in'
}

fb_no_row() {
  out_has 'com.steampowered.App'
  out_has 'after 2 s'
  out_has 'rerun w3c-linux.sh launch'
  err_has "$D08"
  [ "$(sleeps)" = 2 ] || ERRS+=("sleeps: want 2 got $(sleeps)")
}

t_fb_no() { fb_run $'n\n'; fb_no_row; }
t_fb_default() { fb_run $'\n'; fb_no_row; }

t_fb_eof() {
  l_setup
  down
  CASE_ENV=(W3C_BUS_WAIT_SECS=2)
  unset FEED
  run "$T" launch
  rc_is 1
  no_umu
  err_has 'no answer (stdin closed); run in a terminal'
  [ "$(sleeps)" = 2 ] || ERRS+=("sleeps: want 2 got $(sleeps)")
}

t_fb_yes() {
  l_setup
  down
  CASE_ENV=(W3C_BUS_WAIT_SECS=2)
  FEED=$'y\n\n'
  run "$T" launch
  rc_is 0
  faugus_once
  umu_count 1
  [ "$(env_call 1 | sed -n 7p)" = -u ] && [ "$(env_call 1 | sed -n 8p)" = UMU_CONTAINER_NSENTER ] || ERRS+=("no -u UMU_CONTAINER_NSENTER after FAUGUSID: $(env_call 1 | tr '\n' ' ')")
  [ "$(pos PROTON_VERB=run)" = 11 ] || ERRS+=("PROTON_VERB=run is not where nsenter mode puts its selector: $(env_call 1 | tr '\n' ' ')")
  umu_env_has PROTON_VERB=run
  umu_env_has UMU_USE_STEAM=1
  umu_env_lacks '^UMU_CONTAINER_NSENTER='
  out_has 'separate container'
}

t_fb_wait_zero() {
  l_setup
  down
  CASE_ENV=(W3C_BUS_WAIT_SECS=0)
  FEED=n
  run "$T" launch
  rc_is 1
  [ "$(sleeps)" = 0 ] || ERRS+=('slept before the fallback question')
}

t_fb_wait_invalid() {
  l_setup
  down
  CASE_ENV=(W3C_BUS_WAIT_SECS=12s)
  FEED=n
  run "$T" launch
  rc_is 1
  [ "$(sleeps)" = 120 ] || ERRS+=("sleeps: want 120 got $(sleeps)")
}

t_fb_wait_leading_zero() {
  l_setup
  down
  CASE_ENV=(W3C_BUS_WAIT_SECS=08)
  FEED=n
  run "$T" launch
  rc_is 1
  [ "$(sleeps)" = 8 ] || ERRS+=("sleeps: want 8 got $(sleeps)")
}

t_fb_faugus_missing() {
  l_setup
  down
  rm -f "$T/bin/faugus-launcher"
  FEED=n
  run "$T" launch
  rc_is 1
  out_has 'faugus-launcher is not on PATH'
  no_err 'umu #283'
  no_umu
}

# ---------- preflight (LCH-01) ----------

# no_question: the run asked neither a Y/n nor a y/N question.
no_question() { case $ERR in *'[Y/n]'* | *'[y/N]'*) ERRS+=('a question was asked') ;; esac; }

VERIFYJOB='not an installed W3C build'

t_pre_runner_warn() {
  l_setup
  bn_set4 "$T" runner 'Proton-GE Latest'
  go
  rc_is 0
  has_row warn runner "$VERIFYJOB"
  has_row warn runner VerifyJob
  no_question
  umu_env_has 'PROTONPATH=Proton-GE Latest'
  rearm
  go
  rc_is 0
  umu_count 2
  [ "$(grep -c "$VERIFYJOB" <<< "$OUT")" = 1 ] || ERRS+=('the second launch did not print the warning again')
}

t_pre_runner_incomplete() {
  l_setup
  rm -rf "$T/home/.local/share/Steam/compatibilitytools.d/$TAG/files"
  go
  rc_is 0
  has_row warn runner "$VERIFYJOB"
  umu_count 1
}

t_pre_update_hint() {
  l_setup
  latest_17 "$T"
  go
  rc_is 0
  out_has 'newer W3Champions 1.6.17 available (installed 1.6.16): run w3c-linux.sh update'
  curl_only_latest_json
  no_question
  umu_count 1
}

t_pre_offline() {
  l_setup
  rm -f "$T/fix/latest.json"
  go
  rc_is 0
  [ "$(grep -c 'could not check for a newer launcher' <<< "$OUT")" = 1 ] || ERRS+=('not exactly one could-not-check row')
  no_question
  umu_count 1
}

# a Faugus major we never tested only warns: the launcher still starts
t_pre_faugus_untested() {
  l_setup
  printf '%s\n' 'VERSION = "3.0.1"' > "$T/faugus-py/faugus/launcher.py"
  go
  rc_is 0
  out_has "$(printf '%s  %-16s  %s' warn 'faugus version' 'untested Faugus major 3: games.json/envar.json format may differ')"
  umu_count 1
}

t_pre_uptodate() {
  l_setup
  go
  rc_is 0
  lacks_text 'newer W3Champions'
  lacks_text 'could not check'
  lacks_text "$VERIFYJOB"
}

t_pre_lock_held() {
  l_setup
  hold_lock
  go
  drop_lock
  rc_is 1
  out_has 'another w3c-linux.sh run is in progress'
  local m
  for m in curl steam-runtime-launch-client faugus-launcher umu-run; do
    [ ! -e "$T/marks/$m" ] || ERRS+=("$m ran")
  done
}

t_pre_display() {
  l_setup
  go
  rc_is 0
  has_row warn display 'Battle.net and W3Champions need a graphical session'
  rearm
  CASE_ENV=(DISPLAY=:0)
  go
  rc_is 0
  [ "$(grep -c '^warn  display' <<< "$OUT")" = 0 ] || ERRS+=('the display warning appeared with DISPLAY set')
}

# ---------- already running and stale-process hygiene (D-05, LCH-06) ----------

# lp: the process line of a running W3Champions.exe
LP='4500|W3Champions.exe|C:\Program Files\W3Champions\W3Champions.exe'

# pk_lines: the argv lines pkill was called with, one per line
pk_lines() { cat "$T/marks/pkill" 2> /dev/null; }

# nothing_ran NAME...: none of these commands ran (their marker files are absent)
nothing_ran() {
  local m
  for m; do
    [ ! -e "$T/marks/$m" ] || ERRS+=("$m ran")
  done
}

t_bat_running() {
  l_setup
  printf '%s\n' "$LP" >> "$T/fix/procs"
  go
  rc_is 0
  out_has 'W3Champions is already running; bring its window forward'
  no_err 'Sign in'
  nothing_ran curl steam-runtime-launch-client faugus-launcher pkill umu-run
}

t_bat_second_launch() {
  l_setup
  go
  rc_is 0
  umu_count 1
  rearm
  printf '%s\n' "$LP" >> "$T/fix/procs"
  go
  rc_is 0
  out_has 'W3Champions is already running; bring its window forward'
  umu_count 1
  [ "$(pk_lines | grep -c .)" = 2 ] || ERRS+=("pkill calls: want 2 got $(pk_lines | grep -c .)")
}

t_bat_hygiene() {
  l_setup
  # shellcheck disable=SC2016 # the hook text is written literally and expanded when umu-run sources it
  umu_hook "$T" "$LAUNCH_HOOK"$'\n''grep -c . "$MARK/pkill" >> "$MARK/pkill-at-umu"'
  go
  rc_is 0
  umu_count 1
  [ "$(pk_lines | grep -c .)" = 2 ] || ERRS+=("pkill calls: want 2 got $(pk_lines | grep -c .)")
  case $(pk_lines | sed -n 1p) in *" -u $(id -u) -f mDNSResponder\\.exe") ;; *) ERRS+=("first pkill argv: $(pk_lines | sed -n 1p)") ;; esac
  case $(pk_lines | sed -n 2p) in *" -u $(id -u) -f MicrosoftEdgeUpdate\\.exe") ;; *) ERRS+=("second pkill argv: $(pk_lines | sed -n 2p)") ;; esac
  [ "$(cat "$T/marks/pkill-at-umu" 2> /dev/null)" = 2 ] || ERRS+=("pkill calls before umu-run: $(cat "$T/marks/pkill-at-umu" 2> /dev/null)")
}

t_bat_pgrep_fail() {
  l_setup
  echo 2 > "$T/fix/pgrep-rc"
  go
  rc_is 1
  out_has 'cannot check whether W3Champions is running'
  [ ! -e "$T/marks/pkill" ] || ERRS+=('pkill ran')
  no_umu
}

# ---------- W3Champions.bat (D-13, D-14) ----------

BAT_REL='home/Faugus/battlenet/drive_c/Program Files/W3Champions/W3Champions.bat'

# bat_file: the bat path of this case
bat_file() { printf '%s/%s' "$T" "$BAT_REL"; }

# want_bat FILE: the four upstream lines with CRLF, written here with its own printf
want_bat() {
  printf '%s\r\n' 'C:' 'start "" "C:\Program Files\W3Champions\W3Champions.exe"' 'net stop "Bonjour Service"' 'net start "Bonjour Service"' > "$1"
}

# bat_is_crlf: the case's bat equals the expected CRLF file byte for byte
bat_is_crlf() {
  want_bat "$TMPROOT/want.bat"
  cmp -s "$TMPROOT/want.bat" "$(bat_file)" || ERRS+=('the .bat is not the four CRLF lines')
}

# umu_ends WORD: the last umu-run call ends with the host path of that file in the launcher directory
umu_ends() {
  case $(tail -n 1 "$T/marks/umu-run" 2> /dev/null) in
    *" $(pfx)/drive_c/Program Files/W3Champions/$1") ;;
    *) ERRS+=("umu-run does not end with $1: $(tail -n 1 "$T/marks/umu-run" 2> /dev/null)") ;;
  esac
}

t_bat_write() {
  l_setup
  [ ! -e "$(bat_file)" ] || ERRS+=('a .bat existed before the run')
  go
  rc_is 0
  bat_is_crlf
  printf '%s\n' "${CHANGED[@]}" | grep -qxF -- "$BAT_REL" || ERRS+=('the .bat is not listed as changed')
  umu_ends W3Champions.exe
}

t_bat_rewrite() {
  l_setup
  printf '%s\n' 'C:' 'start "" "C:\Program Files\W3Champions\W3Champions.exe"' 'net stop "Bonjour Service"' 'net start "Bonjour Service"' > "$(bat_file)"
  go
  rc_is 0
  bat_is_crlf
}

t_bat_keep() {
  local before after
  l_setup
  want_bat "$(bat_file)"
  touch -d @1000000000 "$(bat_file)"
  before=$(stat -c '%i %Y' "$(bat_file)")
  go
  rc_is 0
  after=$(stat -c '%i %Y' "$(bat_file)")
  [ "$before" = "$after" ] || ERRS+=("the .bat was rewritten: $before -> $after")
  printf '%s\n' "${CHANGED[@]}" | grep -qxF -- "$BAT_REL" && ERRS+=('the .bat is listed as changed')
  bat_is_crlf
}

t_bat_target() {
  local first
  l_setup
  CASE_ENV=(W3C_LAUNCH_BAT=1)
  go
  rc_is 0
  umu_count 1
  umu_ends W3Champions.bat
  out_has 'status n/a'
  first=$(env_call 1 | head -n -1)
  rearm
  CASE_ENV=()
  go
  rc_is 0
  umu_count 2
  umu_ends W3Champions.exe
  [ "$first" = "$(env_call 2 | head -n -1)" ] || ERRS+=('the two targets got different env argv')
}

# the launcher never shows up in .bat mode: no wait on umu-run, whose own end the process check cannot see
t_bat_never_appears() {
  l_setup
  umu_hook "$T" ':'
  CASE_ENV=(W3C_LAUNCH_BAT=1 W3C_START_WAIT_SECS=2)
  go
  rc_is 1
  out_has 'did not start within 2 s (status n/a'
}

t_bat_zero() {
  l_setup
  CASE_ENV=(W3C_LAUNCH_BAT=0)
  go
  rc_is 0
  umu_ends W3Champions.exe
  rearm
  CASE_ENV=(W3C_LAUNCH_BAT=)
  go
  rc_is 0
  umu_count 2
  umu_ends W3Champions.exe
}

t_bat_usage() {
  l_setup
  CASE_ENV=(W3C_LAUNCH_BAT=2)
  go
  rc_is 2
  err_has 'W3C_LAUNCH_BAT must be 0 or 1'
  nothing_ran curl pgrep steam-runtime-launch-client pkill umu-run faugus-launcher
  [ ! -e "$T/home/.local/state/w3c-linux/lock" ] || ERRS+=('the lock file was created')
}

t_bat_unwritable() {
  local d
  if [ "$(id -u)" = 0 ]; then return 0; fi
  l_setup
  d=$(dirname "$(bat_file)")
  chmod a-w "$d"
  go
  chmod u+w "$d"
  rc_is 0
  has_row warn bat 'cannot write'
  umu_count 1
  rearm
  chmod a-w "$d"
  CASE_ENV=(W3C_LAUNCH_BAT=1)
  go
  chmod u+w "$d"
  rc_is 1
  out_has 'launch: cannot write'
  umu_count 1
}

# ---------- LAN test hint (D-15) ----------

LAN_DIR_REL='home/Faugus/battlenet/drive_c/users/steamuser/W3Champions/logs'
LAN_LOG="w3champions.$(date -u +%F).log"   # the launcher's per-UTC-day log name
LAN_MATCH='instanceHandle:searchLanGame timed out'
HINT='LAN test failed: check the UDP 16000 NAT rule'

# lan_case HOOKTEXT: l_setup with the log paths allowed and a hook that runs HOOKTEXT before the process line appears
lan_case() {
  l_setup
  ALLOW_EXTRA+=("$LAN_DIR_REL/$LAN_LOG" "$LAN_DIR_REL" "${LAN_DIR_REL%/*}" "${LAN_DIR_REL%/*/*}")
  umu_hook "$T" "$1"$'\n'"$LAUNCH_HOOK"
}

# lan_old: the log exists before the run with N_OLD matching lines
lan_old() {
  local i
  mkdir -p "$T/$LAN_DIR_REL"
  for ((i = 0; i < N_OLD; i++)); do printf '%s\n' "[2026-10-01] ERROR $LAN_MATCH" >> "$T/$LAN_DIR_REL/$LAN_LOG"; done
}

# hook text: append N matching lines to the launcher log (creating its directory)
# shellcheck disable=SC2016 # the hook text is written literally and expanded when umu-run sources it
HOOK_APPEND='d="$WINEPREFIX/drive_c/users/steamuser/W3Champions/logs"; mkdir -p "$d"'

hook_lines() {
  local i out=$HOOK_APPEND
  for ((i = 0; i < $1; i++)); do out+=$'\n'"echo \"[2026-10-08] ERROR $LAN_MATCH\" >> \"\$d/$LAN_LOG\""; done
  printf '%s' "$out"
}

hint_count() { grep -cF -- "$HINT" <<< "$OUT"; }

t_lan_hint_once() {
  lan_case "$(hook_lines 2)"
  N_OLD=1 lan_old
  go
  rc_is 0
  [ "$(hint_count)" = 1 ] || ERRS+=("hint lines: want 1 got $(hint_count)")
  out_has 'W3C_LAUNCH_BAT=1 w3c-linux.sh launch'
  out_has 'If the rule is active and this is a second or later start, close the launcher and run: '
  case $OUT in *$'\033'*) ERRS+=('the output holds an escape byte') ;; esac
  lacks_text 'ERROR'
}

t_lan_old_only() {
  lan_case 'true'
  N_OLD=1 lan_old
  go
  rc_is 0
  lacks_text 'LAN test failed'
}

t_lan_no_log() {
  lan_case "$(hook_lines 1)"
  go
  rc_is 0
  [ "$(hint_count)" = 1 ] || ERRS+=("hint lines: want 1 got $(hint_count)")
}

t_lan_bat_mode() {
  lan_case "$(hook_lines 1)"
  CASE_ENV=(W3C_LAUNCH_BAT=1)
  go
  rc_is 0
  out_has "$HINT"
  lacks_text 'W3C_LAUNCH_BAT=1 w3c-linux.sh launch'
}

t_lan_truncated() {
  lan_case "$HOOK_APPEND"$'\n'"echo \"[2026-10-08] ERROR $LAN_MATCH\" > \"\$d/$LAN_LOG\""
  N_OLD=3 lan_old
  go
  rc_is 0
  [ "$(hint_count)" = 1 ] || ERRS+=("hint lines: want 1 got $(hint_count)")
}

# ---------- guidance (LCH-07: prompts 10 to 13, D-09 to D-12) ----------

UD_REL='home/Faugus/battlenet/drive_c/users/steamuser/Documents/Warcraft III'
BONJOUR_REL='home/Faugus/battlenet/drive_c/Program Files/Blizzard/Bonjour Service'
UD_PROMPT='start Warcraft III once from Battle.net'

# no_userdata: l_setup with the Warcraft III user data folder removed and allowed to come back
no_userdata() {
  l_setup
  rmdir "$T/$UD_REL"
  ALLOW_EXTRA+=("$UD_REL")
}

t_guide_userdata_missing() {
  local i
  no_userdata
  run_fifo "$T" launch
  send $'\n'
  wait_err 'press Enter to check again'
  no_umu
  send $'\n'
  # the prompts share one stderr line (no newline), so count occurrences
  for ((i = 0; i < 100; i++)); do
    [ "$(grep -oF 'press Enter to check again' "$TMPROOT/err" | wc -l)" -ge 2 ] && break
    sleep 0.1
  done
  [ "$i" -lt 100 ] || ERRS+=('timed out waiting for the second user data prompt')
  no_umu
  mkdir -p "$T/$UD_REL"
  send $'\n'
  wait_err 'it starts again by itself'
  finish
  rc_is 0
  umu_count 1
  err_has "$UD_PROMPT"
}

t_guide_userdata_quit() {
  no_userdata
  FEED=$'\nq\n'
  run "$T" launch
  rc_is 1
  no_umu
  err_has "$UD_PROMPT"
  err_has 'Stopped; W3Champions was not started.'
}

t_guide_userdata_eof() {
  no_userdata
  FEED=$'\n'
  run "$T" launch
  rc_is 1
  no_umu
  err_has "$UD_PROMPT"
  err_has 'no answer (stdin closed); run in a terminal'
}

t_guide_bonjour_notice() {
  l_setup
  go
  rc_is 0
  out_has 'the launcher will install Bonjour and run a LAN test'
  out_has 'WC3 NOT READY'
  out_has 'w3c-linux.sh doctor'
}

t_guide_bonjour_present() {
  l_setup
  mkdir -p "$T/$BONJOUR_REL"
  : > "$T/$BONJOUR_REL/mDNSResponder.exe"
  go
  rc_is 0
  lacks_text 'install Bonjour'
}

t_guide_play() {
  l_setup
  go
  rc_is 0
  out_has "Play: use the launcher's Play button; if the game does not start, press Play in Battle.net while the launcher stays open."
  case ${OUT%%Started W3Champions*} in *"Play: use the launcher's Play button"*) ;; *) ERRS+=('the Play line is not before the start line') ;; esac
}

t_guide_restart() {
  l_setup
  run_fifo "$T" launch
  send $'\n'
  wait_err 'it starts again by itself'
  send $'\n'
  wait_err 'Restart requested: close the W3Champions window; it starts again once it has exited'
  grep -v 'W3Champions\.exe' "$T/fix/procs" > "$T/fix/procs.n"
  mv "$T/fix/procs.n" "$T/fix/procs"
  local i
  for ((i = 0; i < 100; i++)); do
    [ "$(grep -c . "$T/marks/umu-run" 2> /dev/null)" = 2 ] && break
    sleep 0.1
  done
  finish
  rc_is 0
  umu_count 2
  out_has 'Restarting W3Champions'
  [ "$(pk_lines | grep -c .)" = 4 ] || ERRS+=("pkill calls: want 4 got $(pk_lines | grep -c .)")
  [ -n "$(env_call 1)" ] && [ "$(env_call 1)" = "$(env_call 2)" ] || ERRS+=('the restart used a different env argv')
}

# text on stdin other than an empty line changes nothing
t_guide_restart_ignored() {
  l_setup
  FEED=$'\nhello\n'
  run "$T" launch
  rc_is 0
  umu_count 1
  no_err 'Restart requested'
  lacks_text 'Restarting'
}

# ---------- install hands over to launch (prompt 10) ----------

# install_setup: Battle.net on the recorded build, everything provisioned, the release fixtures in place
install_setup() {
  mk_release "$T"
  l_setup
}

t_guide_install_launch() {
  install_setup
  FEED=$'y\ny\n\n'
  run "$T" install
  rc_is 0
  err_has 'Launch now? Battle.net starts first via Faugus; sign in when it appears [Y/n]'
  err_has 'Sign in to Battle.net if it asks, then press Enter'
  out_has 'Install complete: Battle.net runs on'
  out_has 'W3Champions exited'
  umu_count 1
  umu_env_has UMU_CONTAINER_NSENTER=1
  lacks_text 'another w3c-linux.sh run is in progress'
}

t_guide_install_no() {
  install_setup
  FEED=$'y\nn\n'
  run "$T" install
  rc_is 0
  no_umu
  [ ! -e "$T/marks/faugus-launcher" ] || ERRS+=('faugus-launcher ran')
  out_has 'Next: w3c-linux.sh launch.'
  lacks_text 'arrives in a later phase'
}

t_guide_install_eof() {
  install_setup
  FEED=$'y\n'
  run "$T" install
  rc_is 0
  no_umu
  err_has 'Launch now?'
  err_has 'no answer (stdin closed); run in a terminal'
}

# quitting at the sign-in prompt after a finished install does not fail the install
t_guide_install_quit() {
  install_setup
  FEED=$'y\ny\nq\n'
  run "$T" install
  rc_is 0
  no_umu
  out_has 'Install complete: Battle.net runs on'
  out_has 'The install is complete; run w3c-linux.sh launch'
}

t_guide_install_incomplete() {
  install_setup
  no_launcher "$T"
  FEED=$'y\nn\n'
  run "$T" install
  rc_is 0
  no_err 'Launch now?'
  out_has 'Not done yet'
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
