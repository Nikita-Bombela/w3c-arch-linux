# shellcheck shell=bash
# The monitor subcommand: match tally, day check and notifications.

# mon_start TARGET MODE: one monitor per session, started once after the first spawn (a launcher restart keeps it). The lock is taken on fd 8
# before the fork, so a second monitor, standalone or from another launch, is refused and never signalled. The subshell closes the run lock
# (fd 9) and sends its output to wine.log, so it never pins doctor or install and stays silent on the terminal.
# Never fails the launch. ponytail: the monitor shares launch's process group, so Ctrl-C ends both; a SIGKILLed launch leaves it until
# tail's --pid check (about 1 s).
mon_start() {
  if ! type -P tail > /dev/null; then
    say 'Match monitor not started: tail (coreutils) is missing.\n'
    return 0
  fi
  if ! type -P flock > /dev/null; then
    say 'Match monitor not started: flock (util-linux) is missing.\n'
    return 0
  fi
  if ! { mkdir -p -- "$W3C_STATE" && exec 8> "$MON_LOCK"; } 2> /dev/null; then
    say 'Match monitor not started: cannot write %s.\n' "$W3C_STATE"
    return 0
  fi
  if ! flock -n 8; then
    exec 8>&-
    say 'Match monitor already running (%s is held); not starting a second one.\n' "$MON_LOCK"
    return 0
  fi
  mon_tag "$1" "$2"
  ( exec 9>&- < /dev/null >> "$WINE_LOG" 2>&1; mon_loop ) &
  MON_PID=$!
  say 'Match monitor: lost results and join bugs are tallied in %s\n' "$MATCHES_LOG"
}

# mon_stop: ends the monitor launch forked (its TERM trap kills the tail), waits for it, then releases the lock. Idempotent.
# shellcheck disable=SC2329 # runs through the EXIT trap set in cmd_launch
mon_stop() {
  if [ -n "$MON_PID" ]; then
    kill "$MON_PID" 2> /dev/null
    wait "$MON_PID" 2> /dev/null
    MON_PID=''
  fi
  exec 8>&-
}

# mon_tag TARGET MODE: sets MON_TAG, the config part of every tally line. wv2flags is W3C_WRAPPER_WEBVIEW_FLAGS as launch_cmd reads it
# (unset: --no-sandbox; empty or 0: off), spaces turned into commas and every other byte outside [A-Za-z0-9._=,:+-] into _, so the
# value is one token and cannot forge a second line.
mon_tag() {
  local LC_ALL=C wv=--no-sandbox
  wv=${W3C_WRAPPER_WEBVIEW_FLAGS-$wv}
  case $wv in '' | 0) wv=off ;; esac
  wv=${wv// /,}
  MON_TAG="target=$1 mode=$2 wv2flags=${wv//[^A-Za-z0-9._=,:+-]/_}"
}

# mon_log EVENT: one short printf with >> (O_APPEND), so concurrent writers keep whole lines. A failed write is reported and survived.
mon_log() {
  mkdir -p -- "$W3C_STATE" 2> /dev/null
  { printf '%s %s %s\n' "$(date -Is)" "$1" "$MON_TAG" >> "$MATCHES_LOG"; } 2> /dev/null || printf 'monitor: cannot write %s\n' "$MATCHES_LOG" >&2
}

# mon_event LINE: turns one launcher log line into tally entries. The line is untrusted (WebView2 frontend, peers): it is
# only matched against fixed substrings, byte-wise, and none of its text is printed, logged or evaluated; only the event names are written.
mon_event() {
  local LC_ALL=C
  case $1 in
    *'PlayerMatchTelemetryReport emitted'*)
      mon_log game-end
      MON_ARMED_AT=$SECONDS ;;
    *'submitGameExited: No current match or battleTag'*)
      # ponytail: a submitted result logs "Match result <id> sent successfully" a fraction of a second after the telemetry line,
      # and that line disarms; MON_ARM_SECS stays as the fallback if a later launcher drops or renames it. Ceiling: a result lost
      # more than MON_ARM_SECS after game-end with no success line is missed.
      if [ -n "$MON_ARMED_AT" ] && [ $((SECONDS - MON_ARMED_AT)) -lt "$MON_ARM_SECS" ]; then
        mon_log RESULT-LOST
        mon_notify
      fi
      MON_ARMED_AT='' ;;
    # Anchored on the record prefix and a one-token match id, so a failure line ("... was not sent successfully") or free text cannot disarm.
    *'Match result '*' sent successfully'*)
      if [[ $1 =~ ^[^\ ]+\ +INFO\ frontend:\ \[match\]\ Match\ result\ [A-Za-z0-9]+\ sent\ successfully$ ]]; then MON_ARMED_AT=''; fi ;;
    # ponytail: every game the launcher joins logs LanGameJoined with the game's name, so the w3c-test- skip applies to every counted
    # line; flo's slot-status Joined line follows it on ladder matches only and has no game name, so counting both doubled one match.
    # Ceiling: a flo join that never logs LanGameJoined is not counted.
    *'LanGameJoined'*)
      case $1 in *'w3c-test-'*) ;; *) mon_log joined ;; esac ;;
    *'Left during game creation'* | *'join bug'*) mon_log JOIN-BUG ;;   # UNVERIFIED log form (plan.md section 12.2); tighten after the first capture
  esac
}

# mon_notify: a critical desktop notification naming the newest replay. Without notify-send the tally line is the only record.
# The body is fixed text plus a path built from our own prefix; no launcher log text enters it.
mon_notify() {
  local LC_ALL=C d=$PREFIX/drive_c/users/steamuser/Documents/Warcraft\ III/BattleNet newest='' body
  type -P notify-send > /dev/null || return 0
  # ponytail: a replay name holding a newline is cut at it
  read -r newest < <(ls -t -- "$d"/*/Replays/*.w3g 2> /dev/null)
  newest=${newest//[[:cntrl:]]/_}
  body="Match result NOT submitted (the launcher's frontend reloaded at game end); report it to W3Champions support with the replay. "
  if [ -n "$newest" ]; then body+="Newest replay: $newest"; else body+="no replay found under $d"; fi
  notify-send -u critical W3Champions "$body" 2> /dev/null || :
}

# mon_loop: follows the launcher's daily log (UTC day) from its end and feeds every line to mon_event. Returns 0 on TERM or INT; when its
# tail ends it tallies MONITOR-DOWN and returns 1. Never `tail | while`: a pipeline subshell would lose the armed state and outlive the monitor.
mon_loop() {
  local dir=$PREFIX/drive_c/users/steamuser/W3Champions/logs cur next line rc t0 start=(-n 0)
  case ${W3C_MONITOR_POLL_SECS:-} in '' | *[!0-9]* | ?????????*) ;; *) [ $((10#$W3C_MONITOR_POLL_SECS)) -eq 0 ] || MON_POLL=$((10#$W3C_MONITOR_POLL_SECS)) ;; esac   # zero would make the read a busy loop
  case ${W3C_MONITOR_ARM_SECS:-} in '' | *[!0-9]* | ?????????*) ;; *) MON_ARM_SECS=$((10#$W3C_MONITOR_ARM_SECS)) ;; esac
  cur=$(date -u +%F)
  trap '[ -z "$MON_TAIL" ] || kill "$MON_TAIL" 2> /dev/null; exit 0' TERM INT
  while :; do
    # --pid=$$ (not BASHPID): under launch's subshell the tail still dies with the launch process.
    # ponytail: a SIGKILLed launch leaves the tail for up to one tail --pid check (about 1 s).
    exec 7< <(exec tail -F "${start[@]}" --pid=$$ -- "$dir/w3champions.$cur.log" 2> /dev/null 8>&-)
    MON_TAIL=$!
    t0=$SECONDS
    while :; do
      rc=0
      read -r -t "$MON_POLL" -u 7 line || rc=$?
      if [ "$rc" = 0 ]; then
        mon_event "$line"
      elif [ "$rc" -le 128 ]; then
        printf 'monitor: tail stopped; exiting\n' >&2
        mon_log MONITOR-DOWN
        return 1
      fi
      [ $((SECONDS - t0)) -ge "$MON_POLL" ] || continue
      t0=$SECONDS
      next=$(date -u +%F)
      if [[ $next > $cur ]] && [ -e "$dir/w3champions.$next.log" ]; then
        cur=$next start=(-n +1)   # the new file already holds lines from 00:00 UTC on
        kill "$MON_TAIL" 2> /dev/null
        exec 7<&-
        continue 2
      fi
    done
  done
}

# monitor (nothing on stdout, errors on stderr): standalone entry. Resolves the prefix quietly, takes the monitor lock, follows the log.
cmd_monitor() {
  local dir
  FAILS=0
  { faugus_backend; faugus_rows_entry; check_derived; } > /dev/null
  if [ "$FAILS" -ne 0 ] || [ -z "$PREFIX" ]; then
    printf "monitor: cannot find Faugus's Battle.net prefix; run w3c-linux.sh doctor\n" >&2
    return 1
  fi
  if ! type -P tail > /dev/null; then
    printf 'monitor: tail (coreutils) is missing\n' >&2
    return 1
  fi
  if ! type -P flock > /dev/null; then
    printf 'monitor: flock (util-linux) is missing\n' >&2
    return 1
  fi
  if ! { mkdir -p -- "$W3C_STATE" && exec 8> "$MON_LOCK"; } 2> /dev/null; then
    printf 'monitor: cannot write %s\n' "$W3C_STATE" >&2
    return 1
  fi
  if ! flock -n 8; then
    printf 'monitor: already running (%s is held)\n' "$MON_LOCK" >&2
    return 0
  fi
  mon_tag '?' '?'
  dir=$PREFIX/drive_c/users/steamuser/W3Champions/logs
  [ -d "$dir" ] || printf 'monitor: %s does not exist yet; waiting for the launcher to create it\n' "$dir" >&2
  mon_loop
}
