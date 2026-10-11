# shellcheck shell=bash
# Launcher version lookup and the in-prefix steps (WebView2, registry, launcher MSI). Used by install, update and launch.

# py_launcher: latest.json on stdin, status-first NUL fields (trust boundary at the python edge).
#   ok, version, msi_url   |   bad, reason
# stdin carries the JSON; the helper reads it from there.
py_launcher() {
  python3 -I -B "$HELPER" launcher 2> /dev/null
}

# latest_launcher MAXTIME: one GET of latest.json into a variable (never a file); sets L_LATEST and L_URL, or L_ERR and returns 1.
latest_launcher() {
  local json f=()
  L_LATEST='' L_URL='' L_ERR=''
  if ! json=$(curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 5 --max-time "$1" "$LATEST_JSON_URL" 2> /dev/null); then
    L_ERR='latest.json unreachable'
    return 1
  fi
  mapfile -d '' -t f < <(printf '%s' "$json" | py_launcher)
  # shellcheck disable=SC2034 # L_ERR is read by cmd_install in lib/install.sh
  case ${f[0]:-pyfail} in
    ok)
      if [ "${#f[@]}" -eq 3 ]; then
        L_LATEST=${f[1]} L_URL=${f[2]}
        return 0
      fi
      L_ERR='latest.json parser failed' ;;
    bad) L_ERR=${f[1]:-latest.json parser failed} ;;
    *) L_ERR='latest.json parser failed' ;;
  esac
  return 1
}

# launcher_dispver FILE: the highest DisplayVersion of the Uninstall entries named exactly W3Champions, in either registry view.
# A failed MajorUpgrade can leave an orphan entry, so the newest one wins. Prints nothing for a missing file or no valid version.
launcher_dispver() {
  local v vs=''
  while IFS= read -r v; do
    safe_version "$v" && vs+=$v$'\n'
  done < <(LC_ALL=C awk '
    function flush() { if (name == "W3Champions" && ver != "") print ver; name = ""; ver = "" }
    /^\[/ {
      flush(); h = tolower($0)
      u = index(h, tolower("[Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Uninstall\\\\")) == 1 \
        || index(h, tolower("[Software\\\\Wow6432Node\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Uninstall\\\\")) == 1
      next
    }
    u && /^"DisplayName"="/    { name = $0; sub(/^"DisplayName"="/, "", name);    sub(/"$/, "", name) }
    u && /^"DisplayVersion"="/ { ver  = $0; sub(/^"DisplayVersion"="/, "", ver);  sub(/"$/, "", ver) }
    END { flush() }
  ' "$1" 2> /dev/null)
  [ -n "$vs" ] || return 0
  printf '%s' "$vs" | sort -V -r | head -n1
}

# version_lt A B: A sorts strictly before B.
version_lt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

# launcher_status MAXTIME: reads files plus one latest.json GET, never prompts or writes. update and the Phase 4 launch
# preflight call it. Sets L_EXE (1 when the launcher exe exists), L_DISP (installed DisplayVersion), L_REC (recorded version),
# L_CUR (empty without the exe, else L_DISP, else L_REC, else unknown), L_LATEST and L_URL or L_ERR, and L_NEED (install | update | empty).
launcher_status() {
  L_EXE=0 L_DISP='' L_REC='' L_CUR='' L_NEED=''
  [ -f "$W3C_EXE" ] && L_EXE=1
  L_REC=$(read_launcher_version)
  [ -z "$PREFIX" ] || L_DISP=$(launcher_dispver "$PREFIX/system.reg")
  [ "$L_EXE" = 0 ] || L_CUR=${L_DISP:-${L_REC:-unknown}}
  latest_launcher "$1" || true
  [ -n "$L_LATEST" ] || return 0
  if [ "$L_EXE" = 0 ]; then
    L_NEED=install
  elif [ "$L_CUR" = unknown ] || version_lt "$L_CUR" "$L_LATEST"; then
    L_NEED=update
  fi
}

# dos_path PATH: the Wine view of a host path (the z: drive maps /).
dos_path() { printf 'Z:%s' "${1//\//\\}"; }

# prefix_cmd RUNNER ARGS...: fills PREFIX_CMD. Env order: Faugus toggles, launch_arguments env, envar.json, then ours, so ours always win.
# GAMEID stays unset (umu defaults it; the entry has no protonfix) and so does UMU_USE_STEAM (its steam branch wraps the command in steam.exe).
prefix_cmd() {
  local runner=$1
  shift
  PREFIX_CMD=(env -u GAMEID -u STORE -u FAUGUSID -u UMU_USE_STEAM -u UMU_CONTAINER_NSENTER
    "${FAUGUS_ENV_PRE[@]}" "${BN_LAUNCH_ENV[@]}" "${FAUGUS_ENV_POST[@]}"
    PROTON_VERB=run "WINEPREFIX=$PREFIX" "PROTONPATH=$COMPAT/$runner" "$UMU_RUN" "$@")
}

# run_in_prefix ARGS...: the only way Wine starts in the Battle.net prefix. Reads the runner from games.json now, requires a complete
# W3C build and an idle machine, then runs umu-run. Returns 125 when it refused (nothing was started), else umu-run's status.
run_in_prefix() {
  local runner
  if ! faugus_backend runner; then
    printf 'in-prefix step refused: cannot read the Battle.net entry in %s; nothing was run in the prefix\n' "$BN_SOURCE"
    return 125
  fi
  runner=$BN_RUNNER_NOW
  if ! is_w3c_runner "$runner" || ! build_complete "$COMPAT/$runner"; then
    printf 'in-prefix step refused: Battle.net runs on %s, not an installed W3C build; nothing was run in the prefix\n' "$(runner_label "$runner")"
    return 125
  fi
  if ! idle_check; then
    print_busy
    printf 'in-prefix step refused: something is still running (listed above); nothing was run in the prefix\n'
    return 125
  fi
  prefix_cmd "$runner" "$@"
  # umu and Proton chatter goes to WINE_LOG; the user sees one line saying the step is working, not stuck
  if ! { mkdir -p -- "$CACHE_DIR" && printf '\n== %s %s\n' "$(date '+%F %T')" "$*" >> "$WINE_LOG"; }; then
    printf 'in-prefix step refused: cannot write %s; nothing was run in the prefix\n' "$WINE_LOG"
    return 125
  fi
  printf 'Running %s in the Battle.net prefix; this can take a few minutes and prints nothing until it is done (Wine output: %s)\n' \
    "${1##*\\}" "$WINE_LOG"
  # fd 9 is the run lock: a child must never inherit it
  "${PREFIX_CMD[@]}" 9>&- < /dev/null >> "$WINE_LOG" 2>&1
}

# settle_wineserver: wineserver writes the registry when it exits, so wait (W3C_SETTLE_SECS, default 60) until this prefix's one is gone.
# Returns 1 when it outlives the bound. idle_check stays untouched: it sees our own lingering wineserver as busy, hence this wait between steps.
settle_wineserver() {
  local i rc
  SETTLE_MAX=60
  case ${W3C_SETTLE_SECS:-} in '' | *[!0-9]* | ?????????*) ;; *) SETTLE_MAX=$((10#$W3C_SETTLE_SECS)) ;; esac
  for ((i = 0; i < SETTLE_MAX; i++)); do
    wineserver_busy
    rc=$?
    [ "$rc" -eq 1 ] && return 0
    sleep 1
  done
  return 1
}

# reg_get FILE SECTION KEY: the raw text after KEY= in the section whose header starts with SECTION (case-insensitive), nothing when absent.
# SECTION includes the closing "]" so subkeys never match; SECTION and KEY go through ENVIRON because awk -v would eat the backslashes.
reg_get() {
  SEC=$2 KEY=$3 LC_ALL=C awk '
    BEGIN { sec = tolower(ENVIRON["SEC"]); key = tolower("\"" ENVIRON["KEY"] "\"=") }
    /^\[/ { insec = (index(tolower($0), sec) == 1); next }
    insec && index(tolower($0), key) == 1 { print substr($0, length(key) + 1); exit }
  ' "$1" 2> /dev/null
}

# wv2_find: the first msedgewebview2.exe under the prefix (find's order, not sorted); presence alone decides the skip.
wv2_find() { find "$PREFIX/drive_c" -iname msedgewebview2.exe -type f -print -quit 2> /dev/null; }

# wv2_version EXE: the Application/<version>/ directory name, else the EdgeUpdate pv value from system.reg, else nothing.
wv2_version() {
  local LC_ALL=C d=${1%/*} pv
  d=${d##*/}
  if [[ $d =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
    printf '%s' "$d"
    return 0
  fi
  pv=$(reg_get "$PREFIX/system.reg" '[Software\\Wow6432Node\\Microsoft\\EdgeUpdate\\Clients\\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}]' pv)
  pv=${pv#\"}
  pv=${pv%\"}
  if [[ $pv =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then printf '%s' "$pv"; fi
  return 0
}

# wv2_ok VERSION: the working range, major 109 or 144 and newer (110 to 143 shows a white or black launcher window).
wv2_ok() {
  local m=${1%%.*}
  [ "$m" -eq 109 ] || [ "$m" -ge 144 ]
}

# wv2_report VERSION: the version line, plus a warn row when it is unknown or outside the working range.
wv2_report() {
  if [ -z "$1" ] || ! wv2_ok "$1"; then
    emit warn webview2 "${1:-version unknown}: outside the working range (needs 144 or newer, or 109.x; 110 to 143 is the broken range that shows a white or black launcher window)${2:+ ($2)}"
  fi
}

# wv2_row EXE: doctor's webview2 row: pass inside the working range, else wv2_report's warn plus the path.
wv2_row() {
  local v
  v=$(wv2_version "$1")
  if [ -n "$v" ] && wv2_ok "$v"; then emit pass webview2 "$v ($1)"; else wv2_report "$v" "$1"; fi
}

# kill_updater [show | PATTERN]: the only process-kill line in the script. Ends the user's own processes whose command line matches PATTERN
# (default the Edge updater, which can keep the prefix's wineserver alive after the WebView2 installer returned); 1 from the command just
# means nothing matched. "show" prints the default command as the escape hatch instead.
kill_updater() {
  local pat=${1:-} c
  { [ -n "$pat" ] && [ "$pat" != show ]; } || pat='MicrosoftEdgeUpdate\.exe'
  c=(pkill -u "$UID" -f "$pat")
  if [ "${1:-}" = show ]; then
    printf "If the WebView2 installer does not return, run this in another terminal: %s %s %s %s '%s' (its updater can keep Wine busy)\n" "${c[@]}"
    return 0
  fi
  "${c[@]}" || true
}

# fetch_webview2: the Evergreen standalone installer into the cache before the idle wait, no resume.
fetch_webview2() {
  mkdir -p -- "${WV2_FILE%/*}" || { printf '%s: cannot create %s; nothing was installed\n' "$CMD" "${WV2_FILE%/*}"; return 1; }
  rm -f -- "$WV2_FILE"
  printf 'Downloading the WebView2 runtime installer to %s\n' "$WV2_FILE"
  if ! curl_get "$WV2_URL" "$WV2_FILE"; then
    rm -f -- "$WV2_FILE"
    printf '%s: WebView2 download failed (%s); nothing was installed\n' "$CMD" "$WV2_URL"
    return 1
  fi
}

# step_webview2: silent install in the prefix, clear the updater, wait for the wineserver, then trust the file.
step_webview2() {
  local rc exe v
  kill_updater show
  run_in_prefix "$(dos_path "$WV2_FILE")" /silent /install
  rc=$?
  [ "$rc" -ne 125 ] || return 1
  kill_updater
  if ! settle_wineserver; then
    printf '%s: a Wine process in the Battle.net prefix is still running %s s after the WebView2 installer; rerun install once it has exited\n' "$CMD" "$SETTLE_MAX"
    return 1
  fi
  exe=$(wv2_find)
  if [ -z "$exe" ]; then
    printf '%s: WebView2 step failed: msedgewebview2.exe not found under %s/drive_c after the installer ran (exit %s); rerun install\n' "$CMD" "$PREFIX" "$rc"
    return 1
  fi
  v=$(wv2_version "$exe")
  rm -f -- "$WV2_FILE"
  printf 'Installed WebView2 runtime %s\n' "${v:-unknown}"
  wv2_report "$v"
}

# reg_val FILE SECTION KEY: reg_get with the quotes of a string value removed.
reg_val() {
  local v
  v=$(reg_get "$1" "$2" "$3")
  v=${v#\"}
  printf '%s' "${v%\"}"
}

# win_build: the digits of CurrentBuild in system.reg, else nothing. win10_build B: Windows 10 is 10240 up to 22000 (Windows 11 starts there).
win_build() {
  local b LC_ALL=C
  b=$(reg_val "$PREFIX/system.reg" '[Software\\Microsoft\\Windows NT\\CurrentVersion]' CurrentBuild)
  if [[ $b =~ ^[0-9]+$ ]]; then printf '%s' "$b"; fi
  return 0
}

win10_build() { [[ ${1:-} =~ ^[0-9]+$ ]] && [ "$1" -ge 10240 ] && [ "$1" -lt 22000 ]; }

# the two values step_registry sets, read from the prefix files only (a section-scoped read, never a whole-file grep)
webview_winver() { reg_val "$PREFIX/user.reg" '[Software\\Wine\\AppDefaults\\msedgewebview2.exe]' Version; }

allow_local_files() { reg_get "$PREFIX/user.reg" '[Software\\Blizzard Entertainment\\Warcraft III]' 'Allow Local Files'; }

# reg_target_winver: the toggle, else the user's existing win7 or win8, else win7. A missing Allow Local Files never flips a win8.
reg_target_winver() {
  local v
  v=$(webview_winver)
  if [ -n "${W3C_WEBVIEW_WINVER:-}" ]; then
    printf '%s' "$W3C_WEBVIEW_WINVER"
  elif [ "$v" = win7 ] || [ "$v" = win8 ]; then
    printf '%s' "$v"
  else
    printf win7
  fi
}

# registry_satisfied: all three items hold, so the step is skipped; one missing item means the full apply.
registry_satisfied() {
  local v
  v=$(webview_winver)
  case $v in win7 | win8) ;; *) return 1 ;; esac
  [ -z "${W3C_WEBVIEW_WINVER:-}" ] || [ "$v" = "$W3C_WEBVIEW_WINVER" ] || return 1
  [ "$(allow_local_files)" = dword:00000001 ] || return 1
  win10_build "$(win_build)"
}

# write_w3c_reg VER: the plan.md section 5 step 4 file, ASCII with LF line ends, through a temp file and mv.
write_w3c_reg() {
  local tmp
  mkdir -p -- "$CACHE_DIR" || return 1
  tmp=$(mktemp "$CACHE_DIR/.w3c.reg.XXXXXX") || return 1
  if ! { printf '%s\n' 'Windows Registry Editor Version 5.00' '' '[HKEY_CURRENT_USER\Software\Wine\AppDefaults\msedgewebview2.exe]' \
    "\"Version\"=\"$1\"" '' '[HKEY_CURRENT_USER\Software\Blizzard Entertainment\Warcraft III]' '"Allow Local Files"=dword:00000001' > "$tmp" \
    && mv -f -- "$tmp" "$CACHE_DIR/w3c.reg"; }; then
    rm -f -- "$tmp"
    return 1
  fi
}

# step_registry: import w3c.reg, set the prefix to Windows 10, let the wineserver flush, then trust the files.
step_registry() {
  local target v a b rc cmd what
  target=$(reg_target_winver)
  write_w3c_reg "$target" || { printf '%s: cannot write %s/w3c.reg\n' "$CMD" "$CACHE_DIR"; return 1; }
  for cmd in regedit winecfg; do
    if [ "$cmd" = regedit ]; then
      run_in_prefix regedit /S "$(dos_path "$CACHE_DIR/w3c.reg")"
    else
      run_in_prefix winecfg -v win10
    fi
    rc=$?
    [ "$rc" -ne 125 ] || return 1
    if ! settle_wineserver; then
      printf '%s: a Wine process in the Battle.net prefix is still running %s s after %s; rerun install once it has exited\n' "$CMD" "$SETTLE_MAX" "$cmd"
      return 1
    fi
  done
  v=$(webview_winver)
  a=$(allow_local_files)
  b=$(win_build)
  if [ "$v" != "$target" ]; then
    what="Version is ${v:-absent} not $target"
  elif [ "$a" != dword:00000001 ]; then
    what="Allow Local Files is ${a:-absent}"
  elif ! win10_build "$b"; then
    what="build ${b:-unknown} is not Windows 10"
  else
    rm -f -- "$CACHE_DIR/w3c.reg"
    printf 'Registry set: msedgewebview2.exe Version %s, Allow Local Files dword:00000001, Windows 10 (build %s)\n' "$target" "$b"
    return 0
  fi
  printf '%s: registry step failed: %s (read from user.reg and system.reg after Wine exited); rerun install\n' "$CMD" "$what"
  return 1
}

# fetch_launcher_msi: the latest MSI into the cache before the idle wait, no resume. Sets MSI_FILE.
fetch_launcher_msi() {
  local d=$CACHE_DIR/launcher
  MSI_FILE=$d/W3Champions_${L_LATEST}_x64_en-US.msi
  mkdir -p -- "$d" || { printf '%s: cannot create %s; nothing was installed\n' "$CMD" "$d"; return 1; }
  rm -f -- "$MSI_FILE"
  printf 'Downloading W3Champions %s to %s\n' "$L_LATEST" "$MSI_FILE"
  if ! curl_get "$LAUNCHER_MSI_API" "$MSI_FILE"; then
    rm -f -- "$MSI_FILE"
    printf 'Download from %s failed; trying %s\n' "$LAUNCHER_MSI_API" "$L_URL"
    if ! curl_get "$L_URL" "$MSI_FILE"; then
      rm -f -- "$MSI_FILE"
      printf '%s: launcher download failed (%s and %s); nothing was installed\n' "$CMD" "$LAUNCHER_MSI_API" "$L_URL"
      return 1
    fi
  fi
}

# launcher_unfinished OLD: sets WHAT and returns 0 when the launcher is not in its finished state: the exe is missing, or on an upgrade
# (OLD non-empty) the old DisplayVersion is still the highest. An empty DisplayVersion counts as finished: only the exe can be checked.
launcher_unfinished() {
  if [ ! -f "$W3C_EXE" ]; then
    WHAT="$W3C_EXE is missing"
  elif [ -n "$1" ] && [ "$(launcher_dispver "$PREFIX/system.reg")" = "$1" ]; then
    WHAT="W3Champions $1 is still installed"
  else
    return 1
  fi
}

# step_launcher: install the downloaded MSI (MSI_FILE) in the prefix, trust files over exit codes, record the installed version.
# A silent run that leaves the launcher unfinished is followed by one announced interactive run: the only question install asks after the wait.
step_launcher() {
  local rc v old='' how='msiexec /qn' args=(/qn) pass
  if [ "$L_NEED" = update ] && [ "$L_CUR" != unknown ]; then old=$L_CUR; fi
  for pass in 1 2; do
    run_in_prefix msiexec /i "$(dos_path "$MSI_FILE")" "${args[@]}"
    rc=$?
    [ "$rc" -ne 125 ] || return 1
    if ! settle_wineserver; then
      printf '%s: a Wine process in the Battle.net prefix is still running %s s after %s; rerun install once it has exited\n' "$CMD" "$SETTLE_MAX" "$how"
      return 1
    fi
    launcher_unfinished "$old" || break
    if [ "$pass" = 2 ]; then
      printf '%s: launcher step failed: %s after the interactive installer; rerun install\n' "$CMD" "$WHAT"
      return 1
    fi
    if ! ask "msiexec /qn left the launcher unfinished ($WHAT, exit $rc). A Windows installer window opens in the prefix; follow it to the end. Run the MSI installer interactively?" Y; then
      printf '%s: launcher not installed (interactive installer declined); rerun install when ready\n' "$CMD"
      return 1
    fi
    args=() how='the interactive installer'
  done
  v=$(launcher_dispver "$PREFIX/system.reg")
  [ -n "$v" ] || v=$L_LATEST
  if ! write_state "$LAUNCHER_VERSION_FILE" "$v"; then
    printf '%s: cannot record the launcher version in %s\n' "$CMD" "$LAUNCHER_VERSION_FILE"
    return 1
  fi
  rm -f -- "$MSI_FILE"
  L_CUR=$v
  printf 'Installed W3Champions %s: %s\n' "$v" "$W3C_EXE"
}

# sync_launcher_record: a launcher found in the prefix with a valid DisplayVersion is adopted, and a record that disagrees is re-synced.
sync_launcher_record() {
  [ "$L_EXE" = 1 ] && [ -n "$L_DISP" ] && [ "$L_DISP" != "$L_REC" ] || return 0
  if ! write_state "$LAUNCHER_VERSION_FILE" "$L_DISP"; then
    printf '%s: cannot record the launcher version in %s\n' "$CMD" "$LAUNCHER_VERSION_FILE"
    return 1
  fi
  printf 'Recorded W3Champions %s (installed version; record was %s)\n' "$L_DISP" "${L_REC:-none}"
  L_REC=$L_DISP L_CUR=$L_DISP
}
