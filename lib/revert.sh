# shellcheck shell=bash
# The revert subcommand.

# offer_remove NAME REDO: after a switch away from build NAME, offers (default No) to delete it when no games.json entry uses it.
# REDO (install or update) names the command that gets back to it. Only the record that names NAME is removed with it.
offer_remove() {
  local name=$1 gone=''
  [ -n "$name" ] && [ -e "$COMPAT/$name" ] || return 0
  faugus_uses_runner "$name" && return 0
  if ! ask "Remove $name from $COMPAT (about 1.5 GB)? w3c-linux.sh $2 downloads it again." N; then
    case $2 in
      install) printf 'Kept %s: w3c-linux.sh install switches back without downloading.\n' "$name" ;;
      *) printf 'Kept %s: w3c-linux.sh update switches to it without downloading.\n' "$name" ;;
    esac
    return 0
  fi
  if ! idle_check; then
    print_busy
    printf 'revert: something started again (listed above); %s was not removed\n' "$name"
    return 1
  fi
  if ! remove_compat_entry "$name"; then
    printf 'revert: could not remove %s/%s\n' "$COMPAT" "$name"
    return 1
  fi
  if [ "$(read_proton_tag)" = "$name" ]; then rm -f -- "$PROTON_TAG_FILE"; gone=' and the recorded build'; fi
  if [ "$(read_proton_prev)" = "$name" ]; then rm -f -- "$PROTON_PREV_FILE"; fi
  printf 'Removed %s/%s%s.\n' "$COMPAT" "$name" "$gone"
}

# desktop_entry_remove: deletes the menu entry and icon install wrote, nothing else. Only the restore to a non-W3C runner calls it, since
# launch needs the W3C build. No update-desktop-database here: that would write the MIME cache, and nothing else is removed.
desktop_entry_remove() {
  [ -e "$DESK_FILE" ] || [ -e "$DESK_ICON" ] || return 0
  rm -f -- "$DESK_FILE" "$DESK_ICON"
  printf 'Removed the desktop entry %s and its icon.\n' "$DESK_FILE"
}

# revert: with a complete previous W3C build recorded it steps back to that build first; otherwise it restores the
# battlenet runner from the newest backup that is not on a W3C build. Same idle and backup rules, then the delete offer.
# Backups are never pruned.
cmd_revert() {
  local tag picked prev left
  # shellcheck disable=SC2034 # QUIET_PASS is read by emit in lib/common.sh
  QUIET_PASS=1
  faugus_backend
  faugus_rows_entry
  check_derived
  if [ -n "$NEED_ENTRY" ]; then
    printf "revert: Faugus's games.json or its Battle.net entry cannot be read; run w3c-linux.sh doctor\n"
    return 1
  fi
  tag=$(read_proton_tag)
  if ! is_w3c_runner "$BN_RUNNER"; then   # never replace a runner the user chose with an old backup
    printf 'revert: Battle.net runs on %s, not a W3C build; nothing to revert (w3c-linux.sh install switches it to the W3C build)\n' "$(runner_label "$BN_RUNNER")"
    return 1
  fi
  prev=$(read_proton_prev)
  if [ -n "$prev" ] && [ "$prev" != "$BN_RUNNER" ] && build_complete "$COMPAT/$prev"; then   # step back one W3C build
    acquire_lock
    wait_idle
    if ! ask "Switch Battle.net back to the previous W3C build $prev? ($BN_RUNNER stays installed)" Y; then
      printf 'Nothing was changed.\n'   # no fall-through to the pre-W3C runner
      return 0
    fi
    left=$BN_RUNNER
    revert_write "$prev" || return 1
    write_proton_tag "$prev" || { printf 'revert: cannot record the build in %s\n' "$PROTON_TAG_FILE"; return 1; }
    rm -f -- "$PROTON_PREV_FILE"
    offer_remove "$left" update
    return
  fi
  if ! faugus_pick_backup "$tag"; then
    printf 'revert: no backup with a non-W3C Battle.net runner in %s; nothing to revert\n' "$W3C_STATE"
    return 1
  fi
  picked=${G[2]-}   # may be the empty string: Faugus's UMU-Proton Latest
  acquire_lock
  wait_idle
  if [ "$BN_RUNNER" = "$picked" ]; then
    printf 'Battle.net already runs on %s; runner unchanged.\n' "$(runner_label "$picked")"
  else
    if ! ask "Switch Battle.net's runner from $(runner_label "$BN_RUNNER") back to $(runner_label "$picked")? The W3Champions launcher fails VerifyJob on it." Y; then
      printf 'Nothing was changed.\n'
      return 0
    fi
    if ! faugus_managed "$picked" && [ ! -e "$COMPAT/$picked" ]; then
      emit warn runner "$picked is not in $COMPAT: Faugus will show \"$picked was not found\""
    fi
    revert_write "$picked" || return 1
  fi
  desktop_entry_remove
  offer_remove "$tag" install
}
