# shellcheck shell=bash
# The doctor subcommand and its prefix-setup rows.

cmd_doctor() {
  emit pass version "w3c-linux $W3C_LINUX_VERSION"
  run_checks
  check_proton
  check_prefix_setup
  check_desktop_entry
  [ "$FAILS" -eq 0 ]
}

# check_prefix_setup: the Phase 3 rows of doctor. Reads files plus one latest.json GET and never fails, so doctor's exit
# status is unchanged. Called from cmd_doctor only. Needs the prefix, else the six rows skip and no request is made.
check_prefix_setup() {
  local l exe v a b other text
  if [ -n "$NEED_PREFIX" ]; then
    for l in webview2 'webview2 winver' 'local files' 'windows version' launcher 'launcher version'; do
      emit skip "$l" "needs: $NEED_PREFIX"
    done
    return 0
  fi
  exe=$(wv2_find)
  if [ -z "$exe" ]; then emit warn webview2 "absent: run $BIN_NAME install"; else wv2_row "$exe"; fi
  v=$(webview_winver)
  case $v in
    win7 | win8)
      other=win8
      [ "$v" = win8 ] && other=win7
      emit pass 'webview2 winver' "$v (white or black launcher window or ole32 crash: W3C_WEBVIEW_WINVER=$other $BIN_NAME install)" ;;
    '') emit warn 'webview2 winver' "unset: run $BIN_NAME install" ;;
    *) emit warn 'webview2 winver' "$v: expected win7 or win8: run $BIN_NAME install" ;;
  esac
  a=$(allow_local_files)
  if [ "$a" = dword:00000001 ]; then
    emit pass 'local files' "Allow Local Files $a"
  else
    emit warn 'local files' "Allow Local Files ${a:-absent}: run $BIN_NAME install"
  fi
  b=$(win_build)
  if win10_build "$b"; then
    emit pass 'windows version' "Windows 10 (build $b)"
  elif [ -n "$b" ] && [ "$b" -ge 22000 ]; then
    emit warn 'windows version' "Windows 11 (build $b): the launcher needs Windows 10: run $BIN_NAME install"
  else
    emit warn 'windows version' "unknown (CurrentBuild ${b:-absent}): run $BIN_NAME install"
  fi
  if [ -f "$W3C_EXE" ]; then emit pass launcher "$W3C_EXE"; else emit warn launcher "not installed: run $BIN_NAME install"; fi
  launcher_status 5   # the one network call
  text="installed ${L_DISP:--}, recorded ${L_REC:--}, latest ${L_LATEST:-unknown: offline}"
  if [ "$L_EXE" = 0 ] || [ "$L_CUR" = unknown ]; then
    emit warn 'launcher version' "$text: run $BIN_NAME install"
  elif [ -z "$L_LATEST" ]; then
    emit warn 'launcher version' "$text"
  elif [ -n "$L_DISP" ] && [ -n "$L_REC" ] && [ "$L_DISP" != "$L_REC" ]; then
    emit warn 'launcher version' "$text: record differs from installed; install or update re-syncs it"
  elif version_lt "$L_CUR" "$L_LATEST"; then
    emit warn 'launcher version' "$text: newer launcher available: run $BIN_NAME update"
  else
    emit pass 'launcher version' "$L_CUR ($text)"
  fi
}

# check_desktop_entry: the menu entry row. Reads files and never fails, so doctor's exit status is unchanged. With the package's entry under
# SYS_ROOT the row says so, or warns when a per-user file hides it (D-11). The Exec line is only decoded and tested with -f, never run.
check_desktop_entry() {
  local p sys=$SYS_ROOT/usr/share/applications/w3c-linux.desktop
  if [ -f "$sys" ]; then
    if [ -e "$DESK_FILE" ] || [ -L "$DESK_FILE" ]; then
      # install removes only an entry desk_ours accepts, so any other file needs the user's hand (Phase 9 D-01)
      if desk_ours "$DESK_FILE"; then
        emit warn 'desktop entry' "$DESK_FILE hides the system entry: run $BIN_NAME install, or delete it"
      else
        emit warn 'desktop entry' "$DESK_FILE is not written by w3c-linux and hides the system entry: delete it if unwanted"
      fi
    else
      emit pass 'desktop entry' "$sys (system)"
    fi
    return 0
  fi
  if [ ! -f "$DESK_FILE" ]; then
    emit warn 'desktop entry' "absent: run $BIN_NAME install"
    return 0
  fi
  p=$(desk_exec_path "$DESK_FILE")
  if [ -n "$p" ] && [ -f "$p" ]; then
    emit pass 'desktop entry' "$DESK_FILE"
  else
    emit warn 'desktop entry' "$DESK_FILE points at a missing script: run $BIN_NAME install"
  fi
}
