# shellcheck shell=bash
# W3C Proton build: download and verify, idle wait, replaced-build removal. Used by install, revert and update.

# py_release: releases/latest JSON on stdin, status-first NUL fields (trust boundary at the python edge).
#   ok, tag, tgz_name, tgz_url, size_text, sums_url   |   bad, reason
# stdin carries the JSON; the helper reads it from there.
py_release() {
  python3 -I -B "$HELPER" release 2> /dev/null
}

# resolve_release: sets RT_TAG RT_TGZ RT_URL RT_SIZE RT_SUMS, or RT_ERR and returns 1. One curl call.
resolve_release() {
  local json
  if ! json=$(curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 30 "$RELEASE_API" 2> /dev/null); then
    RT_ERR='GitHub API unreachable or rate-limited'
    return 1
  fi
  mapfile -d '' -t REL < <(printf '%s' "$json" | py_release)
  # shellcheck disable=SC2034 # RT_ERR and RT_SIZE are read by cmd_install in lib/install.sh
  case ${REL[0]:-pyfail} in
    ok)
      if [ "${#REL[@]}" -eq 6 ]; then
        RT_TAG=${REL[1]} RT_TGZ=${REL[2]} RT_URL=${REL[3]} RT_SIZE=${REL[4]} RT_SUMS=${REL[5]}
        return 0
      fi
      RT_ERR='release parser failed' ;;
    bad) RT_ERR=${REL[1]:-release parser failed} ;;
    *) RT_ERR='release parser failed' ;;
  esac
  return 1
}

# build_complete DIR: DIR holds proton, compatibilitytool.vdf, version and files/.
build_complete() {
  [ -f "$1/proton" ] && [ -f "$1/compatibilitytool.vdf" ] && [ -f "$1/version" ] && [ -d "$1/files" ]
}

# remove_compat_entry NAME: the only recursive delete in the script. NAME is a validated tag or one of our staging dirs.
remove_compat_entry() {
  [ -n "$COMPAT" ] || return 1
  safe_tag "$1" || [[ $1 =~ ^\.w3c-staging\.[A-Za-z0-9]+$ ]] || return 1
  rm -rf -- "${COMPAT:?}/$1"
}

# shellcheck disable=SC2329 # runs through the EXIT trap set in cmd_install
cleanup_staging() {
  [ -z "$STAGE" ] || remove_compat_entry "${STAGE##*/}"
}

# curl_get URL OUT: no resume option, so an interrupted download always restarts from zero.
curl_get() {
  local bar=-sS
  [ -t 2 ] && bar=--progress-bar
  curl -fL --proto '=https' --proto-redir '=https' --connect-timeout 10 --speed-limit 1024 --speed-time 60 "$bar" -o "$2" "$1"
}

# fetch_verify_extract: download RT_TGZ and SHA256SUMS, verify, extract into a staging dir, place compatibilitytools.d/<tag>.
fetch_verify_extract() {
  local dl=$CACHE_DIR/$RT_TAG bad='' sums rc trc ok=1 ents=() ent
  mkdir -p -- "$dl" || { printf '%s: cannot create %s; nothing was installed\n' "$CMD" "$dl"; return 1; }
  rm -f -- "$dl/$RT_TGZ" "$dl/SHA256SUMS"
  # leftovers of an interrupted run go before anything new is fetched
  mkdir -p -- "$COMPAT" || { printf '%s: cannot create %s; nothing was installed\n' "$CMD" "$COMPAT"; return 1; }
  for ent in "$COMPAT"/.w3c-staging.*; do
    if [ -e "$ent" ] || [ -L "$ent" ]; then remove_compat_entry "${ent##*/}" || true; fi
  done
  printf 'Downloading %s to %s\n' "$RT_TGZ" "$dl"
  curl_get "$RT_URL" "$dl/$RT_TGZ" || bad=$RT_URL
  [ -n "$bad" ] || curl_get "$RT_SUMS" "$dl/SHA256SUMS" || bad=$RT_SUMS
  if [ -n "$bad" ]; then
    rm -f -- "$dl/$RT_TGZ" "$dl/SHA256SUMS"
    printf '%s: download failed (%s); nothing was installed\n' "$CMD" "$bad"
    return 1
  fi
  sums=$(cd "$dl" && sha256sum -c --ignore-missing SHA256SUMS 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ] || ! grep -qxF -- "$RT_TGZ: OK" <<< "$sums"; then
    rm -f -- "$dl/$RT_TGZ" "$dl/SHA256SUMS"
    printf '%s: SHA256 mismatch for %s; the download was deleted and nothing was extracted\n' "$CMD" "$RT_TGZ"
    return 1
  fi
  printf 'Verified: %s: OK (sha256sum -c)\n' "$RT_TGZ"
  STAGE=$(mktemp -d "$COMPAT/.w3c-staging.XXXXXX") || { STAGE=''; printf '%s: cannot create a staging directory in %s; nothing was installed\n' "$CMD" "$COMPAT"; return 1; }
  tar -xzf "$dl/$RT_TGZ" -C "$STAGE" --no-same-owner
  trc=$?
  [ "$trc" -eq 0 ] || ok=0
  if [ "$ok" = 1 ]; then
    mapfile -t ents < <(find "$STAGE" -mindepth 1 -maxdepth 1 -printf '%f\n')
    if [ "${#ents[@]}" -ne 1 ] || [ "${ents[0]}" != "$RT_TAG" ] || [ ! -d "$STAGE/$RT_TAG" ] || [ -L "$STAGE/$RT_TAG" ] \
      || ! build_complete "$STAGE/$RT_TAG"; then
      ok=0
    fi
  fi
  if [ "$ok" = 0 ]; then
    remove_compat_entry "${STAGE##*/}" || true
    STAGE=''
    list_text "$CMD: $RT_TGZ did not unpack to a single $RT_TAG/ directory holding:" proton compatibilitytool.vdf version 'files/'
    printf '%snothing was installed (verified download kept in %s)\n' "$LIST" "$dl"
    return 1
  fi
  # An existing <tag> is incomplete (callers skip complete ones): replace it.
  if [ -e "$COMPAT/$RT_TAG" ] || [ -L "$COMPAT/$RT_TAG" ]; then
    remove_compat_entry "$RT_TAG" || { printf '%s: cannot replace %s/%s; nothing was installed\n' "$CMD" "$COMPAT" "$RT_TAG"; return 1; }
  fi
  if ! mv -T -- "$STAGE/$RT_TAG" "$COMPAT/$RT_TAG"; then
    printf '%s: could not move %s into %s; nothing was installed\n' "$CMD" "$RT_TAG" "$COMPAT"
    return 1
  fi
  rmdir -- "$STAGE" || true
  STAGE=''
  rm -f -- "$dl/$RT_TGZ" "$dl/SHA256SUMS"
  printf 'Installed %s into %s/%s\n' "$RT_TAG" "$COMPAT" "$RT_TAG"
}

# proc_match LABEL PGREP_ARGS...: pgrep status 0 names LABEL as busy, 1 is idle, anything else fails closed.
proc_match() {
  local label=$1 rc
  shift
  pgrep -u "$UID" "$@" > /dev/null
  rc=$?
  case $rc in
    0) BUSY+=("$label") ;;
    1) ;;
    *) BUSY+=("cannot check processes (pgrep exit $rc)") ;;
  esac
}

# prefix_server_names: the server dir names Wine gives this prefix, server-<st_dev hex>-<st_ino hex> (probe-verified).
prefix_server_names() {
  local d s
  [ -n "$PREFIX" ] || return 0
  for d in "$PREFIX" "$PREFIX/pfx"; do
    [ -d "$d" ] || continue
    s=$(stat -L -c '%d %i' "$d") || continue
    printf 'server-%x-%x\n' "${s% *}" "${s#* }"
  done
}

# wineserver_busy: 0 a wineserver of this prefix is alive, 1 none is, 2 pgrep cannot tell.
# Matches the basename of /proc/PID/cwd (the server dir under /tmp/.wine-UID/), not the prefix path.
wineserver_busy() {
  local names out rc pid cwd n
  mapfile -t names < <(prefix_server_names)
  [ "${#names[@]}" -gt 0 ] || return 1
  out=$(pgrep -u "$UID" -x wineserver)
  rc=$?
  case $rc in 0) ;; 1) return 1 ;; *) return 2 ;; esac
  while read -r pid; do
    [ -n "$pid" ] || continue
    cwd=$(readlink "$PROC_DIR/$pid/cwd" 2> /dev/null) || continue
    for n in "${names[@]}"; do
      [ "${cwd##*/}" = "$n" ] && return 0
    done
  done <<< "$out"
  return 1
}

# idle_check: fills BUSY with one human label per running item, prints nothing, returns 0 iff BUSY is empty.
# Frozen contract: the Phase 3 in-prefix steps and the Phase 4 launch preflight reuse it.
idle_check() {
  BUSY=()
  if ! type -P pgrep > /dev/null; then
    BUSY+=('cannot check processes: pgrep (procps-ng) is missing')
    return 1
  fi
  faugus_busy
  proc_match 'Battle.net' -f 'Battle\.net\.exe'
  wineserver_busy
  case $? in
    0) BUSY+=('a Wine process in the Battle.net prefix is still running (wineserver)') ;;
    2) BUSY+=('cannot check processes (pgrep failed for wineserver)') ;;
  esac
  [ "${#BUSY[@]}" -eq 0 ]
}

print_busy() {
  list_text 'Still running:' "${BUSY[@]}"
  printf '%s' "$LIST" >&2
}

# wait_idle: UX prompt 2. Names what still runs, waits, re-checks on Enter; no retry cap.
# q, EOF or a zenity No stop with exit 1 before anything is written. Never closes or signals a process.
wait_idle() {
  local ans
  while ! idle_check; do
    if ! type -P pgrep > /dev/null; then   # nothing the user can close fixes a missing tool
      print_busy
      stop_waiting
    fi
    if use_zenity; then
      list_text 'Still running:' "${BUSY[@]}"
      zenity --question --no-markup --title=w3c-linux \
        --text="${LIST}Close them, then choose Yes to check again (No stops)." 2> /dev/null || stop_waiting
    else
      print_busy
      printf 'Close them (nothing is closed for you), then press Enter to check again (q to quit): ' >&2
      ans=''
      if ! read -r ans && [ -z "$ans" ]; then
        printf 'no answer (stdin closed); run in a terminal\n' >&2
        exit 1
      fi
      [ "${ans,,}" = q ] && stop_waiting
    fi
  done
  return 0
}

stop_waiting() {
  printf 'Stopped while waiting; games.json and the prefix were not changed.\n'
  exit 1
}

# read_proton_prev: the W3C build the last update replaced, when the state file holds a safe tag, else nothing.
read_proton_prev() {
  local t=''
  [ -r "$PROTON_PREV_FILE" ] && { read -r t < "$PROTON_PREV_FILE" || true; }
  if safe_tag "$t"; then printf '%s' "$t"; fi
  return 0
}

# prev_removal_due: sets PREV_RM and returns 0 when the build update replaced is safe to offer for removal: Battle.net runs on the
# complete recorded build, the replaced build's directory exists and no games.json entry uses it (unreadable counts as used).
prev_removal_due() {
  local p cur
  PREV_RM=''
  p=$(read_proton_prev)
  cur=$(read_proton_tag)
  [ -n "$p" ] && [ -n "$cur" ] && [ "$p" != "$cur" ] && [ "$BN_RUNNER" = "$cur" ] && build_complete "$COMPAT/$cur" && [ -e "$COMPAT/$p" ] || return 1
  faugus_uses_runner "$p" && return 1
  PREV_RM=$p
}

# ask_prev_removal: the removal question for PREV_RM, default No; returns 0 only on yes.
ask_prev_removal() {
  ask "Remove $PREV_RM (about 1.5 GB)? Only if a ladder match on $(read_proton_tag) worked." N && return 0
  printf 'Kept %s; you will be asked again on the next run.\n' "$PREV_RM"
  return 1
}

# remove_prev: after the single wait, re-checks idle, then deletes the replaced build and its record.
remove_prev() {
  if ! idle_check; then
    print_busy
    printf '%s: something started again (listed above); %s was not removed\n' "$CMD" "$PREV_RM"
    return 1
  fi
  if ! remove_compat_entry "$PREV_RM"; then
    printf '%s: could not remove %s/%s\n' "$CMD" "$COMPAT" "$PREV_RM"
    return 1
  fi
  rm -f -- "$PROTON_PREV_FILE"
  printf 'Removed %s/%s.\n' "$COMPAT" "$PREV_RM"
}
