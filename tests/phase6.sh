#!/usr/bin/env bash
# Phase 6 fixture check: runs the real w3c-linux.sh launch with no terminal on stdin under env -i against a fake HOME per case, on the harness
# of tests/phase2.sh to tests/phase5.sh. zenity and notify-send are recording shims; zenity answers from a queue in fix/zenity.q. The older
# suites keep the terminal path through the harness-only W3C_ASSUME_TTY=1 that run_cmd sets; nt_env clears it through CASE_ENV.
# No case runs a real Wine, umu, Faugus, zenity or network call.
# Usage: bash tests/phase6.sh [GLOB]   (GLOB filters on display names such as tf-launch-menu)
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=phase5.sh
source "$(dirname "${BASH_SOURCE[0]}")/phase5.sh"

# this suite has its own cases only
mapfile -t P5_CASES < <(compgen -A function t_)
unset -f "${P5_CASES[@]}"

# notify-send is allowed here because a no-terminal launch notifies; cases that forbid notifications assert notify_calls is 0
FORBIDDEN=(wine wineserver sudo nft iptables)

# ---------- helpers ----------

# zenity_shim: a recording zenity (a '== call ==' line, then one argument per line) that answers from the first line of $FIX/zenity.q.
# A queue line is RC [STDOUT TEXT]; an empty or missing queue answers 0 with no output.
zenity_shim() {
  cat > "$T/bin/zenity" <<'SH'
#!/bin/sh
{ echo '== call =='; for a in "$@"; do printf '%s\n' "$a"; done; } >> "$MARK/zenity"
rc=0 txt=
if [ -s "$FIX/zenity.q" ]; then
  read -r rc txt < "$FIX/zenity.q"
  sed -i 1d "$FIX/zenity.q"
fi
[ -z "$txt" ] || printf '%s\n' "$txt"
exit "$rc"
SH
  chmod +x "$T/bin/zenity"
}

# zq LINE...: queues zenity answers, one per call.
zq() { printf '%s\n' "$@" >> "$T/fix/zenity.q"; }

# zen_call N: the argument lines of the N-th recorded zenity call.
zen_call() { awk -v n="$1" '/^== call ==$/ { c++; next } c == n' "$T/marks/zenity" 2> /dev/null; }

# zen_calls: how many times zenity ran.
zen_calls() {
  local n
  n=$(grep -c '^== call ==$' "$T/marks/zenity" 2> /dev/null)
  printf '%s' "${n:-0}"
}

# nt_env: a menu-style start: both shims, no terminal assumed, a display. It leaves the rest of the tree to the caller's setup.
nt_env() {
  zenity_shim
  notify_shim
  CASE_ENV=(W3C_ASSUME_TTY= DISPLAY=:0)
  ALLOW_EXTRA+=(fix/zenity.q)
}

# nt_setup: the launch tree of tests/phase4.sh, then the menu-style start.
nt_setup() {
  l_setup
  nt_env
}

# log_text: launch.log, or nothing when it is missing. log_has and log_lacks check it like out_has and lacks_text.
log_text() { cat "$T/home/.cache/w3c-linux/launch.log" 2> /dev/null; }
log_has() { case $(log_text) in *"$1"*) ;; *) ERRS+=("launch.log lacks: $1") ;; esac; }
log_lacks() { case $(log_text) in *"$1"*) ERRS+=("launch.log unexpectedly has: $1") ;; esac; }

# stop_dialog_is TEXT: exactly one error dialog, shaped as desk_error shapes it: TEXT, a blank line, the launch.log path; launch.log holds TEXT too.
# The expected path is written out here, not taken from the script.
stop_dialog_is() {
  local i n=0 want hit='' log=$T/home/.cache/w3c-linux/launch.log
  for ((i = 1; i <= $(zen_calls); i++)); do
    case $'\n'$(zen_call "$i")$'\n' in *$'\n--error\n'*) n=$((n + 1)) hit=$i ;; esac
  done
  [ "$n" = 1 ] || { ERRS+=("error dialogs: want 1 got $n"); return 0; }
  want=$'--error\n--no-markup\n--title=w3c-linux\n--width=480\n--text='"$1"$'\n\ndetails: '"$log"
  [ "$(zen_call "$hit")" = "$want" ] || ERRS+=("error dialog differs: $(zen_call "$hit")")
  log_has "$1"
}

# long_session N: the sleep shim keeps the launcher's process line for N sleeps after it started, then removes it; the lock-state line stays.
long_session() {
  local body
  # shellcheck disable=SC2016 # the shim body is written literally and expanded when the shim runs
  body='if [ -f "$FIX/armed" ]; then
  echo x >> "$FIX/ls"
  if [ "$(grep -c . "$FIX/ls")" -gt '"$1"' ]; then
    grep -v '"'W3Champions\\.exe'"' "$FIX/procs" > "$FIX/procs.n"
    mv "$FIX/procs.n" "$FIX/procs"
  fi
fi
if flock -n "$HOME/.local/state/w3c-linux/lock" true; then echo free; else echo held; fi >> "$MARK/lock"'
  sleep_shim "$T" "$body"
  ALLOW_EXTRA+=(fix/ls)
}

# bonjour_present: the fixture prefix already has the Bonjour responder, so the first-run notice is not raised.
bonjour_present() {
  mkdir -p "$T/$BONJOUR_REL"
  : > "$T/$BONJOUR_REL/mDNSResponder.exe"
  ALLOW_EXTRA+=("$BONJOUR_REL/mDNSResponder.exe")
}

# notify_is N URGENCY BODY: the N-th notification is exactly that.
notify_is() {
  [ "$(notify_call "$1")" = $'-u\n'"$2"$'\nW3Champions\n'"$3" ] || ERRS+=("notification $1 differs: $(notify_call "$1")")
}

# notify_body_starts TEXT: some notification is normal urgency with a body starting with TEXT.
notify_body_starts() {
  local i
  for ((i = 1; i <= $(notify_calls); i++)); do
    case $(notify_call "$i") in $'-u\nnormal\nW3Champions\n'"$1"*) return 0 ;; esac
  done
  ERRS+=("no normal notification starts with: $1")
}

# ---------- cases ----------

# The tracer: a start with no terminal asks the sign-in once through zenity, starts the launcher once and prints only into launch.log.
t_tf_launch_menu() {
  local p want
  p=$(pfx)
  nt_setup
  zq 0
  run "$T" launch
  rc_is 0
  [ -z "$OUT" ] || ERRS+=("stdout is not empty: $OUT")
  [ -z "$ERR" ] || ERRS+=("stderr is not empty: $ERR")
  umu_count 1
  case $(cat "$T/marks/umu-run" 2> /dev/null) in
    *" $p/drive_c/Program Files/W3Champions/W3Champions.exe") ;;
    *) ERRS+=("umu-run does not end with the host launcher path: $(cat "$T/marks/umu-run" 2> /dev/null)") ;;
  esac
  [ "$(zen_calls)" = 1 ] || ERRS+=("zenity calls: want 1 got $(zen_calls)")
  want=$'--question\n--no-markup\n--title=w3c-linux\n--text=Sign in to Battle.net if it asks, then press Enter (Yes continues, No stops)'
  [ "$(zen_call 1)" = "$want" ] || ERRS+=("zenity call 1 is not the sign-in question: $(zen_call 1)")
  case $(log_text) in '== '*' launch (no terminal)'*) ;; *) ERRS+=('launch.log does not start with the header line') ;; esac
  log_has 'Started W3Champions'
  log_has 'W3Champions exited (status 0)'
}

# stop_is RC TEXT: a stop without a terminal: the exit code, nothing on stdout or stderr, one error dialog with TEXT.
stop_is() {
  rc_is "$1"
  [ -z "$OUT" ] || ERRS+=("stdout is not empty: $OUT")
  [ -z "$ERR" ] || ERRS+=("stderr is not empty: $ERR")
  stop_dialog_is "$2"
}

# the stop texts that more than one case or a case and a helper use
STOP_NOT_STARTED='launch: not started; wait until Battle.net is up in Faugus, then rerun w3c-linux.sh launch'

# launcher not installed, no terminal: one error dialog naming launch.log, nothing on stdout or stderr
t_tf_stop_not_installed() {
  nt_setup
  no_launcher "$T"
  run "$T" launch
  stop_is 1 'launch: W3Champions is not installed in the prefix: run w3c-linux.sh install'
  no_umu
}

t_tf_stop_checks() {
  nt_setup
  rm -f "$T/home/.local/share/faugus-launcher/games.json"
  run "$T" launch
  stop_is 1 'launch: fix the failed checks above, then rerun (w3c-linux.sh doctor shows every check)'
  no_umu
}

t_tf_stop_setsid() {
  nt_setup
  rm -f "$T/bin/setsid"
  run "$T" launch
  stop_is 1 'setsid (util-linux) is missing; install it with your package manager, then rerun'
  no_umu
}

t_tf_stop_pgrep() {
  nt_setup
  printf '3\n' > "$T/fix/pgrep-rc"
  run "$T" launch
  stop_is 1 'launch: cannot check whether W3Champions is running (pgrep failed); nothing was started'
  no_umu
}

# a double start: the second run shows the lock dialog, it does not exit silently
t_tf_stop_lock() {
  local d=$T/home/.cache/w3c-linux
  nt_setup
  mkdir -p "$d"
  printf 'live session\n' > "$d/launch.log"
  hold_lock
  run "$T" launch
  drop_lock
  stop_is 1 'another w3c-linux.sh run is in progress'
  [ "$(head -n 1 "$d/launch.log")" = 'live session' ] || ERRS+=('launch.log lost the live session')
  [ ! -e "$d/launch.log.1" ] || ERRS+=('launch.log.1 was created before the launcher started')
  no_umu
}

t_tf_stop_faugus() {
  nt_setup
  rm -f "$T/fix/bus" "$T/bin/faugus-launcher"
  run "$T" launch
  stop_is 1 'launch: faugus-launcher is not on PATH; start Battle.net in Faugus, then rerun w3c-linux.sh launch'
  no_umu
}

# declining the fallback is the user's No to the question, then the stop dialog explains it
t_tf_stop_fallback_no() {
  nt_setup
  rm -f "$T/fix/bus"
  CASE_ENV+=(W3C_BUS_WAIT_SECS=0)
  zq 1
  run "$T" launch
  stop_is 1 "$STOP_NOT_STARTED"
  [ "$(zen_calls)" = 2 ] || ERRS+=("zenity calls: want 2 got $(zen_calls)")
  case $(zen_call 1) in
    *$'--question\n'*'--default-cancel'*'Battle.net container not found'*) ;;
    *) ERRS+=("call 1 is not the default-No fallback question: $(zen_call 1)") ;;
  esac
  no_umu
}

t_tf_stop_never_started() {
  nt_setup
  CASE_ENV+=(W3C_START_WAIT_SECS=3)
  no_start_hook
  zq 0
  run "$T" launch
  rc_is 1
  stop_dialog_is 'launch: W3Champions did not start within 3 s (status 0); Wine log: '"$T/home/.cache/w3c-linux/wine.log"
}

t_tf_stop_bad_bat() {
  nt_setup
  CASE_ENV+=(W3C_LAUNCH_BAT=2)
  run "$T" launch
  stop_is 2 'launch: W3C_LAUNCH_BAT must be 0 or 1, for example: W3C_LAUNCH_BAT=1 w3c-linux.sh launch'
  no_umu
}

# the user said Yes to the fallback: no error, the launcher starts in a separate container
t_tf_fallback_yes() {
  nt_setup
  rm -f "$T/fix/bus"
  CASE_ENV+=(W3C_BUS_WAIT_SECS=0)
  zq 0 0
  run "$T" launch
  rc_is 0
  umu_count 1
  umu_env_has PROTON_VERB=run
  [ "$(zen_calls)" = 2 ] || ERRS+=("zenity calls: want 2 got $(zen_calls)")
  ! zen_call 1 | grep -qx -e --error && ! zen_call 2 | grep -qx -e --error || ERRS+=('an error dialog appeared')
}

# the Warcraft III folder prompt asks again on Yes and stops quietly on No
t_tf_folder_loop() {
  nt_setup
  rm -rf "$(pfx)/drive_c/users/steamuser/Documents/Warcraft III"
  zq 0 0 1
  run "$T" launch
  rc_is 1
  no_umu
  [ "$(zen_calls)" = 3 ] || ERRS+=("zenity calls: want 3 got $(zen_calls)")
  case $(zen_call 2)$'\n'$(zen_call 3) in
    *"Warcraft III's user data folder is missing"*"Warcraft III's user data folder is missing"*) ;;
    *) ERRS+=("calls 2 and 3 are not the folder question") ;;
  esac
  ! zen_call 1 | grep -qx -e --error && ! zen_call 2 | grep -qx -e --error && ! zen_call 3 | grep -qx -e --error || ERRS+=('an error dialog appeared')
  log_has 'Stopped; W3Champions was not started.'
}

t_tf_signin_no() {
  nt_setup
  zq 1
  run "$T" launch
  rc_is 1
  no_umu
  [ "$(zen_calls)" = 1 ] || ERRS+=("zenity calls: want 1 got $(zen_calls)")
  ! zen_call 1 | grep -qx -e --error || ERRS+=('an error dialog appeared')
}

# already running is a log line: no dialog, no notification
t_tf_running_silent() {
  nt_setup
  add_proc "$T" 4500 W3Champions.exe 'C:\Program Files\W3Champions\W3Champions.exe'
  run "$T" launch
  rc_is 0
  [ "$(zen_calls)" = 0 ] || ERRS+=("zenity calls: want 0 got $(zen_calls)")
  [ "$(notify_calls)" = 0 ] || ERRS+=("notify-send calls: want 0 got $(notify_calls)")
  log_has 'W3Champions is already running; bring its window forward'
  no_umu
}

# the first-run text is a log line and a notification
t_tf_note_first_run() {
  nt_setup
  zq 0
  run "$T" launch
  rc_is 0
  log_has 'First run: the launcher will install Bonjour'
  notify_body_starts 'First run: the launcher will install Bonjour'
}

t_tf_note_newer() {
  nt_setup
  bonjour_present
  latest_17 "$T"
  zq 0
  run "$T" launch
  rc_is 0
  log_has 'newer W3Champions 1.6.17 available (installed 1.6.16): run w3c-linux.sh update'
  notify_body_starts 'newer W3Champions 1.6.17 available (installed 1.6.16): run w3c-linux.sh update'
}

# a launcher gone within ten ticks: one notification that says what to do, no Enter hint
t_tf_quick_exit() {
  nt_setup
  bonjour_present
  zq 0
  run "$T" launch
  rc_is 0
  [ "$(notify_calls)" = 1 ] || ERRS+=("notify-send calls: want 1 got $(notify_calls)")
  notify_is 1 normal "W3Champions closed right after it started (status 0): start Warcraft III once from Battle.net, close it, then start W3Champions again from the menu. Details: $T/home/.cache/w3c-linux/launch.log"
  log_lacks 'press Enter here'
}

t_tf_note_exit_zero() {
  nt_setup
  bonjour_present
  long_session 12
  zq 0
  run "$T" launch
  rc_is 0
  [ "$(notify_calls)" = 0 ] || ERRS+=("notify-send calls: want 0 got $(notify_calls)")
  log_has 'W3Champions exited (status 0)'
}

t_tf_note_exit_status() {
  nt_setup
  bonjour_present
  long_session 12
  umu_hook "$T" "$LAUNCH_HOOK"$'\nexit 3'
  zq 0
  run "$T" launch
  rc_is 0
  [ "$(notify_calls)" = 1 ] || ERRS+=("notify-send calls: want 1 got $(notify_calls)")
  notify_is 1 normal "W3Champions exited (status 3); see $T/home/.cache/w3c-linux/launch.log"
  log_has 'W3Champions exited (status 3)'
}

# pgrep fails after the start: a notification, not an error dialog
t_tf_note_pgrep_lost() {
  nt_setup
  bonjour_present
  # shellcheck disable=SC2016 # the shim body is written literally and expanded when the shim runs
  sleep_shim "$T" '[ -f "$FIX/armed" ] && echo 3 > "$FIX/pgrep-rc"'
  ALLOW_EXTRA+=(fix/pgrep-rc)
  zq 0
  run "$T" launch
  [ "$(notify_calls)" = 1 ] || ERRS+=("notify-send calls: want 1 got $(notify_calls)")
  notify_body_starts 'launch: cannot check processes (pgrep exit 3)'
  [ "$(zen_calls)" = 1 ] || ERRS+=("zenity calls: want 1 got $(zen_calls)")
}

# MON-03: with no terminal the monitor starts and is gone, lock released, once the launcher exits
t_tf_mon_gone() {
  life_setup
  nt_env
  zq 0
  run "$T" launch
  rc_is 0
  umu_count 1
  [ "$(grep -c . "$T/marks/tail.pid" 2> /dev/null)" = 1 ] || ERRS+=("tail starts: want 1 got $(grep -c . "$T/marks/tail.pid" 2> /dev/null)")
  lock_free
  all_gone
  mon_kill
}


# pty_cmd [ASSIGN...]: the env -i command line of run_cmd without W3C_ASSUME_TTY, quoted for script -c.
pty_cmd() {
  printf '%q ' env -i HOME="$T/home" PATH="$T/bin" MARK="$T/marks" FIX="$T/fix" W3C_PTRACE_SCOPE_FILE="$T/ptrace_scope" \
    W3C_PROC_DIR="$T/proc" W3C_FAUGUS_PY_DIR="$T/faugus-py" DISPLAY=:0 "$BASH_BIN" "$SCRIPT" launch
}

# no_start_markers: nothing past the gate ran.
no_start_markers() {
  local n
  for n in curl pgrep umu-run faugus-launcher steam-runtime-launch-client; do
    [ ! -e "$T/marks/$n" ] || ERRS+=("$n ran before the refusal")
  done
}

# the refusal: exit 1, empty stdout and stderr, one critical notification, the same text in launch.log, nothing started
D07_TEXT='zenity is required to launch from the menu: sudo pacman -S zenity, or run w3c-linux.sh launch from a terminal'
refusal_is() {
  rc_is 1
  [ -z "$OUT" ] || ERRS+=("stdout is not empty: $OUT")
  [ -z "$ERR" ] || ERRS+=("stderr is not empty: $ERR")
  [ "$(notify_calls)" = 1 ] || ERRS+=("notify-send calls: want 1 got $(notify_calls)")
  [ "$(notify_call 1)" = $'-u\ncritical\nW3Champions\n'"$D07_TEXT" ] || ERRS+=("notification is not the refusal: $(notify_call 1)")
  log_has "$D07_TEXT"
  no_start_markers
}

# without zenity on PATH the menu start refuses at once
t_tf_gate_no_zenity() {
  l_setup
  notify_shim
  CASE_ENV=(W3C_ASSUME_TTY= DISPLAY=:0)
  run "$T" launch
  refusal_is
}

# a display is part of a usable zenity
t_tf_gate_no_display() {
  l_setup
  zenity_shim
  notify_shim
  CASE_ENV=(W3C_ASSUME_TTY=)
  run "$T" launch
  refusal_is
  [ ! -e "$T/marks/zenity" ] || ERRS+=('zenity ran without a display')
}

# without notify-send only the log line remains
t_tf_gate_no_notify() {
  l_setup
  rm -f "$T/bin/notify-send"
  CASE_ENV=(W3C_ASSUME_TTY= DISPLAY=:0)
  run "$T" launch
  rc_is 1
  [ -z "$OUT" ] || ERRS+=("stdout is not empty: $OUT")
  [ -z "$ERR" ] || ERRS+=("stderr is not empty: $ERR")
  log_has "$D07_TEXT"
  no_start_markers
}

# newlines waiting on stdin are never read: no restart, the session ends with the launcher
t_tf_gate_no_read() {
  nt_setup
  zq 0
  run_fifo "$T" launch
  send $'\n\n\n'
  finish
  rc_is 0
  umu_count 1
  log_lacks 'Restart requested'
  [ "$(zen_calls)" = 1 ] || ERRS+=("zenity calls: want 1 got $(zen_calls)")
}

# two sessions are kept: the previous log becomes launch.log.1
t_tf_log_rotate() {
  local d=$T/home/.cache/w3c-linux
  nt_setup
  mkdir -p "$d"
  printf 'previous session\n' > "$d/launch.log"
  zq 0 0
  run "$T" launch
  rc_is 0
  [ "$(cat "$d/launch.log.1" 2> /dev/null)" = 'previous session' ] || ERRS+=('launch.log.1 does not hold the previous session')
  log_has 'Started W3Champions'
  log_has 'launch (no terminal)'
  log_lacks 'previous session'
  rearm   # a stale armed marker would let the sleep shim remove the second launcher's process line before pgrep sees it
  run "$T" launch
  rc_is 0
  case $(cat "$d/launch.log.1" 2> /dev/null) in *'Started W3Champions'*) ;; *) ERRS+=('launch.log.1 does not hold the first run') ;; esac
  case $(cat "$d/launch.log.1" 2> /dev/null) in *'previous session'*) ERRS+=('launch.log.1 still holds the session before the first run') ;; esac
}

# repeat clicks while W3Champions runs only append: same file, first line kept, launch.log.1 untouched
t_tf_log_running_keeps() {
  local d=$T/home/.cache/w3c-linux ino n
  nt_setup
  add_proc "$T" 4500 W3Champions.exe 'C:\Program Files\W3Champions\W3Champions.exe'
  mkdir -p "$d"
  printf 'live session\n' > "$d/launch.log"
  printf 'older session\n' > "$d/launch.log.1"
  ino=$(stat -c %i "$d/launch.log")
  run "$T" launch
  rc_is 0
  run "$T" launch
  rc_is 0
  [ "$(stat -c %i "$d/launch.log")" = "$ino" ] || ERRS+=('launch.log was replaced')
  [ "$(head -n 1 "$d/launch.log")" = 'live session' ] || ERRS+=('launch.log lost its first line')
  n=$(grep -c 'W3Champions is already running; bring its window forward' "$d/launch.log")
  [ "$n" = 2 ] || ERRS+=("already-running lines: want 2 got $n")
  [ "$(cat "$d/launch.log.1" 2> /dev/null)" = 'older session' ] || ERRS+=('launch.log.1 changed')
  no_umu
}

# stdout on a terminal turns colours on at source time; the log must still hold no escape byte and no tag
t_tf_log_no_colour() {
  type -P script > /dev/null || { ERRS+=('script (util-linux) is missing; the case needs a pty'); return; }
  nt_setup
  zq 0
  snap "$T" > "$TMPROOT/snap.before"
  script -qec "$(pty_cmd)< /dev/null" /dev/null < /dev/null > "$TMPROOT/out" 2> "$TMPROOT/err"
  RC=$?
  post_run "$T"
  rc_is 0
  case $(log_text) in *$'\033'*) ERRS+=('launch.log holds an escape byte') ;; esac
  log_lacks '[w3c-arch]'
  log_has 'Started W3Champions'
}

# a terminal on stdin keeps today's path: the terminal prompt, no zenity, no launch.log
t_tf_tty_unchanged() {
  type -P script > /dev/null || { ERRS+=('script (util-linux) is missing; the case needs a pty'); return; }
  l_setup
  zenity_shim
  snap "$T" > "$TMPROOT/snap.before"
  printf '\n' | script -qec "$(pty_cmd)" /dev/null > "$TMPROOT/out" 2> "$TMPROOT/err"
  RC=$?
  post_run "$T"
  rc_is 0
  OUT=$(tr -d '\r' <<< "$OUT")
  out_has 'Sign in to Battle.net if it asks, then press Enter (q to quit)'
  [ ! -e "$T/marks/zenity" ] || ERRS+=('zenity ran although stdin is a terminal')
  [ ! -e "$T/home/.cache/w3c-linux/launch.log" ] || ERRS+=('launch.log was created on a terminal run')
  umu_count 1
}

# ---------- the NAT offer without a terminal ----------

# sudo_env_shim: sudo_shim, and each call also records SUDO_ASKPASS and W3C_ASKPASS_CMD as sudo saw them.
sudo_env_shim() {
  cat > "$T/bin/sudo" <<'SH'
#!/bin/sh
{ echo '== call =='; for a in "$@"; do printf '%s\n' "$a"; done; } >> "$MARK/sudo"
{ echo "SUDO_ASKPASS=${SUDO_ASKPASS-unset}"; echo "W3C_ASKPASS_CMD=${W3C_ASKPASS_CMD-unset}"; } >> "$MARK/sudo.env"
rc=0
[ -f "$FIX/sudo-rc" ] && read -r rc < "$FIX/sudo-rc"
exit "$rc"
SH
  chmod +x "$T/bin/sudo"
}

# nat_desk_setup: a LAN-test failure with no terminal, the first-run notice out of the way, the env-recording sudo.
nat_desk_setup() {
  nl_case 1
  nt_env
  sudo_env_shim
  bonjour_present
}

# nat_q_call: the number of the NAT question among the zenity calls, or 0.
nat_q_call() {
  local i
  for ((i = 1; i <= $(zen_calls); i++)); do
    case $(zen_call "$i") in *'You will be asked for your password.'*) printf '%s' "$i"; return 0 ;; esac
  done
  printf 0
}

# the apply path: one question with the whole block, Yes, sudo -A with the helper, the printed script, the marker
nat_applied_is() {
  local want got q root=$ROOT rm_line='sudo nft delete table ip w3c'
  [ -e "$T/bin/nft" ] || rm_line='sudo iptables -t nat -D OUTPUT'
  OUT=$(log_text)
  want=$(printed_script) || ERRS+=('no printed sudo sh -c line in launch.log')
  [ "$(sudo_calls)" = 1 ] || ERRS+=("sudo calls: want 1 got $(sudo_calls)")
  got=$(sudo_call 1)
  [ "$got" = $'-A\nsh\n-c\n'"$want" ] || ERRS+=("sudo argv differs from -A and the printed line: $got")
  root=$(realpath -- "$root")
  [ "$(sed -n 1p "$T/marks/sudo.env" 2> /dev/null)" = "SUDO_ASKPASS=$root/lib/w3c-askpass.sh" ] || ERRS+=("SUDO_ASKPASS: $(sed -n 1p "$T/marks/sudo.env" 2> /dev/null)")
  [ -x "$root/lib/w3c-askpass.sh" ] || ERRS+=('the askpass helper is not executable')
  q=$(nat_q_call)
  [ "$q" != 0 ] || { ERRS+=('no NAT question'); return 0; }
  case $(zen_call "$q") in
    $'--question\n--no-markup\n--title=w3c-linux\n--default-cancel\n--text='*"    sudo sh -c '"*"$rm_line"*'You will be asked for your password.') ;;
    *) ERRS+=("the NAT question is not the block plus the notice: $(zen_call "$q")") ;;
  esac
}

# the tracer of plan 03: a LAN failure with no terminal, Yes in the NAT dialog, sudo -A runs the printed script with the askpass helper
t_tf_nat_apply() {
  local FORBIDDEN=(wine wineserver nft iptables) want got
  nat_desk_setup
  zq 0 0
  run "$T" launch
  rc_is 0
  nat_applied_is
  [ "$(sed -n 2p "$T/marks/sudo.env" 2> /dev/null)" = 'W3C_ASKPASS_CMD=nft -f -' ] || ERRS+=("W3C_ASKPASS_CMD: $(sed -n 2p "$T/marks/sudo.env" 2> /dev/null)")
  log_has 'NAT rule applied'
  want=$(< "$T/proc/sys/kernel/random/boot_id")
  got=$(cat "$T/home/.local/state/w3c-linux/nat-applied" 2> /dev/null)
  [ -n "$want" ] && [ "$got" = "$want" ] || ERRS+=("nat-applied marker: want $want got $got")
}

# No answers no sudo and no second dialog; the block is in the log
t_tf_nat_no() {
  local FORBIDDEN=(wine wineserver nft iptables)
  nat_desk_setup
  zq 0 1
  run "$T" launch
  rc_is 0
  [ "$(sudo_calls)" = 0 ] || ERRS+=("sudo calls: want 0 got $(sudo_calls)")
  [ "$(zen_calls)" = 2 ] || ERRS+=("zenity calls: want 2 got $(zen_calls)")
  log_has "    sudo sh -c '"
  log_has 'NAT rule not applied (declined)'
}

# no nft: the iptables script runs and the dialog names the iptables command
t_tf_nat_iptables() {
  local FORBIDDEN=(wine wineserver nft iptables)
  nat_desk_setup
  rm -f "$T/bin/nft"
  zq 0 0
  run "$T" launch
  rc_is 0
  nat_applied_is
  [ "$(sed -n 2p "$T/marks/sudo.env" 2> /dev/null)" = 'W3C_ASKPASS_CMD=iptables -t nat -A OUTPUT -d 255.255.255.255 -p udp --dport 16000 -j DNAT --to-destination 127.0.0.1:16000' ] \
    || ERRS+=("W3C_ASKPASS_CMD: $(sed -n 2p "$T/marks/sudo.env" 2> /dev/null)")
}

# no sudo: one info dialog with the block and the instruction, no question
t_tf_nat_no_sudo() {
  local i
  nat_desk_setup
  rm -f "$T/bin/sudo"
  zq 0
  run "$T" launch
  rc_is 0
  [ "$(nat_q_call)" = 0 ] || ERRS+=('the NAT question was asked without sudo')
  for ((i = 1; i <= $(zen_calls); i++)); do
    case $(zen_call "$i") in *$'--info\n'*"    sudo sh -c '"*'sudo is not on PATH'*) return 0 ;; esac
  done
  ERRS+=("no info dialog with the block and the sudo-missing instruction")
}

# a failed sudo: logged with its status, no marker
t_tf_nat_sudo_fail() {
  local FORBIDDEN=(wine wineserver nft iptables)
  nat_desk_setup
  printf '1\n' > "$T/fix/sudo-rc"
  ALLOW_EXTRA+=(fix/sudo-rc)
  zq 0 0
  run "$T" launch
  rc_is 0
  log_has 'NAT rule not applied (sudo exit 1)'
  [ ! -e "$T/home/.local/state/w3c-linux/nat-applied" ] || ERRS+=('the nat-applied marker exists')
}

# the retest hint fits a menu start
t_tf_nat_retest_text() {
  local FORBIDDEN=(wine wineserver nft iptables)
  nat_desk_setup
  zq 0 0
  run "$T" launch
  rc_is 0
  log_has "To retest: use the launcher's LAN test, or close W3Champions and start it again from the menu."
  log_lacks 'press Enter here'
}

# askpass_run: the helper under env -i with only the shims on PATH, as sudo -A would start it; sets AP_OUT and AP_RC
askpass_run() {
  AP_OUT=$(env -i PATH="$T/bin" MARK="$T/marks" FIX="$T/fix" W3C_ASKPASS_CMD='nft -f -' "$ROOT/lib/w3c-askpass.sh" '[sudo] password for u: ' 2> /dev/null)
  AP_RC=$?
}

t_tf_askpass_pass() {
  local want
  l_setup
  nt_env
  zq '0 hunter2'
  askpass_run
  [ "$AP_OUT" = hunter2 ] && [ "$AP_RC" = 0 ] || ERRS+=("stdout $AP_OUT, rc $AP_RC")
  [ "$(zen_calls)" = 1 ] || ERRS+=("zenity calls: want 1 got $(zen_calls)")
  want=$'--entry\n--hide-text\n--title=w3c-linux\n--width=520\n--text=w3c-linux needs your password to run as root: nft -f - (the rule shown before) so Warcraft III\'s LAN test can reach the W3Champions launcher. Nothing else is run.'
  [ "$(zen_call 1)" = "$want" ] || ERRS+=("zenity call differs: $(zen_call 1)")
}

t_tf_askpass_cancel() {
  l_setup
  nt_env
  zq 1
  askpass_run
  [ -z "$AP_OUT" ] && [ "$AP_RC" = 1 ] || ERRS+=("stdout $AP_OUT, rc $AP_RC")
}

# the helper is a POSIX sh file committed executable
t_tf_static_askpass() {
  local f=$ROOT/lib/w3c-askpass.sh mode
  [ "$(head -n 1 "$f")" = '#!/bin/sh' ] || ERRS+=('first line is not #!/bin/sh')
  [ "$(grep -c 'Nothing else is run.' "$f")" = 1 ] || ERRS+=('the closing sentence is not there exactly once')
  mode=$(git -C "$ROOT" ls-files -s lib/w3c-askpass.sh 2> /dev/null)
  case $mode in '' | 100755*) ;; *) ERRS+=("git mode: $mode") ;; esac
}

# ---------- the desktop entry (plan 04) ----------

DESK_REL=home/.local/share/applications/w3c-linux.desktop
ICON_REL=home/.local/share/icons/hicolor/256x256/apps/w3c-linux.png

# validate_desk FILE: desktop-file-validate exits 0 with no output; the tool is required.
validate_desk() {
  local o
  type -P desktop-file-validate > /dev/null || { ERRS+=('desktop-file-validate is missing: install desktop-file-utils'); return 0; }
  o=$(desktop-file-validate "$1" 2>&1) || ERRS+=("desktop-file-validate failed: $o")
  [ -z "$o" ] || ERRS+=("desktop-file-validate printed: $o")
}

# entry_exec_is EXECLINE: the written entry is the shipped file with its Exec line replaced by EXECLINE, and it validates.
entry_exec_is() {
  local want l
  [ -f "$T/$DESK_REL" ] || { ERRS+=('no desktop entry written'); return 0; }
  want=$(while IFS= read -r l; do case $l in Exec=*) printf '%s\n' "$1" ;; *) printf '%s\n' "$l" ;; esac; done < "$ROOT/share/w3c-linux.desktop")
  [ "$(< "$T/$DESK_REL")" = "$want" ] || ERRS+=("entry differs from the shipped file with Exec $1: $(< "$T/$DESK_REL")")
  validate_desk "$T/$DESK_REL"
}

# the shipped entry is valid and exact, and the shipped icon is 256 by 256
t_tf_static_desktop() {
  local f=$ROOT/share/w3c-linux.desktop want got
  validate_desk "$f"
  want=$'[Desktop Entry]\nType=Application\nName=W3Champions\nTerminal=false\nCategories=Game;\nIcon=w3c-linux\nExec=w3c-linux launch'
  got=$(grep -v '^Comment=' "$f" | LC_ALL=C sort)
  [ "$got" = "$(printf '%s\n' "$want" | LC_ALL=C sort)" ] || ERRS+=("the shipped entry has other lines: $got")
  got=$(python3 -I - "$ROOT/share/w3c-linux.png" <<'PY'
import struct, sys
b = open(sys.argv[1], 'rb').read(24)
print(b[:8] == b'\x89PNG\r\n\x1a\n' and struct.unpack('>II', b[16:24]) == (256, 256))
PY
)
  [ "$got" = True ] || ERRS+=('share/w3c-linux.png is not a 256x256 PNG')
}

# the tracer of plan 04: a complete install writes the entry with Exec on the resolved script and the shipped icon, without a prompt
t_tf_entry_install() {
  install_setup
  FEED=$'y\nn\n'
  run "$T" install
  rc_is 0
  out_has 'Install complete'
  out_has 'Desktop entry: installed'
  [ "$(grep -c '^Desktop entry: ' <<< "$OUT")" = 1 ] || ERRS+=('want exactly one Desktop entry line')
  err_has 'Launch now?'
  entry_exec_is "Exec=\"$(realpath -- "$SCRIPT")\" launch"
  cmp -s "$T/$ICON_REL" "$ROOT/share/w3c-linux.png" || ERRS+=('the installed icon is not the shipped one')
}

# icon_shims [MAGICKNAME]: recording icoextract (writes ICO to its second argument) and an ImageMagick shim named MAGICKNAME (default magick):
# it prints one 256 px frame for info: and otherwise writes "extracted" to its last argument, without the png: prefix.
# Like ImageMagick it stamps every write that lacks the date-chunk exclusion: it appends its own PID.
icon_shims() {
  cat > "$T/bin/icoextract" <<'SH'
#!/bin/sh
{ echo '== call =='; for a in "$@"; do printf '%s\n' "$a"; done; } >> "$MARK/icoextract"
[ ! -f "$FIX/ico-fail" ] || exit 1
printf ICO > "$2"
SH
  cat > "$T/bin/${1:-magick}" <<'SH'
#!/bin/sh
{ echo '== call =='; for a in "$@"; do printf '%s\n' "$a"; done; } >> "$MARK/magick"
for a in "$@"; do last=$a; done
if [ "$last" = info: ]; then echo '65536 0'; exit 0; fi
out=extracted
for a in "$@"; do [ "$a" = png:exclude-chunk=date,time ] && stamped=no; done
[ "${stamped:-}" = no ] || out=extracted$$
printf '%s' "$out" > "${last#png:}"
SH
  chmod +x "$T/bin/icoextract" "$T/bin/${1:-magick}"
  ALLOW_EXTRA+=(fix/ico-fail)
}

# entry_install: a complete install that declines the launch
entry_install() {
  FEED=$'y\nn\n'
  run "$T" install
  rc_is 0
  out_has 'Install complete'
}

# icon_is TEXT: the installed icon holds exactly TEXT
icon_is() { [ "$(cat "$T/$ICON_REL" 2> /dev/null)" = "$1" ] || ERRS+=("installed icon: want $1 got $(cat "$T/$ICON_REL" 2> /dev/null | head -c 40)"); }

t_tf_entry_icon_extracted() {
  local p=$T/home/Faugus/battlenet n
  install_setup
  icon_shims
  entry_install
  icon_is extracted
  n=$(grep -c '^== call ==$' "$T/marks/icoextract" 2> /dev/null)
  [ "${n:-0}" = 1 ] || ERRS+=("icoextract calls: want 1 got ${n:-0}")
  case $(awk '/^== call ==$/ { c++; next } c == 1' "$T/marks/icoextract") in
    "$p/drive_c/Program Files/W3Champions/W3Champions.exe"$'\n'"$T/home/.local/share/icons/hicolor/256x256/apps/"?*) ;;
    *) ERRS+=("icoextract argv: $(cat "$T/marks/icoextract")") ;;
  esac
  grep -q '^ico:.*\[0\]$' "$T/marks/magick" || ERRS+=('no magick call reads ico:<temp>[0]')
  grep -q '^png:' "$T/marks/magick" || ERRS+=('no magick call writes png:')
  entry_exec_is "Exec=\"$(realpath -- "$SCRIPT")\" launch"
}

t_tf_entry_icon_convert() {
  install_setup
  icon_shims convert
  entry_install
  icon_is extracted
}

t_tf_entry_icon_fallback() {
  install_setup
  icon_shims
  : > "$T/fix/ico-fail"
  entry_install
  cmp -s "$T/$ICON_REL" "$ROOT/share/w3c-linux.png" || ERRS+=('the installed icon is not the shipped one')
  [ "$(grep -c '^warn  desktop entry' <<< "$OUT")" = 1 ] || ERRS+=("want one warn desktop entry line: $OUT")
  out_has 'could not extract the icon from W3Champions.exe'
  out_has 'Desktop entry: installed'
}

t_tf_entry_idempotent() {
  local before after
  install_setup
  entry_install
  before=$(stat -c '%i %Y' "$T/$DESK_REL" "$T/$ICON_REL")
  sleep 1
  entry_install
  after=$(stat -c '%i %Y' "$T/$DESK_REL" "$T/$ICON_REL")
  out_has 'Desktop entry: already installed'
  [ "$before" = "$after" ] || ERRS+=("files changed on the second install: $before then $after")
  changed_is
}

# the exe-icon path is idempotent too
t_tf_entry_icon_idempotent() {
  local before after n
  install_setup
  icon_shims
  entry_install
  before=$(stat -c '%i %Y' "$T/$DESK_REL" "$T/$ICON_REL")
  sleep 1
  entry_install
  after=$(stat -c '%i %Y' "$T/$DESK_REL" "$T/$ICON_REL")
  out_has 'Desktop entry: already installed'
  [ "$before" = "$after" ] || ERRS+=("files changed on the second install: $before then $after")
  n=$(grep -c '^== call ==$' "$T/marks/icoextract" 2> /dev/null)
  [ "${n:-0}" = 2 ] || ERRS+=("icoextract calls: want 2 got ${n:-0}")
  icon_is extracted
  changed_is
}

# copy_repo DIR: the script, lib/ and share/ under DIR
copy_repo() {
  mkdir -p "$1"
  cp -r "$ROOT/w3c-linux.sh" "$ROOT/lib" "$ROOT/share" "$1/"
}

t_tf_entry_moved() {
  install_setup
  entry_install
  copy_repo "$T/other"
  local SCRIPT=$T/other/w3c-linux.sh
  entry_install
  out_has 'Desktop entry: installed'
  entry_exec_is "Exec=\"$(realpath -- "$T")/other/w3c-linux.sh\" launch"
}

# a space and a literal dollar in the path: two backslashes before the dollar
t_tf_entry_quoting() {
  install_setup
  copy_repo "$T/x y\$z"
  local SCRIPT=$T/x\ y\$z/w3c-linux.sh
  entry_install
  entry_exec_is "Exec=\"$(realpath -- "$T")/x y\\\\\$z/w3c-linux.sh\" launch"
  # shellcheck disable=SC2016 # the literal file text
  grep -qF 'x y\\$z/w3c-linux.sh" launch' "$T/$DESK_REL" || ERRS+=('the dollar is not preceded by two backslashes')
}

t_tf_entry_udd() {
  install_setup
  add_shim "$T" update-desktop-database
  entry_install
  [ "$(cat "$T/marks/update-desktop-database" 2> /dev/null)" = "$T/bin/update-desktop-database -q $T/home/.local/share/applications" ] \
    || ERRS+=("update-desktop-database after the first install: $(cat "$T/marks/update-desktop-database" 2> /dev/null)")
  entry_install
  [ "$(grep -c . "$T/marks/update-desktop-database")" = 1 ] || ERRS+=('update-desktop-database ran again for an unchanged install')
}

# an install that is not complete writes neither file
t_tf_entry_incomplete() {
  msi_setup
  FEED=$'y\nn\n'
  run "$T" install
  rc_is 0
  out_has 'Not done yet'
  lacks_text 'Desktop entry:'
  [ ! -e "$T/$DESK_REL" ] || ERRS+=('the entry exists after an incomplete install')
  [ ! -e "$T/$ICON_REL" ] || ERRS+=('the icon exists after an incomplete install')
}

# ---------- doctor row ----------

# desk_row_last: the desktop entry row is the last line of doctor's output
desk_row_last() {
  [ "$(tail -n 1 <<< "$OUT" | cut -c 7-22 | tr -d ' ')" = 'desktopentry' ] || ERRS+=("the last row is not desktop entry: $(tail -n 1 <<< "$OUT")")
}

# the tracer of plan 05: install writes the entry, doctor reports it pass with its path
t_tf_doctor_pass() {
  install_setup
  entry_install
  unset FEED
  run "$T" doctor
  has_row pass 'desktop entry' "$T/$DESK_REL"
  desk_row_last
}

t_tf_doctor_absent() {
  l_setup
  run "$T" doctor
  rc_is 0
  has_row warn 'desktop entry' 'absent: run w3c-linux.sh install'
  desk_row_last
}

# the entry names a script that has since been moved away
t_tf_doctor_dangling() {
  install_setup
  copy_repo "$T/other"
  local SCRIPT=$T/other/w3c-linux.sh
  entry_install
  mv "$T/other" "$T/gone"
  unset FEED
  SCRIPT=$ROOT/w3c-linux.sh
  run "$T" doctor
  has_row warn 'desktop entry' 'points at a missing script: run w3c-linux.sh install'
}

# a space and a dollar in the script's directory: the Exec argument decodes back to the real path
t_tf_doctor_quoting() {
  install_setup
  copy_repo "$T/x y\$z"
  local SCRIPT=$T/x\ y\$z/w3c-linux.sh
  entry_install
  unset FEED
  run "$T" doctor
  has_row pass 'desktop entry' "$T/$DESK_REL"
}

t_tf_doctor_optional_tools() {
  l_setup
  add_shim "$T" zenity
  add_shim "$T" notify-send
  run "$T" doctor
  has_row pass 'optional tool' 'zenity present'
  has_row pass 'optional tool' 'notify-send present'
}

# ---------- revert removes the entry ----------

# desk_seed: the entry and icon install wrote, plus a sibling entry and a sibling icon that are not ours
desk_seed() {
  mkdir -p "$T/${DESK_REL%/*}" "$T/${ICON_REL%/*}"
  printf 'entry\n' > "$T/$DESK_REL"
  printf 'icon\n' > "$T/$ICON_REL"
  printf 'sibling entry\n' > "$T/${DESK_REL%/*}/battlenet.desktop"
  printf 'sibling icon\n' > "$T/${ICON_REL%/*}/other.png"
}

# desk_kept: both of our files remain, and so do both siblings byte-equal
desk_kept() {
  [ -f "$T/$DESK_REL" ] || ERRS+=('the entry is gone')
  [ -f "$T/$ICON_REL" ] || ERRS+=('the icon is gone')
  [ "$(< "$T/${DESK_REL%/*}/battlenet.desktop")" = 'sibling entry' ] || ERRS+=('the sibling entry changed')
  [ "$(< "$T/${ICON_REL%/*}/other.png")" = 'sibling icon' ] || ERRS+=('the sibling icon changed')
}

# the restore to a non-W3C runner removes exactly the entry and the icon
t_tf_revert_removes() {
  w3c_on
  desk_seed
  FEED=$'y\n\n'
  run "$T" revert
  rc_is 0
  [ ! -e "$T/$DESK_REL" ] || ERRS+=('the entry remains')
  [ ! -e "$T/$ICON_REL" ] || ERRS+=('the icon remains')
  [ "$(< "$T/${DESK_REL%/*}/battlenet.desktop")" = 'sibling entry' ] || ERRS+=('the sibling entry changed')
  [ "$(< "$T/${ICON_REL%/*}/other.png")" = 'sibling icon' ] || ERRS+=('the sibling icon changed')
  [ "$(grep -c 'Removed the desktop entry' <<< "$OUT")" = 1 ] || ERRS+=("want one removal line: $OUT")
  out_has "Removed the desktop entry $T/$DESK_REL and its icon."
}

# a step back to an earlier W3C build still needs the menu entry
t_tf_revert_step_back_keeps() {
  back_setup
  desk_seed
  FEED=$'y\n\n'
  run "$T" revert
  rc_is 0
  err_has 'previous W3C build'
  lacks_text 'Removed the desktop entry'
  desk_kept
}

t_tf_revert_declined_keeps() {
  w3c_on
  desk_seed
  FEED=$'n\n'
  run "$T" revert
  out_has 'Nothing was changed.'
  desk_kept
}

t_tf_revert_no_entry() {
  w3c_on
  FEED=$'y\n\n'
  run "$T" revert
  rc_is 0
  lacks_text 'Removed the desktop entry'
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
