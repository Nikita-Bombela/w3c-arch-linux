# shellcheck shell=bash disable=SC2034
# Why SC2034 is off: the globals below are read by the other libs, which shellcheck cannot see when it checks this file alone.
# The Steam backend (Phase 18): the third reader of the launch contract. It is read-only: Steam's files are read only through
# `python3 -I -B "$HELPER" steam-*` and this file's own path tests, and nothing here writes (no output redirection to a file, no file-changing
# command; tests/phase18.sh scans this file for that). The one write, BACKEND=steam in the backend file, lives in lib/backend.sh.
# Install, update and revert under Steam (Phase 19) write only through lib/steam_setup.sh and the shared helpers it calls, never from this file.

ST_ROOT='' ST_RULE='' ST_ERR=''   # steam_root: the native Steam root, the D-07 rule that found it, or why none was found
ST_ARULE='' ST_ACCTS=''   # the D-05 rule that chose the accounts, and their ids (the userdata directory names), space separated
ST_SA=() ST_SI=() ST_SN=() ST_SE=() ST_SO=() ST_SM=()   # per shortcut: account id, appid, name, Exe file name, launch options, match flag (1 or 0)
ST_APPID='' ST_NAME='' ST_EXE='' ST_OPTS='' ST_ACCT=''   # the one shortcut chosen
ST_VIA=''   # how it was chosen: target match or W3C_STEAM_APPID
ST_OVR=''   # W3C_STEAM_APPID as a plain number, when it is set and valid (read on every run, never saved)
ST_NM=0   # how many shortcuts matched
ST_STOP='' ST_STOPMSG=''   # the stage that stopped the finder (account, shortcut or prefix) and its one-line reason
ST_PID=''   # steam_running: the pid of the live steam process, or empty
ST_RT='' ST_RTAPPID=''   # the runtime the mapped tool requires: its state (nomanifest, none, installed, missing; empty without a tool) and appid
# Phase 20: the real-process rules for launch under Steam. A Wine process's command line starts with the Windows path of its exe, while Steam's
# wrapper processes (reaper, srt-bwrap, pv-adverb, proton, steam.exe) and steam-wrap start with a host path, so only the real launcher and the
# real game match these (spike 02-ns-and-procs.txt). Single-quoted: each double backslash is one literal backslash in the ERE.
STEAM_W3C_RE='^[A-Za-z]:\\Program Files\\W3Champions\\W3Champions\.exe( |$)'
STEAM_WC3_RE='^[A-Za-z]:\\.*Warcraft III\.exe( |$)'

# steam_reaper_re APPID: prints the ERE of Steam's reaper for that shortcut. Anchored on the first argv token, so the steam-launch-wrapper and
# steam-wrap command lines, which carry the reaper path later in their argv, never match; the trailing group keeps a longer appid out.
steam_reaper_re() {
  printf '^([^ ]*/)?reaper SteamLaunch AppId=%s( |$)' "$1"
}

# steam_root: D-07. The first of ~/.steam/root, ~/.steam/steam (symlinks Steam's own steam.sh keeps), ~/.local/share/Steam and
# ~/.steam/debian-installation that resolves to a directory holding steamapps. A bare ~/.local/share/Steam that holds only compatibilitytools.d
# (every Faugus tree) is not a Steam root. Sets ST_ROOT and ST_RULE and returns 0, or sets ST_ERR and returns 1. Bash and realpath only.
steam_root() {
  local -a cand=("$HOME/.steam/root" "$HOME/.steam/steam" "$HOME/.local/share/Steam" "$HOME/.steam/debian-installation")
  # shellcheck disable=SC2088 # the tilde is row text (D-07 names the rule as the user knows the path), never expanded
  local -a rule=('~/.steam/root' '~/.steam/steam' '~/.local/share/Steam' '~/.steam/debian-installation')
  local i r
  ST_ROOT='' ST_RULE='' ST_ERR=''
  for i in 0 1 2 3; do
    r=$(realpath -e -- "${cand[i]}" 2> /dev/null) || continue
    [ -d "$r/steamapps" ] || continue
    ST_ROOT=$r ST_RULE=${rule[i]}
    return 0
  done
  if [ -d "$HOME/.var/app/com.valvesoftware.Steam" ]; then
    ST_ERR='only Flatpak Steam found (~/.var/app/com.valvesoftware.Steam): w3c-linux reads native Steam only; install the native Steam package'
  else
    ST_ERR='no native Steam found (~/.steam/root, ~/.steam/steam, ~/.local/share/Steam, ~/.steam/debian-installation): install Steam, start it and sign in once'
  fi
  return 1
}

# py_steam_find ROOT REGISTRY APPID: status-first NUL-delimited records, read-only.
#   ok, rule, accounts, then six fields per shortcut: account id, appid, name, Exe file name, launch options, match (1 or 0)
#   bad, file, path    (a present file is unreadable or malformed; file is loginusers.vdf, registry.vdf or shortcuts.vdf)
#   noaccount, path    (loginusers.vdf is absent or lists no user)
# APPID is empty or digits; non-empty makes the shortcut with that appid the only match (D-02).
py_steam_find() {
  python3 -I -B "$HELPER" steam-find "$1" "$2" "$3" 2> /dev/null
}

# py_steam_tool ROOT APPID: status-first NUL-delimited records, read-only.
#   ok, pfx, tool, rtstate, rtappid   (pfx: the first library's compatdata/<APPID>/pfx or empty; tool: the CompatToolMapping name or empty;
#                                      rtstate: empty, nomanifest, none, installed or missing; rtappid: the required runtime's appid or empty)
#   bad, file, path                   (a present file is unreadable or malformed, or the tool name could leave compatibilitytools.d)
py_steam_tool() {
  python3 -I -B "$HELPER" steam-tool "$1" "$2" 2> /dev/null
}

# py_steam_tools ROOT: status-first NUL-delimited records, read-only.
#   ok, name...   (the CompatToolMapping name of every appid in config.vdf; a missing file maps nothing, so just ok)
#   bad, file, path   (config.vdf is unreadable or malformed)
py_steam_tools() {
  python3 -I -B "$HELPER" steam-tools "$1" 2> /dev/null
}

# steam_tool_used NAME (D-12, D-21): returns 0 when some CompatToolMapping entry, for any appid, names the build NAME, or when that cannot be
# told (python3 missing, an unreadable config.vdf); returns 1 when it can be told that none does, and with no native Steam root, which has no
# Steam use. steam_root is deterministic, so under the Steam backend it finds the root the backend read.
steam_tool_used() {
  local -a T=()
  steam_root || return 1
  type -P python3 > /dev/null || return 0
  mapfile -d '' -t T < <(py_steam_tools "$ST_ROOT")
  [ "${T[0]-}" = ok ] || return 0
  local n
  for n in "${T[@]:1}"; do
    [ "$n" != "$1" ] || return 0
  done
  return 1
}

# steam_appid V: prints V as a plain number (no leading zeros) when it is one to ten ASCII digits and at most 4294967295, else returns 1.
steam_appid() {
  local LC_ALL=C
  [[ $1 =~ ^[0-9]{1,10}$ ]] || return 1
  [ $((10#$1)) -le 4294967295 ] || return 1
  printf '%s' $((10#$1))
}

# steam_running: D-11. ~/.steam/steam.pid holds digits and <PROC_DIR>/<pid>/comm reads exactly steam: sets ST_PID and returns 0, else
# returns 1 (a stale file, a recycled pid and a non-number all read as not running). Files only: no pgrep, no ps, no listing of PROC_DIR, and
# never registry.vdf's SteamPID (it is off by one, Phase 16).
steam_running() {
  local LC_ALL=C pid='' c=''
  ST_PID=''
  [ -f "$HOME/.steam/steam.pid" ] && [ -r "$HOME/.steam/steam.pid" ] || return 1   # -f: a FIFO there must not block doctor
  read -r pid < "$HOME/.steam/steam.pid" || true
  [[ $pid =~ ^[0-9]{1,10}$ ]] || return 1
  [ -r "$PROC_DIR/$pid/comm" ] || return 1
  read -r c < "$PROC_DIR/$pid/comm" || true
  [ "$c" = steam ] || return 1
  ST_PID=$pid
}

# steam_busy: adds to BUSY what only the Steam backend tells us (Phase 19): the shortcut's own launch (Steam's reaper for its appid), W3Champions and
# Warcraft III. All three use the real-process rules (Phase 20): a steam-wrap or proton process carries these paths in its argv without being them, so
# an unanchored match would make install, update or revert wait on a lingering wrapper. Steam itself never blocks: the spike provisioned with Steam
# up. Battle.net.exe and the prefix's wineserver stay in idle_check for every backend. Reads the process table only.
steam_busy() {
  [ -z "$ST_APPID" ] || proc_match "the Steam shortcut (appid $ST_APPID)" -f "$(steam_reaper_re "$ST_APPID")"
  proc_match 'W3Champions' -f "$STEAM_W3C_RE"
  proc_match 'Warcraft III' -f "$STEAM_WC3_RE"
}

# steam_opts_wv2: prints the value of WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS in the shortcut's Launch Options (the first token that starts with it),
# or nothing. The match monitor tags its tally lines with it, as launch_cmd's flags tag a Faugus or umu run.
steam_opts_wv2() {
  local -a tok
  local t
  read -ra tok <<< "$ST_OPTS"
  for t in "${tok[@]}"; do
    case $t in
      WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=*)
        printf '%s' "${t#*=}"
        return 0 ;;
    esac
  done
}

# steam_backend [runner]: the Steam backend's reader. It prints nothing and sets the contract variables the other readers set. backend_read calls it.
steam_backend() {
  local -a E=() Q=()
  local i=3 n=0 hit=0 f='' p='' ov=${W3C_STEAM_APPID-}
  if [ "${1-}" = runner ]; then
    # the per-step re-read (Phase 19 D-11): the root and appid keep what the full read set earlier in this run, as the umu reader keeps OV_*
    BN_RUNNER_NOW=''
    [ -n "$ST_ROOT" ] && [ -n "$ST_APPID" ] || return 1
    mapfile -d '' -t Q < <(py_steam_tool "$ST_ROOT" "$ST_APPID")
    [ "${Q[0]-}" = ok ] && [ -n "${Q[2]-}" ] || return 1
    BN_RUNNER_NOW=${Q[2]}
    return 0
  fi
  NEED_ENTRY='' NEED_PREFIX='' NEED_UMU='' BN_PREFIX='' BN_RUNNER='' BN_LAUNCH_ARGUMENTS='' BN_PATH='' PREFIX='' RUNNER_PATH=''
  UMU_VERSION='' FAUGUS_VERSION=''
  R=() BN_LAUNCH_ENV=() FAUGUS_ENV_PRE=() FAUGUS_ENV_POST=()
  ST_ROOT='' ST_RULE='' ST_ERR='' ST_ARULE='' ST_ACCTS=''
  ST_SA=() ST_SI=() ST_SN=() ST_SE=() ST_SO=() ST_SM=()
  ST_APPID='' ST_NAME='' ST_EXE='' ST_OPTS='' ST_ACCT='' ST_VIA='' ST_STOP='' ST_STOPMSG='' ST_OVR='' ST_NM=0 ST_RT='' ST_RTAPPID=''
  BN_SOURCE=$BACKEND_FILE
  steam_running || true   # it needs no root, so it runs first and the row shows it even when the finder stops
  if ! steam_root; then
    NEED_ENTRY='Steam root' NEED_PREFIX='Steam root'
    return 0
  fi
  COMPAT=$ST_ROOT/compatibilitytools.d
  if ! type -P python3 > /dev/null; then
    NEED_ENTRY=python3 NEED_PREFIX=python3
    return 0
  fi
  # D-02: an empty W3C_STEAM_APPID is unset; anything else must be an appid, and is never echoed (it is unvalidated input)
  if [ -n "$ov" ] && ! ST_OVR=$(steam_appid "$ov"); then
    ST_OVR=''
    ST_STOP=shortcut NEED_ENTRY=W3C_STEAM_APPID NEED_PREFIX=W3C_STEAM_APPID
    ST_STOPMSG='W3C_STEAM_APPID is not an appid (digits only, at most 4294967295)'
    return 0
  fi
  mapfile -d '' -t E < <(py_steam_find "$ST_ROOT" "$HOME/.steam/registry.vdf" "$ST_OVR")
  case ${E[0]-} in
    ok)
      ST_ARULE=${E[1]-} ST_ACCTS=${E[2]-}
      while [ $((i + 5)) -lt "${#E[@]}" ]; do
        ST_SA+=("${E[i]}") ST_SI+=("${E[i + 1]}") ST_SN+=("${E[i + 2]}") ST_SE+=("${E[i + 3]}") ST_SO+=("${E[i + 4]}") ST_SM+=("${E[i + 5]}")
        if [ "${E[i + 5]}" = 1 ]; then
          n=$((n + 1))
          hit=$((${#ST_SM[@]} - 1))
        fi
        i=$((i + 6))
      done
      ST_NM=$n
      if [ "$n" -eq 1 ]; then
        ST_ACCT=${ST_SA[hit]} ST_APPID=${ST_SI[hit]} ST_NAME=${ST_SN[hit]} ST_EXE=${ST_SE[hit]} ST_OPTS=${ST_SO[hit]}
        ST_VIA='target match'
        [ -z "$ST_OVR" ] || ST_VIA=W3C_STEAM_APPID
        mapfile -d '' -t Q < <(py_steam_tool "$ST_ROOT" "$ST_APPID")
        if [ "${Q[0]-}" = ok ]; then
          # a missing prefix or mapping is no stop: the other rows still run (D-10)
          if [ -n "${Q[1]-}" ]; then PREFIX=${Q[1]} BN_PREFIX=${Q[1]}; else NEED_PREFIX=prefix; fi
          if [ -n "${Q[2]-}" ]; then BN_RUNNER=${Q[2]}; else NEED_ENTRY=CompatToolMapping; fi
          ST_RT=${Q[3]-} ST_RTAPPID=${Q[4]-}
        else
          # any steam-tool file stops at the prefix row, which names it: one rule, fail closed (D-10)
          if [ "${Q[0]-}" = bad ]; then f=${Q[1]-} p=${Q[2]-}; else f='Steam files' p=$ST_ROOT; fi
          ST_STOP=prefix NEED_ENTRY=$f NEED_PREFIX=$f
          ST_STOPMSG="$f is unreadable or malformed: $p (if Steam is writing it, rerun doctor)"
        fi
      elif [ "$n" -eq 0 ]; then
        ST_STOP=shortcut NEED_ENTRY='one Battle.net shortcut' NEED_PREFIX='one Battle.net shortcut'
        ST_STOPMSG='no Battle.net shortcut in Steam: Games -> Add a Non-Steam Game to My Library -> Browse... -> the Battle.net installer -> Add Selected Programs'
        [ -z "$ST_OVR" ] || ST_STOPMSG="W3C_STEAM_APPID=$ST_OVR names no shortcut in shortcuts.vdf"
      else
        ST_STOP=shortcut NEED_ENTRY='one Battle.net shortcut' NEED_PREFIX='one Battle.net shortcut'
        ST_STOPMSG='more than one shortcut matches: set W3C_STEAM_APPID=<appid> to pick one'
      fi ;;
    noaccount)
      ST_STOP=account NEED_ENTRY='Steam account' NEED_PREFIX='Steam account'
      ST_STOPMSG="no Steam account in ${E[1]-}: start Steam and sign in once" ;;
    *)
      if [ "${E[0]-}" = bad ]; then f=${E[1]-} p=${E[2]-} ST_ARULE=${E[3]-} ST_ACCTS=${E[4]-}; else f='Steam files' p=$ST_ROOT; fi
      case $f in shortcuts.vdf) ST_STOP=shortcut ;; *) ST_STOP=account ;; esac
      NEED_ENTRY=$f NEED_PREFIX=$f
      ST_STOPMSG="$f is unreadable or malformed: $p (if Steam is writing it, rerun doctor)" ;;
  esac
  return 0
}

# steam_note: the Steam backend's doctor row text (no newline), naming where the backend came from.
steam_note() {
  printf "steam: from %s; Steam's files are read, never written" "$BN_SOURCE"
}

# steam_wrap_cmd (Phase 20 D-09): prints the command the shortcut's steam-wrap runs, no newline: the script's real path for a clone,
# $HOME/.local/bin/w3c-linux for make install-user and <prefix>/bin/w3c-linux for a package or make install (the rule check_location shows;
# never SELF's real path into lib/). A path with a byte outside [A-Za-z0-9/._+@:,=-] is single-quoted with each ' written as '\''. Whether
# Steam parses quotes in Launch Options is unverified (RESEARCH A4), so only a plain path is promised to work.
steam_wrap_cmd() {
  local LC_ALL=C p q=\' rep="'\\''"
  case $INSTALL_KIND in
    user) p=$HOME/.local/bin/w3c-linux ;;
    system) p=${INSTALL_PREFIX#"$SYS_ROOT"}/bin/w3c-linux ;;
    *) p=$SELF ;;
  esac
  if [[ $p =~ [^A-Za-z0-9/._+@:,=-] ]]; then
    printf "'%s'" "${p//$q/$rep}"
  else
    printf '%s' "$p"
  fi
}

# steam_launch_opts (D-09): the default Launch Options string, printed for the user to paste and never written. The four variables and %command%
# are the spike's string; steam-wrap is the shortcut's entry into w3c-linux.
steam_launch_opts() {
  printf 'W3C_SHARED_QUERY=1 WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--no-sandbox PROTON_ENABLE_WAYLAND=0 WINE_SIMULATE_WRITECOPY=1 %s steam-wrap %%command%%' "$(steam_wrap_cmd)"
}

# steam_opts_wrap: prints the token right before the first steam-wrap token of ST_OPTS, one pair of surrounding quotes stripped (empty when
# steam-wrap is the first token), and returns 0; returns 1 when there is no steam-wrap token. Tokens split on blanks, so a quoted path with a
# space is not rejoined. ponytail: tighten when a user with such a path reports the warn.
steam_opts_wrap() {
  local -a tok
  local i c
  read -ra tok <<< "$ST_OPTS"
  for i in "${!tok[@]}"; do
    [ "${tok[i]}" = steam-wrap ] || continue
    c=''
    if [ "$i" -gt 0 ]; then c=${tok[i - 1]} c=${c#[\'\"]} c=${c%[\'\"]}; fi
    printf '%s' "$c"
    return 0
  done
  return 1
}

# steam_opts_problems (D-07, D-09): prints why the stored Launch Options fail, nothing when they pass. Each of the four variables, steam-wrap and
# %command% must be a token; extra tokens are allowed. Presence is judged, not order: %command% before steam-wrap passes and breaks Play.
# ponytail: tighten when a user reports it. A steam-wrap command that is not an absolute path to an executable file is a second reason.
steam_opts_problems() {
  local -a tok miss=()
  local t w3=0 wv=0 pw=0 wc=0 sw=0 cm=0 out='' cmd
  read -ra tok <<< "$ST_OPTS"
  for t in "${tok[@]}"; do
    case $t in
      W3C_SHARED_QUERY=1) w3=1 ;;
      WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=*--no-sandbox*) wv=1 ;;
      PROTON_ENABLE_WAYLAND=0) pw=1 ;;
      WINE_SIMULATE_WRITECOPY=1) wc=1 ;;
      steam-wrap) sw=1 ;;
      %command%) cm=1 ;;
    esac
  done
  [ "$w3" = 1 ] || miss+=(W3C_SHARED_QUERY=1)
  [ "$wv" = 1 ] || miss+=(WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--no-sandbox)
  [ "$pw" = 1 ] || miss+=(PROTON_ENABLE_WAYLAND=0)
  [ "$wc" = 1 ] || miss+=(WINE_SIMULATE_WRITECOPY=1)
  [ "$sw" = 1 ] || miss+=(steam-wrap)
  [ "$cm" = 1 ] || miss+=(%command%)
  if [ "${#miss[@]}" -gt 0 ]; then
    printf -v out 'missing %s' "$(printf '%s, ' "${miss[@]}")"
    out=${out%, }
  fi
  if [ "$sw" = 1 ]; then
    cmd=$(steam_opts_wrap)
    if [[ $cmd != /* ]] || [ ! -f "$cmd" ] || [ ! -x "$cmd" ]; then
      out=${out:+$out; }"steam-wrap's command $cmd does not exist or is not executable"
    fi
  fi
  printf '%s' "$out"
}

# steam_opts_row (D-07): the launch options row. A warn, never a fail, when the stored string lacks a part, with the string to paste; else the
# stored string as a pass. The Phase 18 D-12 slot and label (launch_arguments) are kept.
steam_opts_row() {
  local p
  p=$(steam_opts_problems)
  if [ -n "$p" ]; then
    emit warn 'launch options' "$p; set the shortcut's Launch Options to: $(steam_launch_opts)"
  else
    emit pass 'launch options' "${ST_OPTS:-(none)}"
  fi
}

# steam_rows_entry: the Steam rows of doctor, in order, from what steam_backend found.
steam_rows_entry() {
  local i sfx
  if [ -n "$ST_ROOT" ]; then
    emit pass 'steam root' "$ST_ROOT ($ST_RULE)"
  else
    emit fail 'steam root' "$ST_ERR"
  fi
  # D-11: running only matters to launch (it needs a live Steam), so not running is a warn here, never a fail
  if [ -n "$ST_PID" ]; then
    emit pass 'steam running' "pid $ST_PID"
  else
    emit warn 'steam running' 'no: only launch needs Steam running'
  fi
  # D-06: the numeric account ids and the rule that chose them; no login name, display name or steamid64 ever reaches here
  if [ -n "$ST_ACCTS" ]; then
    emit pass account "$ST_ACCTS ($ST_ARULE)"
  elif [ "$ST_STOP" = account ]; then
    emit fail account "$ST_STOPMSG"
  else
    emit skip account "needs: $NEED_ENTRY"
  fi
  case $ST_STOP in
    shortcut)
      if [ "$ST_NM" -gt 1 ]; then
        # D-03: every match, in shortcuts.vdf order, then the hint; nothing is picked
        for i in "${!ST_SM[@]}"; do
          [ "${ST_SM[i]}" = 1 ] || continue
          sfx=''
          [ "$ST_ARULE" != 'all accounts' ] || sfx=", account ${ST_SA[i]}"
          emit fail shortcut "${ST_SN[i]} (appid ${ST_SI[i]}$sfx)"
        done
        emit fail shortcut "$ST_STOPMSG"
      else
        # D-04: the click path, then the account's other shortcuts and the way to pick one
        emit fail shortcut "$ST_STOPMSG"
        for i in "${!ST_SM[@]}"; do
          sfx=''
          [ "$ST_ARULE" != 'all accounts' ] || sfx=", account ${ST_SA[i]}"
          emit warn shortcut "${ST_SN[i]} (appid ${ST_SI[i]}, target ${ST_SE[i]}$sfx)"
        done
        if [ "${#ST_SM[@]}" -gt 0 ]; then
          emit warn shortcut 'if one of these starts Battle.net, set W3C_STEAM_APPID=<appid>'
        fi
      fi ;;
    *)
      if [ -n "$ST_APPID" ]; then
        emit pass shortcut "$ST_NAME (appid $ST_APPID, target $ST_EXE)"
      else
        emit skip shortcut "needs: $NEED_ENTRY"
      fi ;;
  esac
  if [ -n "$ST_APPID" ]; then
    emit pass appid "$ST_APPID ($ST_VIA)"
    steam_rows_tool
    # D-12 slot, Phase 20 D-07: judged part by part (warn, never fail: no variable was tested on its own in Phase 16), the string to paste on a warn
    steam_opts_row
  else
    for i in appid prefix runner runtime 'launch options'; do emit skip "$i" "needs: $NEED_ENTRY"; done
  fi
}

# steam_show: the lines `backend show` prints after the backend line (D-14), from what steam_backend found. The root, the shortcut's name and
# appid and the prefix only: never an account name or id. The appid is shown here and never stored.
steam_show() {
  if [ -z "$ST_ROOT" ]; then
    printf 'steam: %s\n' "$ST_ERR"
    return 0
  fi
  printf 'root: %s\n' "$ST_ROOT"
  if [ -z "$ST_APPID" ]; then
    printf 'steam: needs: %s; run %s doctor\n' "$NEED_ENTRY" "$BIN_NAME"
    return 0
  fi
  printf 'shortcut: %s (appid %s)\n' "$ST_NAME" "$ST_APPID"
  if [ -z "$PREFIX" ]; then
    printf 'steam: needs: %s; run %s doctor\n' "$NEED_PREFIX" "$BIN_NAME"
  else
    printf 'prefix: %s\n' "$PREFIX"
  fi
}

# steam_rows_tool: the prefix, runner and runtime rows of the chosen shortcut (D-08 order, D-09, D-10 severities).
steam_rows_tool() {
  if [ "$ST_STOP" = prefix ]; then
    emit fail prefix "$ST_STOPMSG"
    emit skip runner "needs: $NEED_ENTRY"
    emit skip runtime "needs: $NEED_ENTRY"
    return 0
  fi
  if [ "$NEED_PREFIX" = prefix ]; then
    emit fail prefix "no compatdata/$ST_APPID/pfx in any Steam library: press Play on the shortcut once so Steam creates it"
  else
    emit pass prefix "$PREFIX"
  fi
  if [ -z "$BN_RUNNER" ]; then
    emit fail runner "no CompatToolMapping entry for appid $ST_APPID: in Steam, open the shortcut's Properties -> Compatibility and select a compatibility tool"
  else
    emit pass runner "$BN_RUNNER (CompatToolMapping)"
  fi
  case $ST_RT in
    installed) emit pass runtime "$ST_RTAPPID installed (required by $BN_RUNNER)" ;;
    none) emit pass runtime "none required by $BN_RUNNER" ;;
    missing) emit warn runtime "$ST_RTAPPID required by $BN_RUNNER is not installed (Steam may download it on the next Play of the shortcut)" ;;
    nomanifest) emit skip runtime 'needs: toolmanifest.vdf' ;;
    *) emit skip runtime 'needs: CompatToolMapping' ;;
  esac
}
