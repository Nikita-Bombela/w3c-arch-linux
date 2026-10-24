# shellcheck shell=bash
# Check rows for the prefix, Warcraft III, host and Proton, and run_checks, which adds the Faugus rows. Used by doctor, install, update, launch and report.

# APPID and W3C_EXE derive from PREFIX.
check_derived() {
  local l
  if [ -n "$NEED_PREFIX" ]; then
    for l in PREFIX APPID W3C_EXE; do
      if [ "$BACKEND" = steam ] && [ "$l" = APPID ]; then
        emit skip APPID 'not used (backend: steam)'
      else
        emit skip "$l" "needs: $NEED_PREFIX"
      fi
    done
  else
    emit pass PREFIX "$PREFIX"
    # the APPID is the md5 bus name of the umu container; Steam names its prefix by the shortcut's appid, shown on the appid row
    if [ "$BACKEND" = steam ]; then
      emit skip APPID 'not used (backend: steam)'
    elif type -P md5sum > /dev/null; then
      APPID=$(printf %s "$PREFIX" | md5sum)
      APPID=${APPID%% *}
      emit pass APPID "$APPID"
    else
      emit skip APPID 'needs: md5sum'
    fi
    W3C_EXE="$PREFIX/drive_c/Program Files/W3Champions/W3Champions.exe"
    emit pass W3C_EXE "$W3C_EXE"
  fi
  if [ "$BACKEND" = steam ]; then
    emit skip launch-client 'not used (backend: steam)'
  elif [ -e "$LAUNCH_CLIENT" ]; then
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

# wc3_buildinfo DIR: sets WC3_BUILD (Version) and WC3_BRANCH (Branch) from the Active row of DIR/.build.info; both empty when it is unreadable.
wc3_buildinfo() {
  local r
  WC3_BUILD='' WC3_BRANCH=''
  [ -r "$1/.build.info" ] || return 0
  r=$(awk -F'|' 'NR==1{for(i=1;i<=NF;i++){split($i,h,"!"); if(h[1]=="Active")a=i; if(h[1]=="Version")v=i; if(h[1]=="Branch")b=i}; next}
    a&&v&&$a==1{print $v, (b ? $b : ""); exit}' "$1/.build.info" 2> /dev/null) || r=''
  WC3_BUILD=${r%% *}
  WC3_BRANCH=${r#* }
  [ "$WC3_BRANCH" != "$r" ] || WC3_BRANCH=''
}

# wc3_versions_text CONNECT MAX: the Warcraft III version table on stdout: the file W3C_WC3_VERSIONS names when it is non-empty (the test seam; an
# unreadable file counts as offline), else one capped GET. The HTTPS v2 endpoint serves the same table as the plain-http :1119 one, so the repo's
# https-only rule holds; every region row is in every answer. Prints nothing on any failure.
wc3_versions_text() {
  if [ -n "${W3C_WC3_VERSIONS-}" ]; then
    cat -- "$W3C_WC3_VERSIONS" 2> /dev/null
  else
    curl -fsS --proto '=https' --proto-redir '=https' --connect-timeout "$1" --max-time "$2" \
      https://us.version.battle.net/v2/products/w3/versions 2> /dev/null
  fi
  return 0
}

# wc3_current REGION: the table on stdin; prints REGION's VersionsName when it is a 4-part version, else nothing (T-22-12: the answer is only compared and printed).
wc3_current() {
  local v
  v=$(awk -F'|' -v r="$1" '/^#/{next} !c{for(i=1;i<=NF;i++){split($i,h,"!"); if(h[1]=="Region")a=i; if(h[1]=="VersionsName")v=i}; c=1; next}
    a&&v&&$a==r{print $v; exit}' 2> /dev/null) || v=''
  [[ $v =~ ^[0-9]+(\.[0-9]+){3}$ ]] && printf '%s' "$v"
  return 0
}

# wc3_status CONNECT MAX: sets WC3_CURRENT (the list's build for the prefix's Branch) and WC3_STATE (current, outdated, or empty when anything is
# unknown: no 4-part build, no Branch, no answer, no row). Needs WC3_BUILD and WC3_BRANCH from wc3_buildinfo.
wc3_status() {
  WC3_CURRENT='' WC3_STATE=''
  [[ $WC3_BUILD =~ ^[0-9]+(\.[0-9]+){3}$ ]] && [[ $WC3_BRANCH =~ ^[a-z]+$ ]] || return 0
  WC3_CURRENT=$(wc3_versions_text "$1" "$2" | wc3_current "$WC3_BRANCH")
  [ -n "$WC3_CURRENT" ] || return 0
  # shellcheck disable=SC2034 # WC3_STATE is read by doctor, launch and steam-wrap
  if version_lt "$WC3_BUILD" "$WC3_CURRENT"; then WC3_STATE=outdated; else WC3_STATE=current; fi
}

# wc3_fix: what to do about an outdated build. Under Steam nothing patches the game but update; Battle.net patches it under Faugus and umu.
wc3_fix() {
  if [ "$BACKEND" = steam ]; then printf 'run %s update' "$BIN_NAME"; else printf 'let Battle.net update Warcraft III before you play'; fi
}

# wc3_msg FIX: the one outdated line, from regex-validated versions and fixed wording (T-22-14).
wc3_msg() { printf 'Warcraft III %s is outdated (current %s): %s' "$WC3_BUILD" "$WC3_CURRENT" "$1"; }

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
    wc3_buildinfo "$WC3_DIR"
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

# nv_libver DIR: prints the driver version of the library link the loader follows in DIR (libGLX_nvidia.so.0, else libnvidia-ml.so.1) and returns 0;
# returns 1 when neither link gives a dotted number. Only the link counts, so a leftover older libGLX_nvidia.so.<old> file next to it never matters.
nv_libver() {
  local l t
  for l in libGLX_nvidia.so.0 libnvidia-ml.so.1; do
    t=$(readlink -- "$1/$l" 2> /dev/null) || continue
    t=${t##*/}
    t=${t#*.so.}
    if [[ $t =~ ^[0-9]+(\.[0-9]+)+$ ]]; then printf '%s' "$t"; return 0; fi
  done
  return 1
}

# nvidia_state: no output. Sets NV_KERNEL (the loaded module's version), NV_V64 and NV_V32 (the userspace libraries', empty when not found) and NV_STATE:
# empty (no module, or no version to trust), ok, nolib (no library link found) or mismatch; NV_TEXT is the pass text, NV_MSG the mismatch warning.
# Files only, never a GPU tool (D-09: nvidia-smi can wake a discrete GPU or hang). The family decides the directories because Fedora's 32-bit /usr/lib
# is Arch's 64-bit /usr/lib. A version is used only when it is a dotted number (T-22-09).
# ponytail: no scan of libGLX_nvidia.so.<ver> files when the link is missing (the row says "not compared"); add one if a rig shows a packager without the link.
nvidia_state() {
  local f=$SYS_ROOT/sys/module/nvidia/version d d64=() d32=()
  NV_KERNEL='' NV_V64='' NV_V32='' NV_STATE='' NV_TEXT='' NV_MSG=''
  [ -r "$f" ] && read -r NV_KERNEL < "$f"
  [[ $NV_KERNEL =~ ^[0-9]+(\.[0-9]+)+$ ]] || { NV_KERNEL=''; return 0; }
  case $DISTRO_FAMILY in
    arch) d64=(/usr/lib) d32=(/usr/lib32) ;;
    fedora) d64=(/usr/lib64) d32=(/usr/lib) ;;
    debian) d64=(/usr/lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu/nvidia/current) d32=(/usr/lib/i386-linux-gnu /usr/lib/i386-linux-gnu/nvidia/current) ;;
  esac
  for d in "${d64[@]}"; do NV_V64=$(nv_libver "$SYS_ROOT$d") && break; done
  for d in "${d32[@]}"; do NV_V32=$(nv_libver "$SYS_ROOT$d") && break; done
  if [ -n "$NV_V64$NV_V32" ] && { [ "${NV_V64:-$NV_KERNEL}" != "$NV_KERNEL" ] || [ "${NV_V32:-$NV_KERNEL}" != "$NV_KERNEL" ]; }; then
    NV_STATE=mismatch
    NV_MSG="NVIDIA kernel module $NV_KERNEL differs from its userspace libraries (64-bit ${NV_V64:-not found}, 32-bit ${NV_V32:-not found}): reboot after a driver update; if it persists, reinstall the driver so module and libraries match"
  elif [ -z "$NV_V64$NV_V32" ]; then
    NV_STATE=nolib
    NV_TEXT="kernel $NV_KERNEL (userspace libraries not found; not compared)"
  else
    NV_STATE=ok
    if [ -n "$NV_V64" ] && [ -n "$NV_V32" ]; then NV_TEXT="$NV_KERNEL (kernel = 64-bit = 32-bit)"
    elif [ -n "$NV_V64" ]; then NV_TEXT="$NV_KERNEL (kernel = 64-bit; 32-bit not found)"
    else NV_TEXT="$NV_KERNEL (kernel = 32-bit; 64-bit not found)"; fi
  fi
}

check_host() {
  local t miss='' v names=()
  # Presence only: none of these tools runs here.
  for t in curl python3 sha256sum tar md5sum pgrep; do
    type -P "$t" > /dev/null || { miss+="${miss:+ }$t"; names+=("$t"); }
  done
  if [ -z "$miss" ]; then
    emit pass 'required tools' 'curl python3 sha256sum tar md5sum pgrep'
  else
    emit fail 'required tools' "missing: $miss: $(install_hint "${names[@]}")"
  fi
  for t in zenity nft iptables sudo notify-send; do
    if type -P "$t" > /dev/null; then
      emit pass 'optional tool' "$t present"
    elif [ "$t" = sudo ]; then
      emit pass 'optional tool' 'sudo absent'   # no hint: installing sudo needs sudo
    else
      emit pass 'optional tool' "$t absent: $(install_hint "$t")"
    fi
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
  # DEBT-05, D-08: a warn at most; launch sends it to stderr, so a terminal shows it once and a menu launch logs it
  nvidia_state
  case $NV_STATE in
    ok | nolib) emit pass nvidia "$NV_TEXT" ;;
    mismatch) if [ "$CMD" = launch ]; then emit warn nvidia "$NV_MSG" >&2; else emit warn nvidia "$NV_MSG"; fi ;;
  esac
}

run_checks() {
  backend_read
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
  local t label p v='' l d L=() via='via Faugus' cdir=$PREFIX
  # umu-mode wording (Phase 10): the user starts Battle.net with this script, not with Faugus
  if [ "$BACKEND" = umu ]; then via="with $BIN_NAME launch"; fi
  # Steam wording (Phase 18): the user starts Battle.net with Play on the shortcut, and Steam keeps version and config_info beside pfx/
  if [ "$BACKEND" = steam ]; then via='with Play on the Steam shortcut' cdir=${PREFIX%/pfx}; fi
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
    elif [ "$BACKEND" = faugus ] && faugus_managed "$BN_RUNNER"; then
      emit pass 'runner dir' "$label: managed by Faugus (downloaded on first use)"
    elif [ -d "$p" ]; then
      emit warn 'runner dir' "incomplete: $p (needs proton, compatibilitytool.vdf, version, files/): rerun $BIN_NAME install"
    elif [ "$BACKEND" = umu ]; then
      emit warn 'runner dir' "missing: $p: run $BIN_NAME install"
    elif [ "$BACKEND" = steam ]; then
      emit warn 'runner dir' "missing: $p ($BN_RUNNER is mapped but is no build in this root's compatibilitytools.d: a built-in Steam tool, or a tool whose name differs from its directory)"
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
  [ -r "$cdir/version" ] && { read -r v < "$cdir/version" || true; }
  if [ -n "$v" ]; then
    emit pass 'prefix version' "$v (Proton prefix format, same for stock and W3C builds)"
  else
    emit warn 'prefix version' "absent: start Battle.net once $via"
  fi
  if [ ! -r "$cdir/config_info" ]; then
    emit skip 'prefix runner' "needs: config_info (start Battle.net once $via)"
    return 0
  fi
  mapfile -t -n 3 L < "$cdir/config_info"
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
