# shellcheck shell=bash
# Check rows for the prefix, Warcraft III, host and Proton, and run_checks, which adds the Faugus rows. Used by doctor, install, update, launch and report.

# APPID and W3C_EXE derive from PREFIX.
check_derived() {
  local l
  if [ -n "$NEED_PREFIX" ]; then
    for l in PREFIX APPID W3C_EXE; do
      emit skip "$l" "needs: $NEED_PREFIX"
    done
  else
    emit pass PREFIX "$PREFIX"
    if type -P md5sum > /dev/null; then
      APPID=$(printf %s "$PREFIX" | md5sum)
      APPID=${APPID%% *}
      emit pass APPID "$APPID"
    else
      emit skip APPID 'needs: md5sum'
    fi
    W3C_EXE="$PREFIX/drive_c/Program Files/W3Champions/W3Champions.exe"
    emit pass W3C_EXE "$W3C_EXE"
  fi
  if [ -e "$LAUNCH_CLIENT" ]; then
    emit pass launch-client "present: $LAUNCH_CLIENT"
  elif [ "$BACKEND" = umu ]; then
    emit warn launch-client "absent: $LAUNCH_CLIENT (umu downloads it the first time it starts Battle.net: run $BIN_NAME launch)"
  else
    emit warn launch-client "absent: $LAUNCH_CLIENT (umu downloads it the first time Faugus launches a game; launch Battle.net once in Faugus)"
  fi
}

check_prefix() {
  local f l
  for l in system.reg Battle.net.exe; do
    if [ -n "$NEED_PREFIX" ]; then
      emit skip "$l" "needs: $NEED_PREFIX"
      continue
    fi
    case $l in
      system.reg) f=$PREFIX/system.reg ;;
      *) f="$PREFIX/drive_c/Program Files (x86)/Battle.net/Battle.net.exe" ;;
    esac
    if [ -f "$f" ]; then
      emit pass "$l" "$f"
    else
      emit fail "$l" "Battle.net not installed in that prefix (missing $f)"
    fi
  done
}

# WC3 directory from system.reg; empty output when there is no usable value. The grep -A25 window can cross into the next registry key,
# so it is cut at the first blank line.
wc3_install_dir() {
  local w rest
  [ -r "$PREFIX/system.reg" ] || return 0
  w=$(grep -a -A25 -F '[Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Warcraft III]' "$PREFIX/system.reg" \
    | sed '/^$/q' | grep -m1 -F '"InstallLocation"=' \
    | sed -E 's/^.*="(.*)"$/\1/; s/\\\\/\\/g')
  case $w in
    [Cc]:\\*) rest=${w:3} ;;
    *) return 0 ;;
  esac
  case $rest in *..*) return 0 ;; esac
  printf '%s' "$PREFIX/drive_c/${rest//\\//}"
}

check_wc3() {
  local d ud
  if [ -n "$NEED_PREFIX" ]; then
    NEED_WC3EXE=$NEED_PREFIX
    for d in 'wc3 dir' 'wc3 exe' 'wc3 build' 'wc3 user data'; do
      emit skip "$d" "needs: $NEED_PREFIX"
    done
    return 0
  fi
  WC3_DIR=$(wc3_install_dir)
  [ -d "$WC3_DIR" ] || WC3_DIR="$PREFIX/drive_c/Program Files (x86)/Warcraft III"
  emit pass 'wc3 dir' "$WC3_DIR"
  WC3_EXE="$WC3_DIR/_retail_/x86_64/Warcraft III.exe"
  if [ -f "$WC3_EXE" ]; then
    emit pass 'wc3 exe' "$WC3_EXE"
  else
    emit fail 'wc3 exe' 'Install Warcraft III from Battle.net, start it once, then rerun'
    NEED_WC3EXE='Warcraft III.exe'
  fi
  if [ -n "$NEED_WC3EXE" ]; then
    emit skip 'wc3 build' "needs: $NEED_WC3EXE"
  else
    if [ -r "$WC3_DIR/.build.info" ]; then
      WC3_BUILD=$(awk -F'|' 'NR==1{for(i=1;i<=NF;i++){split($i,h,"!"); if(h[1]=="Active")a=i; if(h[1]=="Version")v=i}; next}
        a&&v&&$a==1{print $v; exit}' "$WC3_DIR/.build.info" 2> /dev/null)
    fi
    if [ -z "$WC3_BUILD" ] && type -P strings > /dev/null && [ -r "$WC3_DIR/.product.db" ]; then
      # strings prints 3.0.0.24268R on a real file: keep only the dotted number.
      read -r WC3_BUILD < <(strings "$WC3_DIR/.product.db" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+') || true
    fi
    if [ -n "$WC3_BUILD" ]; then
      emit pass 'wc3 build' "$WC3_BUILD"
    else
      emit warn 'wc3 build' unknown
    fi
  fi
  ud="$PREFIX/drive_c/users/steamuser/Documents/Warcraft III"
  if [ -d "$ud" ]; then
    emit pass 'wc3 user data' "$ud"
  else
    emit warn 'wc3 user data' "missing $ud: start Warcraft III once from Battle.net (Battle.net -> Warcraft III -> Play), then close it; only the game creates this folder and the W3Champions launcher refuses to start without it"
  fi
}

check_host() {
  local t miss='' v
  # Presence only: none of these tools runs here.
  for t in curl python3 sha256sum tar md5sum pgrep; do
    type -P "$t" > /dev/null || miss+="${miss:+ }$t"
  done
  if [ -z "$miss" ]; then
    emit pass 'required tools' 'curl python3 sha256sum tar md5sum pgrep'
  else
    emit fail 'required tools' "missing: $miss (install them with your package manager; needs root)"
  fi
  for t in zenity nft iptables sudo notify-send; do
    if type -P "$t" > /dev/null; then emit pass 'optional tool' "$t present"; else emit pass 'optional tool' "$t absent"; fi
  done
  # W3C_PTRACE_SCOPE_FILE is the only test seam.
  PTRACE_FILE=${W3C_PTRACE_SCOPE_FILE:-/proc/sys/kernel/yama/ptrace_scope}
  if [ ! -r "$PTRACE_FILE" ]; then
    emit pass ptrace_scope "absent ($PTRACE_FILE)"
  else
    read -r v < "$PTRACE_FILE" || true
    case $v in
      0|1) emit pass ptrace_scope "$v" ;;
      2|3) emit fail ptrace_scope "$v: Yama ptrace_scope 2 or 3 breaks ReadProcessMemory for wineserver; lowering it needs root: sudo sysctl kernel.yama.ptrace_scope=1" ;;
      *) emit warn ptrace_scope "unexpected value: $v" ;;
    esac
  fi
  if [ -d "$COMPAT" ]; then emit pass 'compat tools' "present: $COMPAT"; else emit pass 'compat tools' "absent: $COMPAT"; fi
}

run_checks() {
  faugus_backend
  faugus_row_version
  faugus_rows_entry
  check_derived
  faugus_rows_umu
  check_prefix
  check_wc3
  check_host
  faugus_rows_env
}

# check_proton: the W3C build rows of doctor. Reads files only and never fails, so doctor's exit status is unchanged.
# Called from cmd_doctor, not run_checks, so install's quiet pre-check never prints them.
check_proton() {
  local t label p v='' l d L=() via='via Faugus'
  # umu-mode wording (Phase 10): the user starts Battle.net with this script, not with Faugus
  if [ "$BACKEND" = umu ]; then via="with $BIN_NAME launch"; fi
  label=$(runner_label "$BN_RUNNER")
  t=$(read_proton_tag)
  if [ -n "$t" ]; then
    emit pass 'w3c build' "$t (recorded)"
  elif [ -e "$PROTON_TAG_FILE" ]; then
    emit warn 'w3c build' "unreadable record $PROTON_TAG_FILE: rerun $BIN_NAME install"
  else
    emit warn 'w3c build' "none recorded: run $BIN_NAME install"
  fi
  p=$(runner_dir "$BN_RUNNER")
  if [ -n "$NEED_ENTRY" ]; then
    emit skip 'runner build' "needs: $NEED_ENTRY"
    emit skip 'runner dir' "needs: $NEED_ENTRY"
  else
    if [ -z "$t" ]; then
      emit warn 'runner build' "$label is not a recorded W3C build: run $BIN_NAME install"
    elif runner_is_tag "$t"; then
      emit pass 'runner build' "$t"
    elif build_complete "$COMPAT/$t"; then
      emit warn 'runner build' "$label, expected $t: W3C build $t installed: $BIN_NAME install to switch back"
    else
      emit warn 'runner build' "$label, expected $t: run $BIN_NAME install"
    fi
    if [ -n "$BN_RUNNER" ] && build_complete "$p"; then
      emit pass 'runner dir' "$p"
    elif [ "$BACKEND" != umu ] && faugus_managed "$BN_RUNNER"; then
      emit pass 'runner dir' "$label: managed by Faugus (downloaded on first use)"
    elif [ -d "$p" ]; then
      emit warn 'runner dir' "incomplete: $p (needs proton, compatibilitytool.vdf, version, files/): rerun $BIN_NAME install"
    elif [ "$BACKEND" = umu ]; then
      emit warn 'runner dir' "missing: $p: run $BIN_NAME install"
    else
      emit warn 'runner dir' "missing: $p (Faugus would show \"$BN_RUNNER was not found\"): run $BIN_NAME install"
    fi
  fi
  if [ -n "$NEED_PREFIX" ]; then
    emit skip 'prefix version' "needs: $NEED_PREFIX"
    emit skip 'prefix runner' "needs: $NEED_PREFIX"
    return 0
  fi
  # information only: Proton writes the same prefix version for stock and W3C builds, so it is never compared
  [ -r "$PREFIX/version" ] && { read -r v < "$PREFIX/version" || true; }
  if [ -n "$v" ]; then
    emit pass 'prefix version' "$v (Proton prefix format, same for stock and W3C builds)"
  else
    emit warn 'prefix version' "absent: start Battle.net once $via"
  fi
  if [ ! -r "$PREFIX/config_info" ]; then
    emit skip 'prefix runner' "needs: config_info (start Battle.net once $via)"
    return 0
  fi
  mapfile -t -n 3 L < "$PREFIX/config_info"
  l=${L[2]:-}
  case $l in
    ?*/files/lib/)
      d=${l%/files/lib/}
      d=${d##*/}
      if [ -z "$BN_RUNNER" ] || [ "$d" = "${BN_RUNNER##*/}" ]; then
        emit pass 'prefix runner' "$d (config_info line 3)"
      else
        emit warn 'prefix runner' "last touched by $d, not $BN_RUNNER: start Battle.net once $via"
      fi ;;
    *) emit warn 'prefix runner' "config_info line 3 unrecognised: $l" ;;
  esac
}
