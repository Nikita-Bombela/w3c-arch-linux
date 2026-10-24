# shellcheck shell=bash
# Backend dispatch and selection live here. backend_read is the one entry point every subcommand reads the active backend through: it calls
# the active backend's reader (faugus_backend in lib/faugus.sh, umu_backend in lib/umu.sh, steam_backend in lib/steam.sh), and no other code
# calls a reader (Phase 17 D-02, D-08). backend_resolve picks the backend once per run before any output (Phase 10 D-06); backend_file_read
# and backend_file_write handle the saved backend file, which is data and never sourced (D-19); cmd_backend is the backend subcommand (D-17).

# backend_read [runner]: dispatch on BACKEND (set once by backend_resolve) to that backend's reader, which prints nothing and sets the
# contract variables DESIGN.md lists. A BACKEND with no arm is an internal error that stops the run: one line on stderr and exit 2, because
# the callers ignore the status and would go on with stale contract variables (17-REVIEW WR-01).
# shellcheck disable=SC2120 # the optional argument is passed from lib/prefix.sh
backend_read() {
  case $BACKEND in
    faugus) faugus_backend "$@" ;;
    umu) umu_backend "$@" ;;
    steam) steam_backend "$@" ;;
    *)
      printf "backend_read: internal error: no reader for backend '%s'\n" "$BACKEND" >&2
      exit 2 ;;
  esac
}

# backend_pair: D-07, exactly one of W3C_PREFIX and W3C_PROTON set (empty counts as unset) is an error: message on stderr, return 1.
backend_pair() {
  if [ -n "${W3C_PREFIX-}" ] || [ -n "${W3C_PROTON-}" ]; then
    if [ -z "${W3C_PREFIX-}" ] || [ -z "${W3C_PROTON-}" ]; then
      printf '%s: set both W3C_PREFIX and W3C_PROTON, or neither\n' "$BIN_NAME" >&2
      return 1
    fi
  fi
  return 0
}

# backend_file_read: sets F_BACKEND, F_PREFIX, F_RUNNER from BACKEND_FILE. Returns 1 when the file is absent, 2 when it is not a valid
# backend (BACKEND=steam, any other line ignored; or BACKEND=umu with PREFIX and RUNNER), else 0. The file is data: read line by line, never sourced or evaluated (D-19).
backend_file_read() {
  local k v
  F_BACKEND='' F_PREFIX='' F_RUNNER=''
  [ -e "$BACKEND_FILE" ] || [ -L "$BACKEND_FILE" ] || return 1
  [ -f "$BACKEND_FILE" ] || return 2   # a directory or a dangling link is present but not a valid file (D-17, D-19)
  while IFS='=' read -r k v || [ -n "$k" ]; do
    case $k in
      BACKEND) F_BACKEND=$v ;;
      PREFIX) F_PREFIX=$v ;;
      RUNNER) F_RUNNER=$v ;;
    esac
  done < "$BACKEND_FILE"
  [ "$F_BACKEND" = steam ] && return 0
  [ "$F_BACKEND" = umu ] && [ -n "$F_PREFIX" ] && [ -n "$F_RUNNER" ] || return 2
  return 0
}

# backend_file_write PREFIX RUNNER: the saved backend, atomically (write_state).
backend_file_write() {
  write_state "$BACKEND_FILE" "BACKEND=umu
PREFIX=$1
RUNNER=$2"
}

# backend_resolve: picks the backend once per run, before any command prints (D-06): both env vars, else the saved file, else Faugus.
# Return 1 for a half-set override (D-07) or a present but malformed file (D-17: never silently hidden).
backend_resolve() {
  local rc
  BACKEND=faugus BACKEND_SRC=faugus
  backend_pair || return 1
  if [ -n "${W3C_PREFIX-}" ]; then
    BACKEND=umu BACKEND_SRC=env
    OV_PREFIX=$(realpath -m -- "$W3C_PREFIX")
    OV_RUNNER=$(runner_abs "$W3C_PROTON")
    return 0
  fi
  backend_file_read && rc=0 || rc=$?
  case $rc in
    0)
      if [ "$F_BACKEND" = steam ]; then
        BACKEND=steam BACKEND_SRC=file
      else
        BACKEND=umu BACKEND_SRC=file
        OV_PREFIX=$(realpath -m -- "$F_PREFIX")
        OV_RUNNER=$(runner_abs "$F_RUNNER")
      fi ;;
    2)
      printf '%s: %s is not a valid umu backend file (it needs BACKEND=umu, PREFIX= and RUNNER= lines, or BACKEND=steam): fix it or run %s backend clear\n' \
        "$BIN_NAME" "$BACKEND_FILE" "$BIN_NAME" >&2
      return 1 ;;
  esac
  return 0
}

# cmd_backend VERB...: set umu PREFIX RUNNER, show, clear (D-17). Every verb is refused for a half-set override (D-07). show resolves
# on its own so set and clear still work on a malformed file.
cmd_backend() {
  local usage="usage: $BIN_NAME backend set umu PREFIX RUNNER | backend set steam | backend show | backend clear" p r
  backend_pair || return 2
  case ${1-} in
    set)
      # D-13: exactly `set steam`; the file is BACKEND=steam and nothing else, and no shortcut is needed yet
      if [ "${2-}" = steam ]; then
        [ "$#" = 2 ] || { printf '%s\n' "$usage" >&2; return 2; }
        steam_root || { printf 'backend: %s. Nothing was saved.\n' "$ST_ERR" >&2; return 1; }
        write_state "$BACKEND_FILE" BACKEND=steam || { printf 'backend: cannot write %s\n' "$BACKEND_FILE" >&2; return 1; }
        printf 'Saved the Steam backend in %s (Steam root %s). Next: %s doctor\n' "$BACKEND_FILE" "$ST_ROOT" "$BIN_NAME"
        [ -n "${W3C_PREFIX-}" ] && printf 'W3C_PREFIX and W3C_PROTON are set and win over this file until you unset them\n'
        return 0
      fi
      # D-17: exactly `set umu PREFIX RUNNER`
      [ "$#" = 4 ] || { printf '%s\n' "$usage" >&2; return 2; }
      [ "$2" = umu ] || { printf 'backend: unknown backend %s; use umu or steam\n' "$2" >&2; return 2; }
      # T-10-10: an empty or multi-line value would inject or lose KEY lines
      case $3 in '' | *$'\n'*) printf 'backend: PREFIX and RUNNER must be non-empty single-line values\n' >&2; return 2 ;; esac
      case $4 in '' | *$'\n'*) printf 'backend: PREFIX and RUNNER must be non-empty single-line values\n' >&2; return 2 ;; esac
      p=$(realpath -m -- "$3")
      # D-18: the prefix must exist and be a Wine prefix; nothing is created. The runner is not checked.
      if [ ! -d "$p/drive_c" ]; then
        printf 'backend: %s is not a Wine prefix (no drive_c); point it at your existing Battle.net prefix. Nothing was saved.\n' "$p" >&2
        return 1
      fi
      r=$(runner_abs "$4")
      backend_file_write "$p" "$r" || { printf 'backend: cannot write %s\n' "$BACKEND_FILE" >&2; return 1; }
      printf 'Saved the umu backend in %s: prefix %s, runner %s. Next: %s doctor\n' "$BACKEND_FILE" "$p" "$r" "$BIN_NAME"
      [ -n "${W3C_PREFIX-}" ] && printf 'W3C_PREFIX and W3C_PROTON are set and win over this file until you unset them\n'
      return 0 ;;
    show)
      [ "$#" = 1 ] || { printf '%s\n' "$usage" >&2; return 2; }
      backend_resolve || return 2
      if [ "$BACKEND" = steam ]; then
        # D-14: resolved now; the steam backend only comes from the file (the env selects umu), and the appid is shown, never stored
        printf 'backend: steam (from %s)\n' "$BACKEND_FILE"
        # shellcheck disable=SC2119 # no argument: the full read, as in checks.sh and report.sh
        backend_read
        steam_show
      elif [ "$BACKEND" = umu ]; then
        if [ "$BACKEND_SRC" = env ]; then printf 'backend: umu (from W3C_PREFIX and W3C_PROTON)\n'
        else printf 'backend: umu (from %s)\n' "$BACKEND_FILE"; fi
        printf 'prefix: %s\nrunner: %s\n' "$OV_PREFIX" "$OV_RUNNER"
        # D-06: the env wins; say so when a file is also there
        [ "$BACKEND_SRC" = env ] && [ -e "$BACKEND_FILE" ] && printf '%s is ignored while W3C_PREFIX and W3C_PROTON are set\n' "$BACKEND_FILE"
      else
        printf 'backend: faugus (W3C_PREFIX and W3C_PROTON are unset and %s does not exist)\n' "$BACKEND_FILE"
      fi
      return 0 ;;
    clear)
      [ "$#" = 1 ] || { printf '%s\n' "$usage" >&2; return 2; }
      # T-10-12: one fixed path, no recursion or globbing; a malformed file can always be cleared
      if [ -e "$BACKEND_FILE" ] || [ -L "$BACKEND_FILE" ]; then
        rm -f -- "$BACKEND_FILE" || { printf 'backend: cannot remove %s\n' "$BACKEND_FILE" >&2; return 1; }
        printf 'Removed %s; the Faugus backend is used unless W3C_PREFIX and W3C_PROTON are set\n' "$BACKEND_FILE"
      else
        printf 'Nothing to clear: %s does not exist\n' "$BACKEND_FILE"
      fi
      return 0 ;;
    *) printf '%s\n' "$usage" >&2; return 2 ;;
  esac
}
