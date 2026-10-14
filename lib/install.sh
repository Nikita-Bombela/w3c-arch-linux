# shellcheck shell=bash
# The install subcommand and its install-only steps.

# nat_step: install prompt 8.
nat_step() {
  if nat_marker_ok; then
    say 'LAN-test NAT rule: applied this boot (by w3c-linux); if you removed it since, delete %s and rerun install.\n' "$NAT_MARK"
    return 0
  fi
  nat_offer
}

# fw_ntp_info: install prompt 9. Read-only and unprivileged: one `systemctl is-active --quiet` per unit (a multi-unit call exits 0 when
# any one is active) and `timedatectl show -p NTP --value`. Fixed text only; a missing tool or empty output means "cannot tell" and prints nothing.
# Always returns 0.
fw_ntp_info() {
  local u active=() ntp
  if type -P systemctl > /dev/null; then
    for u in nftables iptables ufw firewalld; do
      systemctl is-active --quiet "$u" 2> /dev/null && active+=("$u")
    done
  fi
  if [ "${#active[@]}" -gt 0 ]; then
    say 'A firewall is active (%s): allow TCP 3550 3551 3552 | UDP 3552 5353 | mDNS multicast 224.0.0.251 UDP 5353\n' "${active[*]}"
    say 'flo also uses QUIC (UDP) to service.w3flo.com:3550 and stats.w3flo.com:3557 (INFERRED from the launcher binary)\n'
  fi
  if type -P timedatectl > /dev/null; then
    ntp=$(timedatectl show -p NTP --value 2> /dev/null) || ntp=''
    if [ -n "$ntp" ] && [ "$ntp" != yes ]; then
      say 'NTP is off and the launcher checks clock skew: run sudo timedatectl set-ntp true\n'
    fi
  fi
  return 0
}

# install_summary TAG: the closing report. Lists what is still missing (returns 1), else the completion line (returns 0).
install_summary() {
  local missing=()
  runner_is_tag "$1" || missing+=("Battle.net runner on $1")
  [ -n "$(wv2_find)" ] || missing+=('WebView2 runtime')
  registry_satisfied || missing+=('registry settings')
  [ -f "$W3C_EXE" ] || missing+=('W3Champions launcher')
  if [ "${#missing[@]}" -gt 0 ]; then
    list_text 'Not done yet (rerun install when ready):' "${missing[@]}"
    printf '%s' "$LIST"
    return 1
  fi
  printf 'Install complete: Battle.net runs on %s and W3Champions %s is in its prefix. Next: %s launch.\n' "$1" "$L_CUR" "$BIN_NAME"
}

# desktop_entry_system SYS: the installer owns the menu entry (SYS: the package, make install or make install-user), so no per-user .desktop or icon
# is written (D-09) and the install's own entry is never removed (Phase 11 D-01). A per-user entry that desk_ours accepts (the clone path wrote it)
# is removed, since it would hide the installer's (Phase 7 D-10, Phase 9 D-01); any other file of that name, a symlink included, is the user's and
# stays. Never asks, never fails.
desktop_entry_system() {
  local sys=$1
  if ! desk_is_own && desk_ours "$DESK_FILE"; then
    rm -f -- "$DESK_FILE"
    printf 'Desktop entry: removed the per-user entry; the system entry is used\n'
  fi
  if [ "$INSTALL_KIND" = user ]; then
    printf 'Desktop entry: the entry make install-user wrote is used (%s)\n' "$sys"
  else
    printf 'Desktop entry: the system entry is used (%s)\n' "$sys"
  fi
}

# desktop_entry_install: the menu entry and icon of a complete install. It never asks and never fails the install: a problem is one warn line.
# With the install's own entry (OWN_DESK) it only calls desktop_entry_system; the rest is the clone (Phase 6) path. An installed copy whose own
# entry is missing lands in the clone path too, finds no share/ next to the script and writes nothing but one warn row.
# The entry is the shipped file with only its Exec line replaced; both files are written through a temp file and mv, and left alone when equal.
# ponytail: the installed files keep mktemp's 0600 mode like every other file this script writes; 0644 only if another user must read them.
desktop_entry_install() {
  local src=$SHARE_DIR/w3c-linux.desktop png=$SHARE_DIR/w3c-linux.png adir=${DESK_FILE%/*} idir=${DESK_ICON%/*} te='' ti='' line f
  [ -f "$OWN_DESK" ] && { desktop_entry_system "$OWN_DESK"; return 0; }
  for f in "$src" "$png"; do
    [ -f "$f" ] || { emit warn 'desktop entry' "$f is missing; no menu entry written"; return 0; }
  done
  {
    mkdir -p "$adir" "$idir" \
      && te=$(mktemp "$adir/.w3c-linux.desktop.XXXXXX") && ti=$(mktemp "$idir/.w3c-linux.png.XXXXXX") \
      && while IFS= read -r line || [ -n "$line" ]; do
        case $line in
          Exec=*) printf 'Exec=%s launch\n' "$(desk_quote "$SELF")" ;;
          *) printf '%s\n' "$line" ;;
        esac
      done < "$src" > "$te" \
      && cp -- "$png" "$ti"
  } || {
    rm -f -- "$te" "$ti"
    emit warn 'desktop entry' "could not write $DESK_FILE"
    return 0
  }
  if cmp -s "$te" "$DESK_FILE" && cmp -s "$ti" "$DESK_ICON"; then
    rm -f -- "$te" "$ti"
    printf 'Desktop entry: already installed (%s)\n' "$DESK_FILE"
    return 0
  fi
  if ! { mv -f -- "$te" "$DESK_FILE" && mv -f -- "$ti" "$DESK_ICON"; }; then
    rm -f -- "$te" "$ti"
    emit warn 'desktop entry' "could not write $DESK_FILE"
    return 0
  fi
  # only rebuilds the MIME cache, harmless for an entry without MimeType; its status and output do not matter
  if type -P update-desktop-database > /dev/null; then update-desktop-database -q "$adir" > /dev/null 2>&1 || true; fi
  printf 'Desktop entry: installed %s (icon %s)\n' "$DESK_FILE" "$DESK_ICON"
}

# install_finish TAG: the summary, the desktop entry, then prompt 10 for a complete install. The ask runs in a subshell so EOF counts as No (exit 0, nothing
# started unasked). LOCK_HELD makes cmd_launch's acquire_lock keep install's fd 9, so the run lock is never free in between. The install is
# done by then, so a launch that stops or fails does not fail it.
install_finish() {
  install_summary "$1" || return 0
  nat_step
  fw_ntp_info
  desktop_entry_install
  if [ "$BACKEND" = umu ]; then
    ( ask 'Launch now? Battle.net starts first through umu-run; sign in when it appears' Y ) || return 0
  else
    ( ask 'Launch now? Battle.net starts first via Faugus; sign in when it appears' Y ) || return 0
  fi
  cleanup_staging
  cmd_launch || say 'The install is complete; run %s launch when you are ready.\n' "$BIN_NAME"
}

# install: prompt 1, resolve, prompt 3 (download), then the batch of questions, downloads, one idle wait, the switch and the chosen steps.
cmd_install() {
  local tag recorded found='Found Faugus Battle.net:' want_switch=0 want_wv2=0 want_reg=0 want_msi=0 want_rm=0 exe v
  case ${W3C_WEBVIEW_WINVER:-} in
    '' | win7 | win8) ;;
    *)
      printf 'install: W3C_WEBVIEW_WINVER must be win7 or win8, for example: W3C_WEBVIEW_WINVER=win8 %s install\n' "$BIN_NAME" >&2
      return 2 ;;
  esac
  QUIET_PASS=1
  run_checks
  if [ "$FAILS" -gt 0 ]; then
    printf 'install: fix the failed checks above, then rerun (%s doctor shows every check)\n' "$BIN_NAME"
    return 1
  fi
  # UMU-04, D-12: the umu backend names its source in one line and never mentions Faugus's games.json
  if [ "$BACKEND" = umu ]; then
    printf '%s\n' "$(umu_note)"
    found='Found Battle.net (umu backend):'
  fi
  list_text "$found" "prefix $PREFIX" "runner $BN_RUNNER" "Warcraft III ${WC3_BUILD:-unknown}" 'Battle.net present'
  if ! ask "${LIST}Continue?" Y; then
    printf 'Declined; nothing was changed.\n'
    return 0
  fi
  acquire_lock
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
  launcher_status 30
  if [ "$L_EXE" = 0 ] && [ -z "$L_LATEST" ]; then
    printf 'install: cannot read the latest W3Champions version (%s); the launcher step needs it, rerun install when online\n' "$L_ERR"
    return 1
  fi
  sync_launcher_record || return 1
  # every outstanding question first, so the user can walk away once the installers run
  # D-12, D-13: the umu backend has no games.json to switch; the tag goes into the backend file (file origin) or is printed as the
  # W3C_PROTON line to set (env origin), and the run stops: the in-prefix steps refuse on a runner that is not the W3C build
  if [ "$BACKEND" = umu ] && ! runner_is_tag "$tag"; then
    # a saved runner is the user's choice (it may be another Proton), so changing it is asked like the Faugus switch is
    if [ "$BACKEND_SRC" = file ] && ! ask "Use $tag as the umu backend's runner (now $BN_RUNNER)? It is saved in $BACKEND_FILE." Y; then
      printf 'Runner not changed; rerun install when ready.\n'
      return 0
    fi
    umu_save_runner "$tag" install || { [ $? = 2 ] && return 1; return 0; }
    printf 'Rerun %s install to set up the prefix on %s.\n' "$BIN_NAME" "$tag"
    return 0
  fi
  if runner_is_tag "$tag"; then
    # shellcheck disable=SC2034 # QUIET_PASS is read by emit in lib/common.sh
    QUIET_PASS=0   # already switched, so no backup and no switch
    emit pass runner "already $tag"
  else
    if ! ask "Switch Faugus's Battle.net runner to $tag? Required: the game must run on the patched build. Revert later with $BIN_NAME revert." Y; then
      printf 'Battle.net runner not switched; rerun install when ready.\n'
      printf 'The prefix steps (WebView2, registry, launcher) run only on the W3C build (PFX-01), so they were not offered.\n'
      return 0
    fi
    want_switch=1
  fi
  exe=$(wv2_find)
  if [ -z "$exe" ]; then
    ask 'Install Microsoft Edge WebView2 runtime into the prefix?' Y && want_wv2=1   # plan.md section 8, prompt 5
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
  # only without a switch in this run (prev_removal_due needs the runner already on the recorded build)
  if prev_removal_due && ask_prev_removal; then want_rm=1; fi
  if [ "$want_switch$want_wv2$want_reg$want_msi$want_rm" = 00000 ]; then
    install_finish "$tag"
    return
  fi
  # installers are downloaded before the wait, while Faugus or Battle.net may still run
  if [ "$want_wv2$want_reg$want_msi" != 000 ]; then
    case $CACHE_DIR in "$HOME"/*) ;; *) emit warn cache "$CACHE_DIR is outside $HOME; Wine's container may not see installers there (set XDG_CACHE_HOME under $HOME)" ;; esac
  fi
  if [ "$want_wv2" = 1 ]; then fetch_webview2 || return 1; fi
  if [ "$want_msi" = 1 ]; then fetch_launcher_msi || return 1; fi
  wait_idle
  if [ "$want_rm" = 1 ]; then remove_prev || return 1; fi
  if [ "$want_switch" = 1 ]; then
    if ! idle_check; then
      print_busy
      printf 'install: something started again (listed above); games.json was not changed, rerun install\n'
      return 1
    fi
    switch_runner "$tag" || return 1
    BN_RUNNER=$tag
  fi
  # a failed step stops install; the rerun skips finished steps
  if [ "$want_wv2" = 1 ]; then step_webview2 || return 1; fi
  if [ "$want_reg" = 1 ]; then step_registry || return 1; fi
  if [ "$want_msi" = 1 ]; then step_launcher || return 1; fi
  install_finish "$tag"
}
