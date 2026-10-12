# shellcheck shell=bash
# The update subcommand and its upstream watch.

# py_json_str KEY: JSON on stdin; prints the top-level KEY when the document is an object and the value is a str without NUL, else nothing.
py_json_str() {
  python3 -I -B "$HELPER" json-str "$1" 2> /dev/null
  return 0
}

# watch_get URL: one GET to stdout, never to disk.
watch_get() {
  curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 5 --max-time 20 "$1" 2> /dev/null
}

# watch_upstream TAG: the upstream-fix watch for the recorded W3C tag (may be empty). Prints only;
# it never writes a file, switches the runner or touches games.json. Every item degrades to "could not check" on its own.
watch_upstream() {
  local body n state ge base
  printf 'Upstream fix watch (advisory; nothing here changes the runner):\n'
  # only the get_job_info request block counts: limit_flags also appears in set_job_limits, so a whole-file count would be wrong
  n=-1
  if body=$(watch_get "$WINE_PROTOCOL_URL") && [ -n "$body" ]; then
    n=$(awk '/^@REQ\(get_job_info\)/ { inb = 1; started = 1; next }
      inb && /^@END/ { exit }
      inb && /limit_flags/ { c++ }
      END { print started ? c + 0 : -1 }' <<< "$body")
  fi
  case $n in
    0) printf '    Wine master: the get_job_info reply has no limit_flags yet (server/protocol.def): no upstream fix\n' ;;
    -1) printf '    could not check Wine master (server/protocol.def get_job_info)\n' ;;
    *) printf '    Wine master: the get_job_info reply now carries limit_flags (server/protocol.def): an upstream fix may have landed; once stock GE-Proton ships it Battle.net can go back to Proton-GE Latest by hand (this wrapper never switches back by itself)\n' ;;
  esac
  state=$(watch_get "$ISSUE57_API" | py_json_str state)
  case $state in
    open) printf '    w3champions-issues #57 is open: %s\n' "$ISSUE57_URL" ;;
    closed) printf '    w3champions-issues #57 is closed: the launcher may accept stock Wine now; read %s before changing runners\n' "$ISSUE57_URL" ;;
    *) printf '    could not check w3champions-issues #57\n' ;;
  esac
  ge=$(watch_get "$GE_RELEASE_API" | py_json_str tag_name)
  base=${1%-W3C}
  if [ -z "$ge" ] || ! safe_tag "$ge"; then
    printf "    could not check GE-Proton's latest release\n"
  elif [ -z "$1" ] || [ "$base" = "$1" ]; then
    printf '    could not check whether the W3C build lags GE (no W3C build recorded)\n'
  elif version_lt "$base" "$ge"; then
    printf "    %s is newer than the W3C build's base %s: stay on %s, wait for a rebase of %s, or rebuild the patches on %s following the fork README\n" "$ge" "$base" "$1" "$FORK_URL" "$ge"
  else
    printf '    GE-Proton latest is %s; the W3C build %s is based on %s: not lagging\n' "$ge" "$1" "$base"
  fi
  printf '    GE code search for JobObjectBasicLimitInformation (needs a GitHub login): %s\n' "$GE_SEARCH_URL"
}

# update: checks the launcher and the patched Proton, asks everything first, downloads, waits once, switches the runner to the
# new build first and then runs the MSI on it. The old build stays installed and proton-tag.prev names it.
cmd_update() {
  local recorded='' want_proton=0 want_msi=0 want_rm=0 offered=0 offer_proton=0
  # shellcheck disable=SC2034 # CMD is read by fetch_verify_extract in lib/proton.sh
  CMD=update
  # shellcheck disable=SC2034 # QUIET_PASS is read by emit in lib/common.sh
  QUIET_PASS=1
  run_checks
  if [ "$FAILS" -gt 0 ]; then
    printf 'update: fix the failed checks above, then rerun (%s doctor shows every check)\n' "$BIN_NAME"
    return 1
  fi
  acquire_lock
  trap cleanup_staging EXIT
  recorded=$(read_proton_tag)
  if [ -z "$recorded" ] || ! build_complete "$COMPAT/$recorded"; then
    printf 'patched Proton: no complete W3C build recorded; run %s install\n' "$BIN_NAME"
  elif ! resolve_release; then
    emit warn 'w3c build' "could not check for a newer build ($RT_ERR)"
  elif [ "$RT_TAG" = "$recorded" ]; then
    printf 'patched Proton %s up to date\n' "$recorded"
  else
    offer_proton=1   # compared with proton-tag only, never by listing compatibilitytools.d
  fi
  launcher_status 30
  sync_launcher_record || return 1
  if [ "$L_EXE" = 0 ]; then
    printf 'W3Champions is not installed: run %s install\n' "$BIN_NAME"
  elif [ -z "$L_LATEST" ]; then
    emit warn launcher "could not check for a newer launcher ($L_ERR); W3Champions $L_CUR stays"
  elif [ -z "$L_NEED" ]; then
    printf 'launcher %s up to date\n' "$L_CUR"
  fi
  watch_upstream "$recorded"
  # every question first, so the user can walk away once the downloads are done
  if [ "$offer_proton" = 1 ]; then
    offered=1
    if build_complete "$COMPAT/$RT_TAG"; then
      ask "Switch Faugus's Battle.net runner to $RT_TAG? $recorded stays installed; $BIN_NAME revert switches back." Y && want_proton=1
    else
      ask "Install $RT_TAG (about $RT_SIZE) and switch Faugus's Battle.net runner to it? $recorded stays installed; $BIN_NAME revert switches back." Y && want_proton=1
    fi
  fi
  if [ "$L_NEED" = update ]; then
    if [ "$want_proton" = 1 ] || is_w3c_runner "$BN_RUNNER"; then
      offered=1
      ask "Update W3Champions $L_CUR -> $L_LATEST?" Y && want_msi=1
    else
      printf 'launcher update needs Battle.net on a W3C build: run %s install\n' "$BIN_NAME"
    fi
  fi
  if [ "$offer_proton" = 0 ] && prev_removal_due; then   # never in a run that offers the switch
    offered=1
    if ask_prev_removal; then want_rm=1; fi
  fi
  if [ "$want_proton$want_msi$want_rm" = 000 ]; then
    [ "$offered" = 0 ] || printf 'Nothing was changed.\n'
    return 0
  fi
  # downloads before the wait, while Faugus or Battle.net may still run
  if [ "$want_proton" = 1 ] && ! build_complete "$COMPAT/$RT_TAG"; then fetch_verify_extract || return 1; fi
  if [ "$want_msi" = 1 ]; then
    case $CACHE_DIR in "$HOME"/*) ;; *) emit warn cache "$CACHE_DIR is outside $HOME; Wine's container may not see installers there (set XDG_CACHE_HOME under $HOME)" ;; esac
    fetch_launcher_msi || return 1
  fi
  wait_idle
  if [ "$want_rm" = 1 ]; then remove_prev || return 1; fi
  if [ "$want_proton" = 1 ]; then
    if [ "$BN_RUNNER" != "$RT_TAG" ]; then   # an earlier run that stopped after the switch only needs the records
      if ! idle_check; then
        print_busy
        printf 'update: something started again (listed above); games.json was not changed, rerun update\n'
        return 1
      fi
      switch_runner "$RT_TAG" || return 1
      BN_RUNNER=$RT_TAG
    fi
    if ! write_state "$PROTON_PREV_FILE" "$recorded"; then
      printf 'update: cannot record %s; rerun update\n' "$PROTON_PREV_FILE"
      return 1
    fi
    if ! write_proton_tag "$RT_TAG"; then
      printf 'update: cannot record %s; rerun update\n' "$PROTON_TAG_FILE"
      return 1
    fi
    printf 'Recorded %s; the previous W3C build %s stays installed (%s revert switches back to it)\n' "$RT_TAG" "$recorded" "$BIN_NAME"
  fi
  # run_in_prefix reads the runner from games.json now, so msiexec runs on the new build
  if [ "$want_msi" = 1 ]; then step_launcher || return 1; fi
  printf 'Update finished.\n'
}
