# shellcheck shell=bash disable=SC2034
# Why SC2034 is off: the globals below are read by the other libs, which shellcheck cannot see when it checks this file alone.
# Shared state and helpers: colours, say, emit, banner, paths, prompts, state records and the run lock. Used by every subcommand.

FAILS=0
QUIET_PASS=0   # install sets 1 to print only warn and fail lines

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_PASS=$'\033[32m' C_WARN=$'\033[33m' C_FAIL=$'\033[31m' C_SKIP=$'\033[2m' C_BOLD=$'\033[1m' C_RESET=$'\033[0m'
else
  C_PASS='' C_WARN='' C_FAIL='' C_SKIP='' C_BOLD='' C_RESET=''
fi
# TAG marks launch's own lines among Battle.net and Wine output; terminal only, like the colours, so pipes and tests stay unprefixed.
TAG=''
if [ -t 1 ]; then TAG="${C_PASS}[w3c-arch]${C_RESET} "; fi

# say FORMAT ARG...: printf with TAG in front. Every launch message goes through it.
# shellcheck disable=SC2059 # FORMAT is always a literal at the call site
say() { printf "%s$1" "$TAG" "${@:2}"; }

# emit STATUS LABEL VALUE: the only way a report line is printed.
emit() {
  local col=''
  case $1 in
    pass) col=$C_PASS ;;
    warn) col=$C_WARN ;;
    fail) col=$C_FAIL; FAILS=$((FAILS + 1)) ;;
    skip) col=$C_SKIP ;;
  esac
  if [ "$QUIET_PASS" = 1 ] && [ "$1" != warn ] && [ "$1" != fail ]; then
    return 0
  fi
  printf '%s%s%s  %-16s  %s\n' "$col" "$1" "$C_RESET" "$2" "$3"
}

# banner: w3c-arch title, only on a terminal so reports and tests stay parseable.
banner() {
  local blue='' rst=''
  if [ -z "${NO_COLOR:-}" ]; then blue=$'\033[1;36m' rst=$'\033[0m'; fi
  printf '%s' "$blue"
  cat <<'EOF'
 ██╗    ██╗██████╗  ██████╗       █████╗ ██████╗  ██████╗██╗  ██╗
 ██║    ██║╚════██╗██╔════╝      ██╔══██╗██╔══██╗██╔════╝██║  ██║
 ██║ █╗ ██║ █████╔╝██║     █████╗███████║██████╔╝██║     ███████║
 ██║███╗██║ ╚═══██╗██║     ╚════╝██╔══██║██╔══██╗██║     ██╔══██║
 ╚███╔███╔╝██████╔╝╚██████╗      ██║  ██║██║  ██║╚██████╗██║  ██║
  ╚══╝╚══╝ ╚═════╝  ╚═════╝      ╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝
EOF
  printf '%s\n' "$rst"
}

STATE_HOME=${XDG_STATE_HOME:-$HOME/.local/state}
W3C_STATE=$STATE_HOME/w3c-linux
PROTON_TAG_FILE=$W3C_STATE/proton-tag   # the W3C build install recorded
PROTON_PREV_FILE=$W3C_STATE/proton-tag.prev   # the W3C build update replaced
PREV_RM=''   # the replaced W3C build prev_removal_due found removable
CMD=install   # message prefix of the shared helpers; cmd_update sets update
LAUNCHER_VERSION_FILE=$W3C_STATE/launcher-version   # the W3Champions version install recorded
LATEST_JSON_URL=https://github.com/w3champions/launcher-e-release/releases/latest/download/latest.json
LAUNCHER_MSI_API=https://update-service.w3champions.com/api/launcher-e
CACHE_DIR=${XDG_CACHE_HOME:-$HOME/.cache}/w3c-linux
# the saved umu backend: written by backend set and by install/update, read by backend_resolve; KEY=VAL data, never sourced (Phase 10 D-17, D-19)
BACKEND_FILE=${XDG_CONFIG_HOME:-$HOME/.config}/w3c-linux/backend
DESK_FILE=${XDG_DATA_HOME:-$HOME/.local/share}/applications/w3c-linux.desktop   # the menu entry; written by install, removed by revert
DESK_ICON=${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps/w3c-linux.png   # its icon; written by install, removed by revert
WINE_LOG=$CACHE_DIR/wine.log   # umu-run and Proton output of every in-prefix step, appended
LAUNCH_LOG=$CACHE_DIR/launch.log   # launch's own lines when it runs without a terminal; the previous session is kept as launch.log.1
WV2_URL='https://go.microsoft.com/fwlink/p/?LinkId=2124701'   # Evergreen standalone installer; the redirect's file name is below
WV2_FILE=$CACHE_DIR/webview2/MicrosoftEdgeWebView2RuntimeInstallerX64.exe
COMPAT=$HOME/.local/share/Steam/compatibilitytools.d   # Faugus derives this from ~/.local/share, not XDG_DATA_HOME
PROC_DIR=${W3C_PROC_DIR:-/proc}   # test seam, like W3C_PTRACE_SCOPE_FILE
SYS_ROOT=${W3C_SYS_ROOT-}   # test seam, like W3C_PROC_DIR: report reads os-release, DRM cards, Vulkan ICDs and libraries under it
# INSTALL_KIND, INSTALL_PREFIX and BIN_NAME come from where the script lives (SELF), never from $0 or a marker file, so any symlink or
# relative path gives the same answer. A make or package install keeps the script at <prefix>/lib/w3c-linux/w3c-linux.sh; anything else is
# a clone. The prefix is compared with $HOME/.local by inode (-ef), not by string, because a symlinked /home makes the real path differ
# from $HOME. On a real system SYS_ROOT is empty. Accepted edge: a clone kept at a path ending in lib/w3c-linux counts as an install.
BIN_NAME=w3c-linux.sh
INSTALL_KIND=clone
INSTALL_PREFIX=''
case $SELF in
  */lib/w3c-linux/w3c-linux.sh)
    INSTALL_PREFIX=${SELF%/lib/w3c-linux/w3c-linux.sh}
    BIN_NAME=w3c-linux
    if [ "$INSTALL_PREFIX" -ef "$HOME/.local" ]; then INSTALL_KIND=user; else INSTALL_KIND=system; fi
    ;;
esac
# OWN_DESK: the menu entry the installer (make or the package) owns. install, revert and doctor never write or remove it (Phase 11 D-01);
# a clone keeps the package's /usr entry as before.
OWN_DESK=$SYS_ROOT/usr/share/applications/w3c-linux.desktop
[ "$INSTALL_KIND" = clone ] || OWN_DESK=$INSTALL_PREFIX/share/applications/w3c-linux.desktop
RELEASE_API=https://api.github.com/repos/davex32/proton-ge-w3c/releases/latest
FORK_URL=https://github.com/davex32/proton-ge-w3c
WINE_PROTOCOL_URL=https://raw.githubusercontent.com/wine-mirror/wine/master/server/protocol.def
ISSUE57_API=https://api.github.com/repos/w3champions/w3champions-issues/issues/57
ISSUE57_URL=https://github.com/w3champions/w3champions-issues/issues/57
GE_RELEASE_API=https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest
GE_SEARCH_URL='https://github.com/search?q=repo%3AGloriousEggroll%2Fproton-ge-custom+JobObjectBasicLimitInformation&type=code'
BUSY=() REL=() G=()   # idle_check reasons; py_release fields; games helper fields
RT_TAG='' RT_TGZ='' RT_URL='' RT_SIZE='' RT_SUMS='' RT_ERR='' STAGE=''
LIST=''   # list_text output
# The launch contract (NEED_ENTRY to NEED_UMU): faugus_backend in lib/faugus.sh sets these and DESIGN.md says what each means.
NEED_ENTRY=''    # root cause when the battlenet entry was not read; empty = satisfied
NEED_PREFIX=''   # NEED_ENTRY, or "prefix" when the entry has no prefix
BN_SOURCE='' BN_PREFIX='' BN_RUNNER='' RUNNER_PATH='' BN_RUNNER_NOW=''
BN_LAUNCH_ENV=()
FAUGUS_ENV_PRE=() FAUGUS_ENV_POST=()   # mirrored Faugus env, spliced around BN_LAUNCH_ENV by later phases
PTRACE_FILE=''
PREFIX='' APPID='' W3C_EXE=''
UMU_RUN_USER=${UMU_RUN-}   # Phase 10 D-01: the user's UMU_RUN, read here because the next line resets UMU_RUN
UMU_RUN='' UMU_VERSION='' NEED_UMU=''   # NEED_UMU: umu-run when it is missing or not executable
# Phase 10 D-06: set once by backend_resolve (lib/umu.sh) before dispatch. BACKEND is umu or faugus; BACKEND_SRC is env, file or faugus;
# OV_PREFIX and OV_RUNNER are the resolved override prefix and runner (a runner path or a compatibilitytools.d name).
BACKEND=faugus BACKEND_SRC=faugus OV_PREFIX='' OV_RUNNER=''
UMU_SRC=''   # which chain step umu_pick took: empty for Faugus's bundled copy, else UMU_RUN, PATH or /usr/share/umu
WC3_DIR='' WC3_EXE='' WC3_BUILD='' NEED_WC3EXE=''   # WC3_EXE is the game, W3C_EXE the launcher
LAUNCH_CLIENT=$HOME/.local/share/umu/steamrt4/pressure-vessel/bin/steam-runtime-launch-client
PREFIX_CMD=()   # prefix_cmd output: the argv of one in-prefix command
LAUNCH_CMD=()   # launch_cmd output: the argv of the launcher start
LAUNCHER_PID='' W3C_LOG='' W3C_BAT='' LAN_BASE=0 LAN_HINTED=0 START_MAX=30 BUS_MAX=120 PGREP_RC=0 LAUNCHER_UP=0   # launch: spawned child, launcher log path, start and bus wait seconds, last pgrep status, ticks follow_launcher saw the launcher running in this session
L_EXE='' L_DISP='' L_REC='' L_CUR='' L_LATEST='' L_URL='' L_ERR='' L_NEED=''   # launcher_status results
SETTLE_MAX=60   # settle_wineserver's bound in seconds
MSI_FILE=''     # fetch_launcher_msi's download
WHAT=''         # launcher_unfinished's reason
NAT_VARIANT='' NAT_SCRIPT='' NAT_REMOVE=()   # nat_variant and nat_text results: nft, iptables or none; the one script sudo runs; the printed removal lines
NAT_MARK=$W3C_STATE/nat-applied   # the per-boot "applied by w3c-linux" marker: it holds the boot_id of the boot the apply ran in
MON_TAG='' MON_POLL=60 MON_ARM_SECS=120 MON_ARMED_AT='' MON_TAIL='' MON_PID=''   # monitor: tally tag, day-check seconds, armed-state TTL in seconds, SECONDS at the last game-end, the tail child, the monitor launch forked
MATCHES_LOG=$W3C_STATE/matches.log   # tally file, append-only
MON_LOCK=$W3C_STATE/monitor.lock   # one monitor at a time (flock on fd 8)

# use_zenity: no terminal on stdin, zenity is on PATH and a display exists. A terminal always asks in the terminal.
use_zenity() { [ ! -t 0 ] && type -P zenity > /dev/null && { [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; }; }

# no_tty: stdin is not a terminal, as when a menu or dock starts launch. W3C_ASSUME_TTY=1 is a test seam like W3C_PROC_DIR: the fixtures set it so piped stdin counts as a terminal; it is not a user option.
no_tty() { [ ! -t 0 ] && [ "${W3C_ASSUME_TTY:-}" != 1 ]; }

# desk_notify URGENCY TEXT: a desktop notification, only without a terminal. The body is fixed text plus our own paths and numbers, never launcher log text.
desk_notify() {
  no_tty && type -P notify-send > /dev/null || return 0
  notify-send -u "$1" W3Champions "$2" 2> /dev/null || :
}

# desk_error TEXT: a modal error dialog with TEXT, a blank line and the launch.log path, only without a terminal (zenity is required there).
# No timeout: the dialog stays until answered. The text is fixed wording plus our own paths, never launcher log text; --no-markup keeps it literal.
desk_error() {
  no_tty && use_zenity || return 0
  zenity --error --no-markup --title=w3c-linux --width=480 --text="${1%$'\n'}"$'\n\n'"details: $LAUNCH_LOG" 2> /dev/null || :
}

# list_text LEAD ITEM...: sets LIST to LEAD, a blank line, each ITEM on its own line indented 4 spaces, a blank line. A global, not stdout, so $(...) cannot strip the trailing blank line.
list_text() {
  local items
  printf -v items '    %s\n' "${@:2}"
  LIST=$1$'\n\n'$items$'\n'
}

# ask QUESTION DEFAULT(Y|N): returns 0 for yes, 1 for no. Shared by every phase that prompts.
ask() {
  local q=$1 def=$2 hint='[Y/n]' ans zargs=()
  if [ "$def" = N ]; then
    hint='[y/N]'
    zargs=(--default-cancel)
  fi
  # zenity only with a display; any non-zero exit (Cancel, close, dead display) is No.
  if use_zenity; then
    zenity --question --no-markup --title=w3c-linux "${zargs[@]}" --text="$q" 2> /dev/null
    return
  fi
  while :; do
    # printf, not read -p: read's prompt prints nothing when stdin is not a terminal.
    printf '%s %s ' "$q" "$hint" >&2
    if ! read -r ans && [ -z "$ans" ]; then
      printf 'no answer (stdin closed); run in a terminal\n' >&2
      exit 1
    fi
    case ${ans,,} in
      '') [ "$def" = Y ]; return ;;
      y | yes) return 0 ;;
      n | no) return 1 ;;
    esac
  done
}

# desk_quote PATH: PATH as one double-quoted Desktop Entry Exec argument, as the spec quotes it (backslash, double quote, backtick and dollar
# get two levels of backslashes; a percent sign is doubled).
desk_quote() {
  local p=$1
  p=${p//\\/\\\\\\\\}
  p=${p//\"/\\\\\"}
  p=${p//\`/\\\\\`}
  p=${p//\$/\\\\\$}
  p=${p//%/%%}
  printf '"%s"' "$p"
}

# desk_unquote QUOTED: the inverse of desk_quote for the installed Exec argument (the text between Exec=" and " launch): %% becomes %, then
# two passes in which a backslash takes the next character literally (the string level, then the exec level).
desk_unquote() {
  local s=${1//%%/%} pass i c o
  for pass in 1 2; do
    o=
    for ((i = 0; i < ${#s}; i++)); do
      c=${s:i:1}
      if [[ $c == \\ ]] && [ $((i + 1)) -lt ${#s} ]; then
        i=$((i + 1))
        c=${s:i:1}
      fi
      o+=$c
    done
    s=$o
  done
  printf '%s' "$s"
}

# desk_exec_path FILE: the decoded script path in the Exec line an install wrote (the first line shaped Exec="<quoted>" launch); nothing when
# FILE is not a regular file or has no such line. Only decoded and tested, never run. Always returns 0.
desk_exec_path() {
  local l q=''
  [ -f "$1" ] || return 0
  while IFS= read -r l || [ -n "$l" ]; do
    case $l in
      'Exec="'*'" launch')
        q=${l#'Exec="'}
        q=${q%'" launch'}
        break ;;
    esac
  done < "$1"
  [ -n "$q" ] && desk_unquote "$q"
  return 0
}

# desk_ours FILE: true when FILE is a per-user entry install wrote: not a symlink (install writes a regular file, so a link is the user's) and its
# Exec line decodes to a path whose basename is w3c-linux.sh; a moved or deleted clone still counts (Phase 7 D-10, Phase 9 D-01). Reads only.
desk_ours() {
  local p
  [ -L "$1" ] && return 1
  p=$(desk_exec_path "$1")
  [ "${p##*/}" = w3c-linux.sh ]
}

# desk_is_own: true when DESK_FILE exists and is the same file as OWN_DESK, which is how a ~/.local install's entry is recognised (desk_ours
# rejects it: its Exec names w3c-linux). Never a string compare.
desk_is_own() {
  [ -e "$DESK_FILE" ] && [ "$DESK_FILE" -ef "$OWN_DESK" ]
}

# safe_tag NAME: one path component, no dot-only name, no slash, no leading dash, ASCII only.
safe_tag() {
  local LC_ALL=C
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

# read_proton_tag: the recorded tag when the state file holds a safe one, else nothing.
read_proton_tag() {
  local t=''
  [ -r "$PROTON_TAG_FILE" ] && { read -r t < "$PROTON_TAG_FILE" || true; }
  if safe_tag "$t"; then printf '%s' "$t"; fi
  return 0
}

# write_state FILE VALUE: atomic state or data file (temp file in the target's own directory, then mv); VALUE may hold newlines.
write_state() {
  local tmp
  mkdir -p -- "${1%/*}" || return 1
  tmp=$(mktemp "${1%/*}/.${1##*/}.XXXXXX") || return 1
  if ! { printf '%s\n' "$2" > "$tmp" && mv -f -- "$tmp" "$1"; }; then
    rm -f -- "$tmp"
    return 1
  fi
}

write_proton_tag() { write_state "$PROTON_TAG_FILE" "$1"; }

# safe_version V: a dotted version such as 1.6.16 (two to four numeric parts, ASCII only).
safe_version() {
  local LC_ALL=C
  [[ $1 =~ ^[0-9]+(\.[0-9]+){1,3}$ ]]
}

# read_launcher_version: the recorded launcher version when the state file holds a safe one, else nothing.
read_launcher_version() {
  local v=''
  [ -r "$LAUNCHER_VERSION_FILE" ] && { read -r v < "$LAUNCHER_VERSION_FILE" || true; }
  if safe_version "$v"; then printf '%s' "$v"; fi
  return 0
}

# acquire_lock: one install or revert at a time, so two runs cannot delete each other's download or staging dir; fd 9 is held until the process exits and is never exported.
# run_in_prefix closes it for Wine, so a lingering wineserver cannot hold it.
acquire_lock() {
  if ! type -P flock > /dev/null; then
    printf 'flock (util-linux) is missing; install it with your package manager, then rerun\n'
    desk_error 'flock (util-linux) is missing; install it with your package manager, then rerun'
    exit 1
  fi
  [ -z "${LOCK_HELD:-}" ] || return 0   # install's handover to launch: reopening fd 9 would free the lock for a moment
  if ! { mkdir -p -- "$W3C_STATE" && exec 9> "$W3C_STATE/lock" && flock -n 9; }; then
    printf 'another %s run is in progress\n' "$BIN_NAME"
    desk_error "another $BIN_NAME run is in progress"
    exit 1
  fi
  LOCK_HELD=1
}

# runner_dir NAME: where the runner build lives: NAME itself when it is a path, else its entry in compatibilitytools.d (Phase 10 D-08).
runner_dir() {
  case $1 in
    */*) printf '%s' "$1" ;;
    *) printf '%s' "$COMPAT/$1" ;;
  esac
}

# runner_is_tag TAG: BN_RUNNER names the build installed as TAG (a slash-free name equal to TAG, or its compatibilitytools.d path).
runner_is_tag() { [ "$(runner_dir "$BN_RUNNER")" = "$COMPAT/$1" ]; }

# is_w3c_runner NAME: the recorded W3C build or any *-W3C name (the rule pick-backup uses).
is_w3c_runner() {
  local t
  [ -n "$1" ] || return 1
  t=$(read_proton_tag)
  # the name of a runner path is its last component (Phase 10 D-09: one rule for both backends)
  { [ -n "$t" ] && [ "${1##*/}" = "$t" ]; } || [[ $1 == *-W3C ]]
}
