# shellcheck shell=bash
# install, update and revert under the Steam backend (Phase 19). Every Steam change is a printed click path. This file writes only the W3C build
# (through lib/proton.sh), state files under W3C_STATE, the cache and, from plan 19-02 on, the Battle.net installer in the download directory,
# never a Steam config file.

STEAM_PREV_TOOL_FILE=$W3C_STATE/steam-prev-tool   # D-08: the CompatToolMapping name the shortcut used before w3c-linux; written once by install, read and removed by revert
BN_SETUP_URL='https://www.battle.net/download/getInstallerForGame?os=win&version=LIVE&gameProgram=BATTLENET_APP'   # Blizzard's installer (verified 2026-10-17: https hops only, an MZ file; RESEARCH A1 keeps it unverified long term)
BN_SETUP_FILE=''   # the installer file step 1 names, set by steam_fetch_setup
SS_LABEL=() SS_DONE=()   # the Steam steps, index 1 to 6 (index 0 is unused): their labels and their done flags, filled by steam_steps
STEAM_LAST_PAGE=''   # the page steam_show_page printed last, without its still-waiting line

# steam_hard_stop: returns 0 and prints one line when the finder stopped on something no Steam click fixes here, else returns 1 and prints
# nothing (D-20). A missing shortcut alone is checklist step 1, not a stop. First match wins.
steam_hard_stop() {
  local why=''
  if [ -z "$ST_ROOT" ]; then
    why=$ST_ERR
  elif [ "$NEED_ENTRY" = python3 ]; then
    why="python3 is missing: $(install_hint python3)"
  elif [ "$ST_STOP" = account ] || [ "$ST_STOP" = prefix ]; then
    why=$ST_STOPMSG
  elif [ "$ST_STOP" = shortcut ]; then
    [ "$ST_NM" = 0 ] && [ -z "$ST_OVR" ] && [ "$NEED_ENTRY" = 'one Battle.net shortcut' ] && return 1
    why=$ST_STOPMSG
  fi
  [ -n "$why" ] || return 1
  printf '%s: %s (%s doctor shows every check)\n' "$CMD" "$why" "$BIN_NAME"
}

# steam_steps TAG: fills SS_LABEL and SS_DONE from what backend_read just set. Files only; run_checks is never called here because its fail
# rows print even under QUIET_PASS.
steam_steps() {
  local w wc ud exe=${ST_EXE,,}
  SS_LABEL=('' 'Add the Battle.net shortcut' "Select $1 as its compatibility tool" 'Play once: Battle.net installs into the new prefix'
    'Point the shortcut at Battle.net.exe' 'Sign in, install Warcraft III, start it once, exit Battle.net' 'Point the shortcut at W3Champions.exe')
  SS_DONE=(0 0 0 0 0 0 0)
  [ -z "$ST_APPID" ] || SS_DONE[1]=1
  [ "$BN_RUNNER" != "$1" ] || SS_DONE[2]=1
  if [ -n "$PREFIX" ]; then
    [ ! -f "$PREFIX/drive_c/Program Files (x86)/Battle.net/Battle.net.exe" ] || SS_DONE[3]=1
    # the Warcraft III directory is where Battle.net put it; the same two paths check_wc3 reads
    w=$(wc3_install_dir)
    [ -d "$w" ] || w="$PREFIX/drive_c/Program Files (x86)/Warcraft III"
    wc="$w/_retail_/x86_64/Warcraft III.exe"
    ud="$PREFIX/drive_c/users/steamuser/Documents/Warcraft III"
    if [ -f "$wc" ] && [ -d "$ud" ]; then SS_DONE[5]=1; fi
  fi
  # a finished Warcraft III setup never sends a W3Champions.exe shortcut back to Battle.net.exe
  if [ "$exe" = battle.net.exe ] || [ "${SS_DONE[5]}" = 1 ]; then SS_DONE[4]=1; fi
  [ "$exe" != w3champions.exe ] || SS_DONE[6]=1
}

# steam_title N LABEL: a walk step's title line, bold on a terminal (D-12).
steam_title() { printf '%sStep %s: %s%s\n' "$S_BOLD" "$1" "$2" "$S_RST"; }

# steam_checklist: the numbered list of every step in SS_LABEL, [x] for a done one. Generic over the arrays, so update and revert reuse it.
steam_checklist() {
  local i
  printf "Steam steps (checked from Steam's files; [x] done):\n"
  for ((i = 1; i < ${#SS_LABEL[@]}; i++)); do
    if [ "${SS_DONE[i]}" = 1 ]; then printf '  %s[x]%s %d. %s\n' "$S_OK" "$S_RST" "$i" "${SS_LABEL[i]}"; else printf '  [ ] %d. %s\n' "$i" "${SS_LABEL[i]}"; fi
  done
}

# steam_click N [NAME]: the literal click path of step type N, indented four spaces (labels from the Phase 16 click path). NAME is the tool to
# select (default: the recorded build). Nothing here offers removing the shortcut: that deletes the prefix and the mapping (D-16).
steam_click() {
  local n=$1 name=${2:-$(read_proton_tag)} dir exe opts
  [ -n "$ST_PID" ] || printf '    Steam is not running: start Steam first.\n'
  case $n in
    1)
      printf '    Steam: Games > Add a Non-Steam Game to My Library > Browse...\n'
      printf '    In the file picker press Ctrl+L, paste %s%s%s, set the All Files filter, then Select > Add Selected Programs\n' \
        "$S_VAL" "${BN_SETUP_FILE:-the Battle.net installer from battle.net}" "$S_RST" ;;
    2)
      printf '    Restart Steam (Steam menu > Exit, then start Steam again): Steam lists a new compatibility tool only after a restart.\n'
      printf '    Then right-click the shortcut > Properties > Compatibility > turn on "Show all compatibility tools" > Select compatibility tool > %s%s%s\n' "$S_VAL" "$name" "$S_RST" ;;
    3) printf '    Press Play on the shortcut: the Battle.net installer runs in the new prefix; keep its default install location.\n' ;;
    4 | 6)
      if [ "$n" = 4 ]; then
        dir=$PREFIX/drive_c/Program\ Files\ \(x86\)/Battle.net exe=Battle.net.exe opts='WINE_SIMULATE_WRITECOPY=1 PROTON_ENABLE_WAYLAND=0 %command%'
      else
        dir=$PREFIX/drive_c/Program\ Files/W3Champions exe=W3Champions.exe
        opts=$(steam_launch_opts)   # Phase 20 D-09: the spike's string plus the absolute steam-wrap command
      fi
      printf '    Right-click the shortcut > Properties > Shortcut, and set:\n    Target: %s"%s/%s"%s\n    Start In: %s"%s/"%s\n    Launch Options: %s%s%s\n' \
        "$S_VAL" "$dir" "$exe" "$S_RST" "$S_VAL" "$dir" "$S_RST" "$S_VAL" "$opts" "$S_RST"
      if [ "$n" = 4 ]; then
        # D-09: this retarget (install step 4 and every revert) drops steam-wrap; Launch Options are only ever pasted by the user
        printf '    These Launch Options replace the current ones; steam-wrap, if it is there, goes with them.\n'
      elif [[ $(steam_wrap_cmd) == \'* ]]; then
        printf '    (the command path holds a space or a special character; Steam may not parse it: a path of plain characters is safest)\n'
      fi ;;
    5)
      printf '    Press Play, sign in to Battle.net and install Warcraft III at its default location.\n'
      printf '    Start Warcraft III once (Battle.net > Warcraft III > Play), close it, then quit Battle.net (its menu > Exit).\n' ;;
  esac
}

# steam_wait PAGE (D-01, D-19): shows PAGE and waits. Enter (or a zenity Yes) returns 0; q, a zenity No or EOF print the stop line and exit 1, so
# the EXIT trap cleans staging.
steam_wait() {
  local ans=''
  if use_zenity; then
    # the dialog shows the page without its SGR sequences (D-12)
    # shellcheck disable=SC2001 # a glob replacement cannot match the variable-length sequence
    zenity --question --no-markup --title=w3c-linux --text="$(sed $'s/\033\\[[0-9;]*m//g' <<< "$1")"$'\n\n'"Yes checks again, No stops." 2> /dev/null && return 0
  else
    printf '%spress Enter to check again (q to quit): %s' "$S_ITAL" "$S_IRST" >&2
    if ! read -r ans && [ -z "$ans" ]; then
      printf 'no answer (stdin closed); run in a terminal\n' >&2
    elif [ "${ans,,}" != q ]; then
      return 0
    fi
  fi
  printf 'Stopped; rerun %s %s to continue.\n' "$BIN_NAME" "$CMD"
  exit 1
}

# steam_show_page PAGE LINE (D-12): prints PAGE, and under it LINE when PAGE is the page shown last (the re-read changed nothing), then waits on that
# text, so zenity gets the line too.
steam_show_page() {
  local shown=$1
  if [ "$1" = "$STEAM_LAST_PAGE" ]; then shown+=$'\n'$2; fi
  STEAM_LAST_PAGE=$1
  printf '%s\n' "$shown"
  steam_wait "$shown"
}

# steam_save_prev_tool (D-08): the first time install sees the shortcut on a tool that is not a W3C build, keep that name for revert. Never
# overwritten. The name is stored as Steam has it (it may hold spaces).
steam_save_prev_tool() {
  [ ! -e "$STEAM_PREV_TOOL_FILE" ] && [ -n "$BN_RUNNER" ] && ! is_w3c_runner "$BN_RUNNER" || return 0
  write_state "$STEAM_PREV_TOOL_FILE" "$BN_RUNNER" || emit warn 'steam tool' "could not save the shortcut's tool name in $STEAM_PREV_TOOL_FILE; revert will not restore it"
}

# steam_download_dir: prints the directory Steam's file picker opens in: XDG_DOWNLOAD_DIR from user-dirs.dirs, else ~/Downloads (created). The
# file is read as data, never sourced; only a leading literal $HOME is expanded and only an absolute existing directory is accepted.
steam_download_dir() {
  local f=${XDG_CONFIG_HOME:-$HOME/.config}/user-dirs.dirs k v d=''
  if [ -r "$f" ]; then
    while IFS='=' read -r k v || [ -n "$k" ]; do
      [ "$k" = XDG_DOWNLOAD_DIR ] || continue
      v=${v#\"} v=${v%\"}
      v=${v%/}   # "$HOME/" is the xdg-user-dirs "disabled" value, so $HOME itself counts as unset
      case $v in \$HOME | \$HOME/*) v=$HOME${v#\$HOME} ;; esac
      if [[ $v == /* ]] && [ "$v" != "${HOME%/}" ] && [ -d "$v" ]; then d=$v; fi
    done < "$f"
  fi
  if [ -z "$d" ]; then
    d=$HOME/Downloads
    mkdir -p -- "$d" || return 1
  fi
  printf '%s\n' "$d"
}

# steam_fetch_setup (D-04): puts Battle.net's installer where Steam's file picker finds it and sets BN_SETUP_FILE. An MZ file already there is
# reused. The download goes to a temp file in the same directory and is moved into place only after the MZ check, so a failure leaves nothing;
# no sha256, Blizzard rotates the file.
steam_fetch_setup() {
  local d f tmp=''
  d=$(steam_download_dir) || { printf '%s: cannot create the download directory %s\n' "$CMD" "$HOME/Downloads"; return 1; }
  f=$d/Battle.net-Setup.exe
  if [ -f "$f" ] && [ ! -L "$f" ] && [ "$(head -c2 -- "$f")" = MZ ]; then
    BN_SETUP_FILE=$f
    printf 'Battle.net installer: %s (already downloaded)\n' "$f"
    return 0
  fi
  printf 'Downloading the Battle.net installer to %s\n' "$f"
  tmp=$(mktemp "$d/.Battle.net-Setup.exe.XXXXXX") || tmp=''
  if [ -n "$tmp" ] && curl_get "$BN_SETUP_URL" "$tmp" && [ "$(head -c2 -- "$tmp")" = MZ ] && mv -fT -- "$tmp" "$f"; then
    BN_SETUP_FILE=$f
    return 0
  fi
  [ -z "$tmp" ] || rm -f -- "$tmp"
  printf '%s: Battle.net installer download failed (%s); nothing was saved in %s\n' "$CMD" "$BN_SETUP_URL" "$d"
  return 1
}

# steam_walk TAG LAST: returns 0 when Steam steps 1 to LAST are done. Otherwise it shows the checklist and the click path of the first step not
# done, waits, and re-reads all of Steam's files (Steam writes shortcuts and config together); no retry cap, the user decides.
steam_walk() {
  local n page
  while :; do
    steam_steps "$1"
    for ((n = 1; n <= $2; n++)); do
      [ "${SS_DONE[n]}" = 1 ] || break
    done
    [ "$n" -le "$2" ] || return 0
    page=$(steam_checklist; steam_title "$n" "${SS_LABEL[n]}"; steam_click "$n" "$1")
    steam_show_page "$page" "Checked Steam's files again: step $n (${SS_LABEL[n]}) is not done yet."
    backend_read
    steam_hard_stop && return 1
    steam_save_prev_tool
  done
}

# steam_install_finish TAG (D-07): the closing report. Anything missing is listed (the run still ends 0); a complete install prints the
# completion line, the NAT offer, the firewall and NTP notes, the launch options row (only its warn shows: one paste, no re-install), the desktop
# entry (Phase 20 adds it, as the other backends write it) and the launch offer Phase 19 D-07 left out. The ask runs in a subshell so EOF is No;
# LOCK_HELD keeps install's run lock through cmd_launch, and a launch that stops or fails does not fail the finished install.
steam_install_finish() {
  local missing=()
  [ "$BN_RUNNER" = "$1" ] || missing+=("the shortcut's compatibility tool on $1")
  [ -n "$(wv2_find)" ] || missing+=('WebView2 runtime')
  registry_satisfied || missing+=('registry settings')
  [ -f "$W3C_EXE" ] || missing+=('W3Champions launcher')
  if [ "${#missing[@]}" -gt 0 ]; then
    list_text 'Not done yet (rerun install when ready):' "${missing[@]}"
    printf '%s' "$LIST"
    return 0
  fi
  steam_walk "$1" 6 || return 1
  printf 'Install complete: the Steam shortcut runs on %s and W3Champions %s is in its prefix.\n' "$1" "$L_CUR"
  nat_step
  fw_ntp_info
  steam_opts_row
  desktop_entry_install
  ( ask 'Launch now? Steam starts the shortcut' Y ) || { printf 'Next: press Play on the shortcut in Steam.\n'; return 0; }
  cleanup_staging
  cmd_launch || say 'The install is complete; run %s launch when you are ready.\n' "$BIN_NAME"
}

# cmd_install_steam: install under the Steam backend, in the order of cmd_install: the host and Steam checks, the patched Proton, the Steam steps
# that come before provisioning, then every question, the downloads, one idle wait and the in-prefix steps. No runner switch, no games.json.
cmd_install_steam() {
  local tag recorded want_wv2=0 want_reg=0 want_msi=0 exe v
  # shellcheck disable=SC2034 # QUIET_PASS is read by emit in lib/common.sh
  QUIET_PASS=1
  backend_read
  steam_hard_stop && return 1
  check_host
  if [ "$FAILS" -gt 0 ]; then
    printf 'install: fix the failed checks above, then rerun (%s doctor shows every check)\n' "$BIN_NAME"
    return 1
  fi
  acquire_lock
  steam_save_prev_tool
  trap cleanup_staging EXIT
  recorded=$(read_proton_tag)
  if [ -n "$recorded" ] && build_complete "$COMPAT/$recorded"; then
    # the recorded build wins; the API only feeds the newer-tag notice and may be down
    tag=$recorded
    if resolve_release; then
      [ "$RT_TAG" = "$tag" ] || printf 'newer tag %s available: run %s update\n' "$RT_TAG" "$BIN_NAME"
    else
      emit warn 'w3c build' "could not check for a newer build ($RT_ERR); using the recorded $tag"
    fi
  else
    if ! resolve_release; then
      printf 'install: cannot resolve the latest patched Proton release (%s); nothing was changed\n' "$RT_ERR"
      return 1
    fi
    tag=$RT_TAG
    if ! build_complete "$COMPAT/$tag"; then
      if ! ask "Download $tag (about $RT_SIZE) into $COMPAT?" Y; then
        printf 'Nothing was changed; rerun install when ready.\n'
        return 0
      fi
      fetch_verify_extract || return 1
    fi
    write_proton_tag "$tag" || { printf 'install: cannot record the build in %s; rerun install\n' "$PROTON_TAG_FILE"; return 1; }
  fi
  [ -n "$ST_APPID" ] || steam_fetch_setup || return 1
  steam_walk "$tag" 5 || return 1
  check_derived
  launcher_status 30
  if [ "$L_EXE" = 0 ] && [ -z "$L_LATEST" ]; then
    printf 'install: cannot read the latest W3Champions version (%s); the launcher step needs it, rerun install when online\n' "$L_ERR"
    return 1
  fi
  sync_launcher_record || return 1
  # every outstanding question first, so the user can walk away once the installers run
  exe=$(wv2_find)
  if [ -z "$exe" ]; then
    ask 'Install Microsoft Edge WebView2 runtime into the prefix?' Y && want_wv2=1
  else
    v=$(wv2_version "$exe")
    printf 'WebView2 runtime %s already in the prefix\n' "${v:-unknown}"
    wv2_report "$v"
  fi
  if ! registry_satisfied && ask "Apply registry tweaks (msedgewebview2.exe -> $(reg_target_winver), prefix -> win10, Allow Local Files)?" Y; then
    want_reg=1
  fi
  case $L_NEED in
    install) ask "Install W3Champions $L_LATEST (latest)?" Y && want_msi=1 ;;
    update) ask "Update W3Champions $L_CUR -> $L_LATEST?" Y && want_msi=1 ;;
    *) [ "$L_EXE" = 0 ] || [ -n "$L_LATEST" ] || emit warn launcher "could not check for a newer launcher ($L_ERR); W3Champions $L_CUR stays" ;;
  esac
  if [ "$want_wv2$want_reg$want_msi" = 000 ]; then
    steam_install_finish "$tag"
    return
  fi
  # installers are downloaded before the wait, while the shortcut may still run
  case $CACHE_DIR in "$HOME"/*) ;; *) emit warn cache "$CACHE_DIR is outside $HOME; Wine's container may not see installers there (set XDG_CACHE_HOME under $HOME)" ;; esac
  if [ "$want_wv2" = 1 ]; then fetch_webview2 || return 1; fi
  if [ "$want_msi" = 1 ]; then fetch_launcher_msi || return 1; fi
  wait_idle
  # a failed step stops install; the rerun skips finished steps
  if [ "$want_wv2" = 1 ]; then step_webview2 || return 1; fi
  if [ "$want_reg" = 1 ]; then step_registry || return 1; fi
  if [ "$want_msi" = 1 ]; then step_launcher || return 1; fi
  steam_install_finish "$tag"
}

# steam_wait_select NAME (D-11, D-03): the select step alone, waited on until CompatToolMapping names NAME. Quitting exits 1 inside steam_wait,
# so nothing is recorded; a hard stop met while waiting returns 1.
steam_wait_select() {
  local page
  while [ "$BN_RUNNER" != "$1" ]; do
    SS_LABEL=('' "Select $1 as its compatibility tool") SS_DONE=('' 0)
    page=$(steam_checklist; steam_title 1 "${SS_LABEL[1]}"; steam_click 2 "$1")
    steam_show_page "$page" "Checked Steam's files again: the shortcut's compatibility tool is not $1 yet."
    backend_read
    steam_hard_stop && return 1
    [ -n "$ST_APPID" ] || { printf '%s: the Battle.net shortcut is gone from Steam; stopping\n' "$CMD"; return 1; }   # not a tool change: keep the records
  done
  return 0
}

# steam_wc3_read: sets WC3_BUILD, WC3_BRANCH, WC3_CURRENT and WC3_STATE for the Steam prefix (the list read with wc3_status's update caps).
steam_wc3_read() {
  local d
  d=$(wc3_install_dir)
  [ -d "$d" ] || d=$PREFIX/drive_c/Program\ Files\ \(x86\)/Warcraft\ III   # the default path, as check_wc3 has it
  wc3_buildinfo "$d"
  wc3_status 3 5
}

# The Warcraft III walk (D-14 B): the patch by hand, three steps: the shortcut to Battle.net.exe, Play (Battle.net patches the game), the shortcut
# back to W3Champions.exe. Every Steam change is the user's, from the printed click path; this writes no Steam file. Each Enter re-reads Steam's files,
# the build and the list, so the walk ends as soon as the build is current; the last build and list answer read are kept when one cannot be read.
# q or EOF exit 1 inside steam_wait, and nothing is recorded, so a rerun starts clean. Returns 1 on a hard stop, the shortcut gone, or a doctor fail row.
steam_wc3_walk() {
  local bld=$WC3_BUILD cur=$WC3_CURRENT exe page old step line
  while :; do
    steam_wc3_read
    [ -n "$WC3_BUILD" ] || WC3_BUILD=$bld
    [ -n "$WC3_CURRENT" ] || WC3_CURRENT=$cur
    bld=$WC3_BUILD cur=$WC3_CURRENT
    exe=${ST_EXE,,} old=0
    ! version_lt "$WC3_BUILD" "$WC3_CURRENT" || old=1
    SS_LABEL=('' 'Point the shortcut at Battle.net.exe' "Press Play: Battle.net updates Warcraft III to $WC3_CURRENT, then quit Battle.net"
      'Point the shortcut back at W3Champions.exe')
    SS_DONE=(0 0 0 0)
    if [ "$exe" = battle.net.exe ] || [ "$old" = 0 ]; then SS_DONE[1]=1; fi
    [ "$old" = 1 ] || SS_DONE[2]=1
    if [ "$old" = 0 ] && [ "$exe" = w3champions.exe ]; then SS_DONE[3]=1; fi
    [ "${SS_DONE[3]}" != 1 ] || break
    if [ "${SS_DONE[1]}" != 1 ]; then step=1; elif [ "${SS_DONE[2]}" != 1 ]; then step=2; else step=3; fi
    page=$(
      steam_checklist
      steam_title "$step" "${SS_LABEL[step]}"
      case $step in
        1) steam_click 4 ;;
        2)
          printf '    Press Play on the shortcut, sign in to Battle.net and let it update Warcraft III (installed %s, current %s).\n' "$WC3_BUILD" "$WC3_CURRENT"
          printf '    Then quit Battle.net (its menu > Exit).\n' ;;
        3) steam_click 6 ;;
      esac
    )
    line="Checked Steam's files again: step $step (${SS_LABEL[step]}) is not done yet."
    if [ "$step" = 2 ]; then line="Checked Warcraft III again: still $WC3_BUILD, waiting for Battle.net to finish the update to $WC3_CURRENT."; fi
    steam_show_page "$page" "$line"
    backend_read
    steam_hard_stop && return 1
    [ -n "$ST_APPID" ] || { printf '%s: the Battle.net shortcut is gone from Steam; stopping\n' "$CMD"; return 1; }
  done
  printf 'Warcraft III %s is current; checking with doctor (warn and fail rows only):\n' "$WC3_BUILD"
  cmd_doctor || { printf 'update: doctor shows a failed row above; fix it, then run %s doctor\n' "$BIN_NAME"; return 1; }
}

# cmd_update_steam: update under the Steam backend. The launcher is upgraded on the tool CompatToolMapping names; a newer patched Proton is
# downloaded into its own directory, then the user selects it in Steam (one wait) and only then is it recorded (D-11). When the shortcut runs on
# a tool the user chose, update warns once and edits nothing (D-13); build names are compared as exact, case-sensitive strings.
cmd_update_steam() {
  local recorded mapped warn=0 want_proton=0 want_msi=0 want_rm=0 want_wc3=0 offered=0 offer_proton=0
  # shellcheck disable=SC2034 # CMD is read by fetch_verify_extract in lib/proton.sh
  CMD=update
  # shellcheck disable=SC2034 # QUIET_PASS is read by emit in lib/common.sh
  QUIET_PASS=1
  backend_read
  steam_hard_stop && return 1
  if [ -z "$ST_APPID" ] || [ -z "$PREFIX" ]; then
    printf 'update: no Battle.net shortcut with a prefix in Steam yet: run %s install\n' "$BIN_NAME"
    return 1
  fi
  check_host
  if [ "$FAILS" -gt 0 ]; then
    printf 'update: fix the failed checks above, then rerun (%s doctor shows every check)\n' "$BIN_NAME"
    return 1
  fi
  check_derived
  acquire_lock
  trap cleanup_staging EXIT
  recorded=$(read_proton_tag)
  mapped=$BN_RUNNER
  if [ -z "$recorded" ] || ! build_complete "$COMPAT/$recorded"; then
    printf 'patched Proton: no complete W3C build recorded; run %s install\n' "$BIN_NAME"
  elif ! resolve_release; then
    emit warn 'w3c build' "could not check for a newer build ($RT_ERR)"
  elif [ "$RT_TAG" = "$recorded" ]; then
    printf 'patched Proton %s up to date\n' "$recorded"
  else
    offer_proton=1
  fi
  # D-13: one row when the shortcut is not on the recorded W3C build, except the one state update itself leaves behind (the new complete build selected)
  if ! is_w3c_runner "$mapped"; then
    warn=1
  elif [ -n "$recorded" ] && [ "$mapped" != "$recorded" ]; then
    warn=1
    if [ "$offer_proton" = 1 ] && [ "$mapped" = "$RT_TAG" ] && build_complete "$COMPAT/$RT_TAG"; then warn=0; fi
  fi
  if [ "$warn" = 1 ]; then
    emit warn runner "CompatToolMapping for appid $ST_APPID names ${mapped:-no tool}, not the W3C build ${recorded:-(none recorded)}: update changes nothing in Steam; $BIN_NAME install walks you back to the W3C build"
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
  # D-14 B: Warcraft III against Blizzard's list; nothing is printed when the build or the list cannot be read
  steam_wc3_read
  case $WC3_STATE in
    outdated) printf 'Warcraft III %s is outdated (current %s)\n' "$WC3_BUILD" "$WC3_CURRENT" ;;
    current) printf 'Warcraft III %s up to date\n' "$WC3_BUILD" ;;
  esac
  watch_upstream "$recorded"
  # every question first, so the user can walk away once the downloads are done
  if [ "$offer_proton" = 1 ]; then
    offered=1
    if [ "$mapped" = "$RT_TAG" ] && build_complete "$COMPAT/$RT_TAG"; then
      want_proton=1   # the shortcut already uses it; only the records are missing
    elif build_complete "$COMPAT/$RT_TAG"; then
      ask "Use $RT_TAG for the Steam shortcut? You select it in Steam after a restart; $recorded stays installed." Y && want_proton=1
    else
      ask "Install $RT_TAG (about $RT_SIZE) and use it for the Steam shortcut? You select it in Steam after a restart; $recorded stays installed." Y && want_proton=1
    fi
  fi
  if [ "$L_NEED" = update ]; then
    if is_w3c_runner "$mapped"; then   # D-11: the MSI runs on the mapped tool
      offered=1
      ask "Update W3Champions $L_CUR -> $L_LATEST?" Y && want_msi=1
    else
      printf 'launcher update needs Battle.net on a W3C build: run %s install\n' "$BIN_NAME"
    fi
  fi
  if [ "$WC3_STATE" = outdated ]; then
    offered=1
    ask 'Walk through the Warcraft III update in Battle.net now? You point the shortcut at Battle.net.exe, press Play, then point it back.' Y && want_wc3=1
  fi
  if [ "$offer_proton" = 0 ] && prev_removal_due; then   # D-12: never in a run that offers a new build
    offered=1
    if ask_prev_removal; then want_rm=1; fi
  fi
  if [ "$want_proton$want_msi$want_rm$want_wc3" = 0000 ]; then
    [ "$offered" = 0 ] || printf 'Nothing was changed.\n'
    return 0
  fi
  # downloads before any wait, while Steam or Battle.net may still run
  if [ "$want_proton" = 1 ] && ! build_complete "$COMPAT/$RT_TAG"; then fetch_verify_extract || return 1; fi
  if [ "$want_msi" = 1 ]; then
    case $CACHE_DIR in "$HOME"/*) ;; *) emit warn cache "$CACHE_DIR is outside $HOME; Wine's container may not see installers there (set XDG_CACHE_HOME under $HOME)" ;; esac
    fetch_launcher_msi || return 1
  fi
  if [ "$want_proton" = 1 ]; then
    # a user on a non-W3C tool chose it: no wait, the records only (D-13)
    if is_w3c_runner "$mapped"; then steam_wait_select "$RT_TAG" || return 1; fi
    if ! write_state "$PROTON_PREV_FILE" "$recorded"; then
      printf 'update: cannot record %s; rerun update\n' "$PROTON_PREV_FILE"
      return 1
    fi
    if ! write_proton_tag "$RT_TAG"; then
      printf 'update: cannot record %s; rerun update\n' "$PROTON_TAG_FILE"
      return 1
    fi
    if [ "$BN_RUNNER" = "$RT_TAG" ]; then
      printf 'Recorded %s; the previous W3C build %s stays installed (%s revert switches back to it)\n' "$RT_TAG" "$recorded" "$BIN_NAME"
    else
      printf 'Recorded %s; the shortcut runs on %s: %s install walks you to %s\n' "$RT_TAG" "${BN_RUNNER:-no tool}" "$BIN_NAME" "$RT_TAG"
    fi
  fi
  if [ "$want_msi$want_rm" != 00 ]; then wait_idle; fi
  if [ "$want_rm" = 1 ]; then remove_prev || return 1; fi
  if [ "$want_msi" = 1 ]; then
    # run_in_prefix reads CompatToolMapping now, so msiexec runs on the new build after the select step
    step_launcher || return 1
  fi
  if [ "$want_wc3" = 1 ]; then steam_wc3_walk || return 1; fi
  printf 'Update finished.\n'
}

# steam_read_prev_tool (D-08): prints the tool name install saved in STEAM_PREV_TOOL_FILE (first line, control characters shown as ?), nothing when
# there is none. It is only ever printed, never used as a path: it may hold spaces.
steam_read_prev_tool() {
  local v=''
  if [ -r "$STEAM_PREV_TOOL_FILE" ]; then IFS= read -r v < "$STEAM_PREV_TOOL_FILE" || true; fi
  printf '%s' "${v//[[:cntrl:]]/?}"
  return 0
}

# steam_wait_away LEFT TARGET KIND (D-10): waits until CompatToolMapping no longer names LEFT, showing the select step for TARGET; for KIND full it
# also shows the retarget back to Battle.net.exe (D-09: W3Champions.exe fails VerifyJob on a stock Proton). Returns 0 once the mapping names
# anything else, no tool included (Steam owns the choice); a hard stop met while waiting returns 1, q or EOF exit 1 inside steam_wait.
steam_wait_away() {
  local page
  while [ "$BN_RUNNER" = "$1" ]; do
    SS_LABEL=('' "Select $2 as its compatibility tool") SS_DONE=('' 0)
    if [ "$3" = full ]; then
      SS_LABEL+=('Point the shortcut back at Battle.net.exe') SS_DONE+=(0)
      [ "${ST_EXE,,}" != battle.net.exe ] || SS_DONE[2]=1
    fi
    page=$(
      steam_checklist
      steam_title 1 "${SS_LABEL[1]}"
      steam_click 2 "$2"
      if [ "$3" = full ] && [ "${SS_DONE[2]}" != 1 ] && [ -n "$PREFIX" ]; then
        steam_title 2 "${SS_LABEL[2]}"
        steam_click 4
      fi
    )
    steam_show_page "$page" "Checked Steam's files again: the shortcut still runs on $1."
    backend_read
    steam_hard_stop && return 1
    [ -n "$ST_APPID" ] || { printf '%s: the Battle.net shortcut is gone from Steam; stopping\n' "$CMD"; return 1; }   # not a tool change: keep the records
  done
  return 0
}

# cmd_revert_steam: revert under the Steam backend. It prints the click path back (one W3C build back, or to the tool the shortcut used before
# w3c-linux plus the retarget to Battle.net.exe), waits until Steam's mapping has moved, records nothing before that, and only then offers to
# remove the build it left (D-08, D-09, D-10, D-18). The launcher, WebView2 and registry stay in the prefix; the download directory is untouched.
cmd_revert_steam() {
  local tag left prev target kind now
  # shellcheck disable=SC2034 # CMD is read by steam_wait in this file
  CMD=revert
  # shellcheck disable=SC2034 # QUIET_PASS is read by emit in lib/common.sh
  QUIET_PASS=1
  backend_read
  steam_hard_stop && return 1
  if [ -z "$ST_APPID" ]; then
    printf 'revert: no Battle.net shortcut in Steam; nothing to revert\n'
    return 1
  fi
  tag=$(read_proton_tag)
  left=$BN_RUNNER
  if ! is_w3c_runner "$left"; then   # D-18: no wait; the retarget is still shown, the recorded build is offered when unused
    printf 'revert: the shortcut already runs on %s, not a W3C build\n' "${left:-no compatibility tool}"
    if [ -n "$PREFIX" ] && [ "${ST_EXE,,}" != battle.net.exe ]; then
      printf 'Point the shortcut back at Battle.net.exe (W3Champions.exe fails on a stock Proton):\n'
      steam_click 4
    fi
    acquire_lock
    nat_revert_note
    offer_remove "$tag" install
    return
  fi
  prev=$(read_proton_prev)
  if [ -n "$prev" ] && [ "$prev" != "$left" ] && build_complete "$COMPAT/$prev"; then
    target=$prev kind=step
  else
    target=$(steam_read_prev_tool)
    [ -n "$target" ] || target='a Proton of your choice, e.g. Proton Experimental'
    kind=full
  fi
  acquire_lock
  steam_wait_away "$left" "$target" "$kind" || return 1
  now=${BN_RUNNER:-no compatibility tool}
  if [ "$kind" = step ] && [ "$BN_RUNNER" = "$prev" ]; then
    write_proton_tag "$prev" || { printf 'revert: cannot record the build in %s\n' "$PROTON_TAG_FILE"; return 1; }
    rm -f -- "$PROTON_PREV_FILE"
    printf 'The shortcut runs on %s again; %s stays installed.\n' "$prev" "$left"
  else
    # the saved tool is dropped only once the mapping left the W3C builds; a move to another W3C build keeps it for the next revert
    if [ "$kind" = full ] && ! is_w3c_runner "$BN_RUNNER"; then rm -f -- "$STEAM_PREV_TOOL_FILE"; fi
    printf 'The shortcut now runs on %s.\n' "$now"
  fi
  if [ "$kind" = step ]; then
    offer_remove "$left" update
  else
    nat_revert_note
    offer_remove "$left" install
  fi
}
