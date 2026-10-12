#!/usr/bin/env bash
# Phase 1 fixture check: runs the real w3c-linux.sh under env -i against a fake HOME per case.
# Usage: bash tests/phase1.sh [GLOB]   (GLOB filters on display names such as entry-healthy)
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=$ROOT/w3c-linux.sh
SOURCES=("$SCRIPT" "$ROOT"/lib/*.sh "$ROOT"/lib/*.py)   # every file the static checks scan: the entry plus lib/
BASH_BIN=$(type -P bash)   # resolved before any PATH narrowing (D-03)
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

T='' CASE_ENV=() OUT='' ERR='' RC=0 ERRS=()
FORBIDDEN=(wine wineserver faugus-launcher steam-runtime-launch-client pkill pgrep sudo umu-run nft iptables notify-send)

# ---------- fixture tree ----------

# write_shim FILE MARKNAME [RC]: #!/bin/sh with builtins only, so it also works under a curated PATH.
write_shim() {
  mkdir -p "${1%/*}"
  {
    printf '#!/bin/sh\n'
    # shellcheck disable=SC2016 # shim body is written literally and expanded when the shim runs
    printf 'printf "%%s\\n" "$0 $*" >> "$MARK/%s"\n' "$2"
    printf 'exit %s\n' "${3:-0}"
  } > "$1"
  chmod +x "$1"
}

add_link() { ln -s "$(type -P "$2")" "$1/bin/$2"; }
add_shim() { write_shim "$1/bin/$2" "$2" "${3:-0}"; }

# bn_set T KEY VALUE: rewrite one field of the battlenet entry in the fixture games.json.
bn_set() {
  python3 - "$1/home/.local/share/faugus-launcher/games.json" "$2" "$3" <<'PY'
import json, sys
f, k, v = sys.argv[1:4]
d = json.load(open(f))
for e in d:
    if e.get("gameid") == "battlenet":
        e[k] = v
json.dump(d, open(f, "w"), indent=2)
PY
}

# bn_op T dup|del: duplicate or delete the battlenet entry.
bn_op() {
  python3 - "$1/home/.local/share/faugus-launcher/games.json" "$2" <<'PY'
import json, sys
f, op = sys.argv[1:3]
d = json.load(open(f))
bn = [e for e in d if e.get("gameid") == "battlenet"]
d = [e for e in d if e.get("gameid") != "battlenet"] + (bn * 2 if op == "dup" else [])
json.dump(d, open(f, "w"), indent=2)
PY
}

mk_tree() {
  local t=$1 h=$1/home p=$1/home/Faugus/battlenet
  local fg=$h/.local/share/faugus-launcher w=$p/drive_c/Program\ Files\ \(x86\)
  local n bi
  mkdir -p "$t/bin" "$t/marks" "$fg" "$h/.config/faugus-launcher" "$p/drive_c/Program Files/W3Champions"
  mkdir -p "$w/Battle.net" "$w/Warcraft III/_retail_/x86_64" "$p/drive_c/users/steamuser/Documents/Warcraft III"
  mkdir -p "$h/.local/share/Steam/compatibilitytools.d"
  printf '1\n' > "$t/ptrace_scope"
  for n in python3 realpath md5sum awk grep sed sha256sum tar find sort head; do add_link "$t" "$n"; done
  for n in wine wineserver faugus-launcher steam-runtime-launch-client pkill pgrep sudo; do add_shim "$t" "$n"; done
  # doctor's one allowed network call is the latest.json GET: a fixture shim logs every call and serves only that file
  cat > "$t/bin/curl" <<'SH'
#!/bin/sh
printf '%s\n' "$0 $*" >> "$MARK/curl"
for a in "$@"; do
  case $a in */latest.json)
    printf '%s\n' '{"version": "1.6.16", "notes": "", "pub_date": "2026-10-08T10:10:26Z", "platforms": {"windows-x86_64-msi": {"signature": "sig", "url": "https://github.com/w3champions/launcher-e-release/releases/download/1.6.16/W3Champions_1.6.16_x64_en-US.msi"}}}'
    exit 0 ;;
  esac
done
exit 22
SH
  chmod +x "$t/bin/curl"
  python3 - "$fg/games.json" "$p" <<'PY'
import json, sys
f, p = sys.argv[1:3]
json.dump([
    {"gameid": "other", "title": "Other", "prefix": "/nonexistent/other", "runner": "GE-Proton",
     "launch_arguments": "", "path": "/nonexistent/other.exe"},
    {"gameid": "battlenet", "title": "Battle.net", "prefix": p, "runner": "Proton-GE Latest",
     "launch_arguments": "WINE_SIMULATE_WRITECOPY=1 PROTON_ENABLE_WAYLAND=0",
     "path": p + "/drive_c/Program Files (x86)/Battle.net/Battle.net.exe"},
], open(f, "w"), indent=2)
PY
  write_shim "$fg/umu-run" umu-run
  printf '1.4.4-patch' > "$fg/version.txt"
  # the seam W3C_FAUGUS_PY_DIR points here, so no doctor row depends on the host's Faugus install
  mkdir -p "$t/faugus-py/faugus"
  printf '%s\n' '# fixture launcher' 'import os' 'VERSION = "2.4.2"' > "$t/faugus-py/faugus/launcher.py"
  printf '%s\n' '{"wayland-driver": "False", "wow64-enabled": "False", "discrete-gpu": "False"}' > "$h/.config/faugus-launcher/config.json"
  printf '%s\n' '[]' > "$h/.config/faugus-launcher/envar.json"
  cat > "$p/system.reg" <<'REG'
WINE REGISTRY Version 2

[Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Warcraft III] 1700000000
"DisplayName"="Warcraft III"
"InstallLocation"="C:\\Program Files (x86)\\Warcraft III"

[Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Other] 1700000001
"InstallLocation"="C:\\Other"

REG
  : > "$w/Battle.net/Battle.net.exe"
  : > "$w/Warcraft III/_retail_/x86_64/Warcraft III.exe"
  printf '%s\n' 'Branch!STRING:0|Active!DEC:1|Build Key!HEX:16|CDN Key!HEX:16|Install Key!HEX:16|IM Size!DEC:4|CDN Path!STRING:0|CDN Hosts!STRING:0|CDN Servers!STRING:0|Tags!STRING:0|Armadillo!STRING:0|Last Activated!STRING:0|Version!STRING:0|KeyRing!HEX:16|Product!STRING:0' > "$w/Warcraft III/.build.info"
  bi=(eu 1 '' '' '' '' '' '' '' '' '' '' 3.0.0.24268 abcd w3)
  ( IFS='|'; printf '%s\n' "${bi[*]}" ) >> "$w/Warcraft III/.build.info"
  write_shim "$h/.local/share/umu/steamrt4/pressure-vessel/bin/steam-runtime-launch-client" steam-runtime-launch-client
}

# ---------- run and invariants ----------

snap() {
  find "$1" -path "$1/marks" -prune -o -printf '%p\t%y\t%m\t%s\t%T@\t%l\n' | LC_ALL=C sort
  find "$1" -path "$1/marks" -prune -o -type f -exec sha256sum {} + | LC_ALL=C sort
}

# run T ARGS...: the real entry point under env -i; sets OUT ERR RC; enforces the snapshot and marker invariants.
run() {
  local t=$1 before after n outf=$TMPROOT/out errf=$TMPROOT/err
  shift
  # W3C_SYS_ROOT is a path that never exists, so the suite never reads the host's /usr (a maintainer with the package installed has
  # /usr/share/applications/w3c-linux.desktop); a case's own W3C_SYS_ROOT in CASE_ENV overrides it
  before=$(snap "$t")
  if [ "${FEED+set}" = set ]; then
    printf '%s' "$FEED" | env -i HOME="$t/home" PATH="$t/bin" MARK="$t/marks" W3C_PTRACE_SCOPE_FILE="$t/ptrace_scope" W3C_FAUGUS_PY_DIR="$t/faugus-py" \
      W3C_SYS_ROOT="$t/sysroot" "${CASE_ENV[@]}" "$BASH_BIN" "$SCRIPT" "$@" > "$outf" 2> "$errf"
  else
    env -i HOME="$t/home" PATH="$t/bin" MARK="$t/marks" W3C_PTRACE_SCOPE_FILE="$t/ptrace_scope" W3C_FAUGUS_PY_DIR="$t/faugus-py" \
      W3C_SYS_ROOT="$t/sysroot" "${CASE_ENV[@]}" "$BASH_BIN" "$SCRIPT" "$@" < /dev/null > "$outf" 2> "$errf"
  fi
  RC=$?
  OUT=$(< "$outf")
  ERR=$(< "$errf")
  after=$(snap "$t")
  [ "$before" = "$after" ] || ERRS+=("tree under the case root changed during: $*")
  for n in "${FORBIDDEN[@]}"; do
    [ -e "$t/marks/$n" ] && ERRS+=("forbidden command ran: $n")
  done
  if [ -e "$t/marks/curl" ] && grep -qv 'latest\.json' "$t/marks/curl"; then
    ERRS+=('curl ran for something other than latest.json')
  fi
  return 0
}

# ---------- assertions ----------

line() { printf '%s  %-16s  %s' "$1" "$2" "$3"; }
has_line() {
  local want
  want=$(line "$1" "$2" "$3")
  grep -qxF -- "$want" <<< "$OUT" || ERRS+=("missing line: [$want]")
}
values_are() {
  local want=$1 ln lab got=() i
  shift
  while IFS= read -r ln; do
    lab=${ln:6:16}
    lab=${lab%"${lab##*[![:space:]]}"}
    [ "$lab" = "$want" ] && got+=("${ln:24}")
  done <<< "$OUT"
  if [ "${#got[@]}" -ne "$#" ]; then
    ERRS+=("values of $want: want $# got ${#got[@]} [${got[*]-}]")
    return 0
  fi
  for ((i = 0; i < $#; i++)); do
    [ "${got[i]}" = "${*:i+1:1}" ] || ERRS+=("value $i of $want: want [${*:i+1:1}] got [${got[i]}]")
  done
}
# labels_in_order L...: of all OUT labels, those named in the list appear in exactly that order.
labels_in_order() {
  local ln lab seen='' want=" $* "
  while IFS= read -r ln; do
    lab=${ln:6:16}
    lab=${lab%"${lab##*[![:space:]]}"}
    case $want in *" $lab "*) seen+="$lab " ;; esac
  done <<< "$OUT"
  [ "$seen" = "$* " ] || ERRS+=("label order: want [$*] seen [${seen% }]")
}
lacks_text() { case $OUT in *"$1"*) ERRS+=("output unexpectedly has: $1") ;; esac; }
out_has() { case $OUT in *"$1"*) ;; *) ERRS+=("output lacks: $1") ;; esac; }
err_has() { case $ERR in *"$1"*) ;; *) ERRS+=("stderr lacks: $1") ;; esac; }
rc_is() { [ "$RC" = "$1" ] || ERRS+=("exit code: want $1 got $RC"); }

# ---------- cases ----------

t_entry_healthy() {
  local p=$T/home/Faugus/battlenet appid
  run "$T" doctor
  rc_is 0
  has_line pass games.json "$T/home/.local/share/faugus-launcher/games.json"
  has_line pass battlenet found
  has_line pass prefix "$p"
  has_line pass runner 'Proton-GE Latest'
  has_line pass launch_arguments 'WINE_SIMULATE_WRITECOPY=1 PROTON_ENABLE_WAYLAND=0'
  has_line pass path "$p/drive_c/Program Files (x86)/Battle.net/Battle.net.exe"
  appid=$(printf %s "$(realpath "$p")" | md5sum)
  has_line pass PREFIX "$(realpath "$p")"
  has_line pass APPID "${appid%% *}"
  has_line pass W3C_EXE "$(realpath "$p")/drive_c/Program Files/W3Champions/W3Champions.exe"
  has_line pass launch-client "present: $T/home/.local/share/umu/steamrt4/pressure-vessel/bin/steam-runtime-launch-client"
  values_are 'launch env' WINE_SIMULATE_WRITECOPY=1 PROTON_ENABLE_WAYLAND=0
  OUT=$(sed '/^[a-z]*  w3c build/,$d' <<< "$OUT")   # the Phase 2 rows come after 'launch env'; 'prefix runner' would read as two labels here
  labels_in_order games.json battlenet prefix runner launch_arguments path PREFIX APPID W3C_EXE launch-client
}

t_gamesjson_missing() {
  rm "$T/home/.local/share/faugus-launcher/games.json"
  run "$T" doctor
  rc_is 1
  has_line fail games.json 'Install Faugus and add Battle.net (Add game -> Battle.net)'
  has_line skip battlenet 'needs: games.json'
  has_line skip prefix 'needs: games.json'
}

t_gamesjson_config_fallback() {
  local d=$T/home/.config/faugus-launcher
  mv "$T/home/.local/share/faugus-launcher/games.json" "$d/games.json"
  run "$T" doctor
  rc_is 0
  has_line pass games.json "$d/games.json"
}

t_gamesjson_both() {
  cp "$T/home/.local/share/faugus-launcher/games.json" "$T/home/.config/faugus-launcher/games.json"
  run "$T" doctor
  rc_is 0
  has_line pass games.json "$T/home/.local/share/faugus-launcher/games.json"
}

t_gamesjson_xdg() {
  mkdir "$T/xdg-data"
  mv "$T/home/.local/share/faugus-launcher" "$T/xdg-data/faugus-launcher"
  CASE_ENV=("XDG_DATA_HOME=$T/xdg-data")
  run "$T" doctor
  rc_is 0
  has_line pass games.json "$T/xdg-data/faugus-launcher/games.json"
}

t_gamesjson_flatpak_only() {
  local f=$T/home/.var/app/io.github.Faugus.faugus-launcher/data/faugus-launcher
  mkdir -p "$f"
  mv "$T/home/.local/share/faugus-launcher/games.json" "$f/games.json"
  run "$T" doctor
  rc_is 1
  has_line fail games.json "Flatpak Faugus is unsupported: a host-side wrapper cannot re-enter the Flatpak sandbox's container ($f/games.json)"
  has_line skip battlenet 'needs: games.json'
}

t_gamesjson_native_and_flatpak() {
  local f=$T/home/.var/app/io.github.Faugus.faugus-launcher/data/faugus-launcher
  mkdir -p "$f"
  cp "$T/home/.local/share/faugus-launcher/games.json" "$f/games.json"
  run "$T" doctor
  rc_is 0
  has_line pass games.json "$T/home/.local/share/faugus-launcher/games.json"
  lacks_text Flatpak
}

t_gamesjson_invalid() {
  local g=$T/home/.local/share/faugus-launcher/games.json
  printf '%s' '{not json' > "$g"
  run "$T" doctor
  rc_is 1
  has_line fail games.json "games.json unreadable: $g"
  has_line skip battlenet 'needs: games.json'
}

t_gamesjson_not_list() {
  local g=$T/home/.local/share/faugus-launcher/games.json
  printf '%s' '{}' > "$g"
  run "$T" doctor
  rc_is 1
  has_line fail games.json "games.json unreadable: $g"
  has_line skip battlenet 'needs: games.json'
}

t_entry_none() {
  bn_op "$T" del
  run "$T" doctor
  rc_is 1
  has_line fail battlenet 'no Battle.net in Faugus'
  has_line skip runner 'needs: battlenet entry'
  has_line skip PREFIX 'needs: battlenet entry'
}

t_entry_duplicate() {
  bn_op "$T" dup
  run "$T" doctor
  rc_is 1
  has_line fail battlenet 'games.json has 2 entries with gameid battlenet; remove the duplicate in Faugus'
  has_line skip prefix 'needs: battlenet entry'
}

t_entry_verbatim() {
  bn_set "$T" runner 'My  Runner (x)'
  bn_set "$T" launch_arguments 'A=1  B="two words"'
  run "$T" doctor
  rc_is 0
  has_line pass runner 'My  Runner (x)'
  has_line pass launch_arguments 'A=1  B="two words"'
  values_are 'launch env' A=1 'B=two words'
}

t_entry_empty_prefix() {
  bn_set "$T" prefix ''
  run "$T" doctor
  rc_is 1
  has_line fail prefix 'Battle.net entry has no prefix'
  has_line skip PREFIX 'needs: prefix'
  has_line pass runner 'Proton-GE Latest'
}

# mk_symlink_prefix T: the prefix becomes a symlink to a target whose path contains a space.
mk_symlink_prefix() {
  mkdir "$1/ext dir"
  mv "$1/home/Faugus/battlenet" "$1/ext dir/battlenet"
  ln -s "$1/ext dir/battlenet" "$1/home/Faugus/battlenet"
}

t_entry_symlink_space() {
  local tgt="$T/ext dir/battlenet" real appid
  mk_symlink_prefix "$T"
  real=$(realpath "$tgt")
  appid=$(printf %s "$real" | md5sum)
  run "$T" doctor
  rc_is 0
  has_line pass PREFIX "$real"
  has_line pass APPID "${appid%% *}"
  has_line pass W3C_EXE "$real/drive_c/Program Files/W3Champions/W3Champions.exe"
}

t_entry_launch_client_absent() {
  local f=$T/home/.local/share/umu/steamrt4/pressure-vessel/bin/steam-runtime-launch-client
  rm "$f"
  run "$T" doctor
  rc_is 0
  has_line warn launch-client "absent: $f (umu downloads it the first time Faugus launches a game; launch Battle.net once in Faugus)"
}

t_entry_appid_no_md5sum() {
  rm "$T/bin/md5sum"
  run "$T" doctor
  has_line skip APPID 'needs: md5sum'
}

t_entry_launch_env() {
  bn_set "$T" launch_arguments 'A="x y" gamemoderun 1B=2 C=3'
  run "$T" doctor
  rc_is 0
  has_line pass launch_arguments 'A="x y" gamemoderun 1B=2 C=3'
  values_are 'launch env' 'A=x y' C=3
}

t_entry_expand() {
  # shellcheck disable=SC2088,SC2016 # the tilde and $HOME are stored literally in games.json on purpose
  local tilde='~/Faugus/battlenet' dollar='D=$HOME/x'
  bn_set "$T" prefix "$tilde"
  bn_set "$T" launch_arguments "$dollar"
  run "$T" doctor
  rc_is 0
  has_line pass prefix "$tilde"
  has_line pass PREFIX "$(realpath "$T/home/Faugus/battlenet")"
  has_line pass launch_arguments "$dollar"
  values_are 'launch env' "D=$T/home/x"
}

t_entry_badargs() {
  bn_set "$T" launch_arguments 'A="x'
  run "$T" doctor
  rc_is 0
  has_line warn 'launch env' 'launch_arguments has an unbalanced quote; no env taken from it'
}

# ---------- umu, prefix and wc3 cases ----------

# reg_set T LOCATION_LINE: system.reg with the Warcraft III section holding LOCATION_LINE (may be empty), then an unrelated section.
reg_set() {
  {
    printf 'WINE REGISTRY Version 2\n\n'
    printf '[Software\\\\Wow6432Node\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Uninstall\\\\Warcraft III] 1700000000\n"DisplayName"="Warcraft III"\n'
    [ -z "$2" ] || printf '%s\n' "$2"
    printf '\n[Software\\\\Wow6432Node\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Uninstall\\\\Other] 1700000001\n'
    printf '%s\n\n' "${3:-\"InstallLocation\"=\"C:\\\\Other\"}"
  } > "$1/home/Faugus/battlenet/system.reg"
}

t_umu_healthy() {
  run "$T" doctor
  rc_is 0
  has_line pass umu-run "$T/home/.local/share/faugus-launcher/umu-run"
  has_line pass 'umu version' 1.4.4-patch
}

t_umu_missing() {
  rm "$T/home/.local/share/faugus-launcher/umu-run"
  run "$T" doctor
  rc_is 1
  has_line fail umu-run 'Launch any game once in Faugus so it downloads umu-run'
  has_line skip 'umu version' 'needs: umu-run'
}

t_umu_not_executable() {
  local u=$T/home/.local/share/faugus-launcher/umu-run
  chmod -x "$u"
  run "$T" doctor
  rc_is 1
  has_line fail umu-run "not executable: $u"
}

t_umu_no_version() {
  rm "$T/home/.local/share/faugus-launcher/version.txt"
  run "$T" doctor
  rc_is 0
  has_line warn 'umu version' unknown
}

# fv_launcher T TEXT: rewrites the fixture's faugus/launcher.py to the one line TEXT.
fv_launcher() { printf '%s\n' "$2" > "$1/faugus-py/faugus/launcher.py"; }

t_fv_pass() {
  run "$T" doctor
  rc_is 0
  has_line pass 'faugus version' 2.4.2
  labels_in_order version 'faugus version' games.json
}

t_fv_untested() {
  fv_launcher "$T" 'VERSION = "3.0.1"'
  run "$T" doctor
  rc_is 0
  has_line warn 'faugus version' 'untested Faugus major 3: games.json/envar.json format may differ'
}

t_fv_unknown() {
  CASE_ENV=("W3C_FAUGUS_PY_DIR=$T/nofaugus")
  run "$T" doctor
  has_line warn 'faugus version' unknown
  CASE_ENV=()
  fv_launcher "$T" 'VERSION = "abc"'
  run "$T" doctor
  has_line warn 'faugus version' unknown
}

# the pacman fallback: no readable package, so the version comes from pacman -Q faugus-launcher
t_fv_pacman() {
  CASE_ENV=("W3C_FAUGUS_PY_DIR=$T/nofaugus")
  cat > "$T/bin/pacman" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$MARK/pacman"
[ "$*" = '-Q faugus-launcher' ] || exit 1
printf 'faugus-launcher 2.4.2-1\n'
SH
  chmod +x "$T/bin/pacman"
  run "$T" doctor
  has_line pass 'faugus version' 2.4.2
  [ "$(cat "$T/marks/pacman" 2> /dev/null)" = '-Q faugus-launcher' ] || ERRS+=('pacman was not called exactly once with -Q faugus-launcher')
}

t_prefix_no_sysreg() {
  local p
  p=$(realpath "$T/home/Faugus/battlenet")
  rm "$p/system.reg"
  run "$T" doctor
  rc_is 1
  has_line fail system.reg "Battle.net not installed in that prefix (missing $p/system.reg)"
  has_line pass 'wc3 dir' "$p/drive_c/Program Files (x86)/Warcraft III"
}

t_prefix_no_bnet_exe() {
  local p
  p=$(realpath "$T/home/Faugus/battlenet")
  rm "$p/drive_c/Program Files (x86)/Battle.net/Battle.net.exe"
  run "$T" doctor
  rc_is 1
  has_line fail Battle.net.exe "Battle.net not installed in that prefix (missing $p/drive_c/Program Files (x86)/Battle.net/Battle.net.exe)"
}

t_wc3_healthy() {
  local p
  p=$(realpath "$T/home/Faugus/battlenet")
  run "$T" doctor
  rc_is 0
  has_line pass system.reg "$p/system.reg"
  has_line pass Battle.net.exe "$p/drive_c/Program Files (x86)/Battle.net/Battle.net.exe"
  has_line pass 'wc3 dir' "$p/drive_c/Program Files (x86)/Warcraft III"
  has_line pass 'wc3 exe' "$p/drive_c/Program Files (x86)/Warcraft III/_retail_/x86_64/Warcraft III.exe"
  has_line pass 'wc3 build' 3.0.0.24268
  has_line pass 'wc3 user data' "$p/drive_c/users/steamuser/Documents/Warcraft III"
}

t_wc3_installlocation() {
  local p
  p=$(realpath "$T/home/Faugus/battlenet")
  mkdir -p "$p/drive_c/Games"
  mv "$p/drive_c/Program Files (x86)/Warcraft III" "$p/drive_c/Games/Warcraft III"
  reg_set "$T" '"InstallLocation"="C:\\Games\\Warcraft III"'
  run "$T" doctor
  rc_is 0
  has_line pass 'wc3 dir' "$p/drive_c/Games/Warcraft III"
}

t_wc3_fallback_nokey() {
  local p
  p=$(realpath "$T/home/Faugus/battlenet")
  printf 'WINE REGISTRY Version 2\n\n' > "$p/system.reg"
  run "$T" doctor
  rc_is 0
  has_line pass 'wc3 dir' "$p/drive_c/Program Files (x86)/Warcraft III"
}

t_wc3_fallback_missingdir() {
  local p
  p=$(realpath "$T/home/Faugus/battlenet")
  reg_set "$T" '"InstallLocation"="C:\\Nowhere\\Warcraft III"'
  run "$T" doctor
  rc_is 0
  has_line pass 'wc3 dir' "$p/drive_c/Program Files (x86)/Warcraft III"
}

t_wc3_next_key_guard() {
  local p g
  p=$(realpath "$T/home/Faugus/battlenet")
  g="$p/drive_c/Games/Warcraft III/_retail_/x86_64"
  mkdir -p "$g"
  : > "$g/Warcraft III.exe"
  reg_set "$T" '' '"InstallLocation"="C:\\Games\\Warcraft III"'
  run "$T" doctor
  rc_is 0
  has_line pass 'wc3 dir' "$p/drive_c/Program Files (x86)/Warcraft III"
}

t_wc3_no_exe() {
  rm "$T/home/Faugus/battlenet/drive_c/Program Files (x86)/Warcraft III/_retail_/x86_64/Warcraft III.exe"
  run "$T" doctor
  rc_is 1
  has_line fail 'wc3 exe' 'Install Warcraft III from Battle.net, start it once, then rerun'
  has_line skip 'wc3 build' 'needs: Warcraft III.exe'
}

t_wc3_build_two_rows() {
  local binfo="$T/home/Faugus/battlenet/drive_c/Program Files (x86)/Warcraft III/.build.info"
  { sed -n 1p "$binfo"; printf '%s\n' 'eu|0|||||||||||2.0.0.1|abcd|w3'; sed -n 2p "$binfo"; } > "$binfo.new"
  mv "$binfo.new" "$binfo"
  run "$T" doctor
  rc_is 0
  has_line pass 'wc3 build' 3.0.0.24268
}

t_wc3_build_productdb() {
  local d="$T/home/Faugus/battlenet/drive_c/Program Files (x86)/Warcraft III"
  rm "$d/.build.info"
  printf '\001\002\003\000abc 3.0.0.24268R\000\377\376' > "$d/.product.db"
  add_link "$T" strings
  run "$T" doctor
  rc_is 0
  has_line pass 'wc3 build' 3.0.0.24268
}

t_wc3_build_unknown() {
  rm "$T/home/Faugus/battlenet/drive_c/Program Files (x86)/Warcraft III/.build.info"
  run "$T" doctor
  rc_is 0
  has_line warn 'wc3 build' unknown
}

t_wc3_no_userdata() {
  local ud w
  ud=$(realpath "$T/home/Faugus/battlenet")/drive_c/users/steamuser/Documents/Warcraft\ III
  rmdir "$ud"
  run "$T" doctor
  rc_is 0
  out_has 'start Warcraft III once from Battle.net'
  out_has 'refuses to start without it'
  # the Phase 2 rows (w3c build, runner build, prefix version) warn on a tree that never ran Battle.net on the patched build
  w=$(grep '^warn' <<< "$OUT" | grep -vE '^warn  (w3c build|runner build|prefix version|webview2|webview2 winver|local files|windows version|launcher|launcher version|desktop entry) ')
  [ "$(grep -c '^warn' <<< "$w")" = 1 ] || ERRS+=("want exactly one warn line, got: $w")
}

# ---------- host and env cases ----------

# cfg_set T JSON / envar_set T JSON: write the Faugus config files literally.
cfg_set() { printf '%s\n' "$2" > "$1/home/.config/faugus-launcher/config.json"; }
envar_set() { printf '%s\n' "$2" > "$1/home/.config/faugus-launcher/envar.json"; }

t_host_required_missing() {
  rm "$T/bin/tar" "$T/bin/md5sum"
  run "$T" doctor
  rc_is 1
  values_are 'required tools' 'missing: tar md5sum (install them with your package manager; needs root)'
}

t_host_optional_absent() {
  run "$T" doctor
  rc_is 0
  values_are 'optional tool' 'zenity absent' 'nft absent' 'iptables absent' 'sudo present' 'notify-send absent'
  values_are 'required tools' 'curl python3 sha256sum tar md5sum pgrep'
}

t_host_optional_present() {
  local n
  for n in zenity nft iptables notify-send; do add_shim "$T" "$n"; done
  run "$T" doctor
  rc_is 0
  values_are 'optional tool' 'zenity present' 'nft present' 'iptables present' 'sudo present' 'notify-send present'
  [ -e "$T/marks/zenity" ] && ERRS+=('zenity ran')
}

t_host_ptrace() {
  local v
  for v in 0 1; do
    printf '%s\n' "$v" > "$T/ptrace_scope"
    run "$T" doctor
    rc_is 0
    has_line pass ptrace_scope "$v"
  done
  for v in 2 3; do
    printf '%s\n' "$v" > "$T/ptrace_scope"
    run "$T" doctor
    rc_is 1
    out_has 'ReadProcessMemory'
    out_has 'wineserver'
  done
  printf 'x\n' > "$T/ptrace_scope"
  run "$T" doctor
  rc_is 0
  has_line warn ptrace_scope 'unexpected value: x'
  CASE_ENV=("W3C_PTRACE_SCOPE_FILE=$T/nope")
  run "$T" doctor
  rc_is 0
  has_line pass ptrace_scope "absent ($T/nope)"
}

t_host_compat() {
  local c=$T/home/.local/share/Steam/compatibilitytools.d
  run "$T" doctor
  has_line pass 'compat tools' "present: $c"
  rmdir "$c"
  run "$T" doctor
  rc_is 0
  has_line pass 'compat tools' "absent: $c"
  [ ! -e "$c" ] || ERRS+=('compatibilitytools.d was created')
}

t_env_override() {
  cfg_set "$T" '{"wayland-driver": "True"}'
  envar_set "$T" '["PROTON_ENABLE_WAYLAND=0","X=1","X=2"]'
  run "$T" doctor
  rc_is 0
  values_are 'faugus env' 'PROTON_ENABLE_WAYLAND=0' 'X=2'
}

t_env_empty() {
  local c=$T/home/.config/faugus-launcher
  run "$T" doctor
  rc_is 0
  values_are 'faugus env' '(none)'
  has_line pass envar.json "$c/envar.json"
  rm "$c/envar.json"
  run "$T" doctor
  rc_is 0
  values_are 'faugus env' '(none)'
  has_line pass envar.json "absent: $c/envar.json"
  rm "$c/config.json"
  run "$T" doctor
  rc_is 0
  values_are 'faugus env' '(none)'
  has_line pass config.json "absent: $c/config.json"
  lacks_text 'fail '
}

t_env_skip_invalid() {
  envar_set "$T" '["", "NOEQUALS", "=x", 5, " Y = 3 "]'
  run "$T" doctor
  rc_is 0
  values_are 'faugus env' 'Y=3'
}

t_env_bytes() {
  # shellcheck disable=SC2016 # $HOME must stay literal: the value is never expanded
  envar_set "$T" '["FOO=a b $HOME \"q\""]'
  run "$T" doctor
  rc_is 0
  # shellcheck disable=SC2016
  has_line pass 'faugus env' 'FOO=a b $HOME "q"'
}

t_env_toggle_exact() {
  cfg_set "$T" '{"discrete-gpu": "True", "wow64-enabled": "True", "wayland-driver": "true"}'
  run "$T" doctor
  rc_is 0
  values_are 'faugus env' 'DRI_PRIME=1' 'PROTON_USE_WOW64=1'
  cfg_set "$T" '{"discrete-gpu": "1", "wow64-enabled": "False", "wayland-driver": true}'
  run "$T" doctor
  rc_is 0
  values_are 'faugus env' '(none)'
}

t_env_dup_position() {
  envar_set "$T" '["X=1","Y=1","X=2"]'
  run "$T" doctor
  values_are 'faugus env' 'Y=1' 'X=2'
}

t_env_garbage() {
  local c=$T/home/.config/faugus-launcher
  printf 'not json' > "$c/config.json"
  envar_set "$T" '{"a": 1}'
  run "$T" doctor
  rc_is 0
  has_line warn config.json "unreadable, toggles off: $c/config.json"
  has_line warn envar.json "unreadable, no entries used: $c/envar.json"
  values_are 'faugus env' '(none)'
}

t_env_order() {
  local last first
  cfg_set "$T" '{"discrete-gpu": "True"}'
  envar_set "$T" '["A=1"]'
  run "$T" doctor
  rc_is 0
  values_are 'faugus env' 'DRI_PRIME=1' 'A=1'
  last=$(grep -n '  faugus env  ' <<< "$OUT" | tail -n1)
  first=$(grep -n '  launch env  ' <<< "$OUT" | head -n1)
  [ -n "$last" ] && [ -n "$first" ] && [ "${last%%:*}" -lt "${first%%:*}" ] || ERRS+=("faugus env lines not all before launch env: [$last] [$first]")
}

t_dispatch_monitor_no_prefix() {
  rm "$T/home/.local/share/faugus-launcher/games.json"
  run "$T" monitor
  rc_is 1
  err_has 'monitor: cannot find'
  [ -z "$OUT" ] || ERRS+=("stdout is not empty: $OUT")
}

t_dispatch_unknown() {
  local s
  run "$T" bogus
  rc_is 2
  for s in install launch update doctor revert monitor report; do err_has "$s"; done
}

t_shim_selftest() {
  local n
  for n in wine wineserver faugus-launcher steam-runtime-launch-client pkill curl pgrep sudo; do
    env -i PATH="$T/bin" MARK="$T/marks" "$T/bin/$n" probe
    [ -s "$T/marks/$n" ] || ERRS+=("shim $n wrote no marker")
    rm -f "$T/marks/$n"
  done
  env -i PATH="$T/bin" MARK="$T/marks" "$T/home/.local/share/faugus-launcher/umu-run" probe
  [ -s "$T/marks/umu-run" ] || ERRS+=("fake umu-run wrote no marker")
  env -i PATH="$T/bin" MARK="$T/marks" "$T/home/.local/share/umu/steamrt4/pressure-vessel/bin/steam-runtime-launch-client" probe
  [ -s "$T/marks/steam-runtime-launch-client" ] || ERRS+=("fake launch client wrote no marker")
}

t_static_shellcheck() {
  local o
  if ! type -P shellcheck > /dev/null; then
    ERRS+=('shellcheck missing; install it with: sudo pacman -S shellcheck')
    return 0
  fi
  o=$(shellcheck -x "$SCRIPT" "$ROOT"/lib/*.sh "$ROOT/tests/phase1.sh" "$ROOT/tests/phase2.sh" "$ROOT/tests/phase3.sh" "$ROOT/tests/phase4.sh" "$ROOT/tests/phase5.sh" 2>&1) || ERRS+=("shellcheck findings: $o")
}

t_static_no_eval() {
  local o
  o=$(grep -nw eval "${SOURCES[@]}")
  [ -z "$o" ] || ERRS+=("script contains the word eval: $o")
}

# The Python parsers live in lib/w3c_helper.py: no shell source embeds Python or runs python3 without the helper.
t_static_python_helper() {
  local o p sh=("$SCRIPT" "$ROOT"/lib/*.sh)
  [ -f "$ROOT/lib/w3c_helper.py" ] || ERRS+=('lib/w3c_helper.py is missing')
  o=$(grep -nvE '^[[:space:]]*#' "${sh[@]}" | grep -E "<<-?[[:space:]]*['\"]?PY|python3 .* -c( |\$)")
  [ -z "$o" ] || ERRS+=("script embeds Python or runs python3 -c: $o")
  # shellcheck disable=SC2016 # the literal text of the wrapper line
  p=$(grep -nvE '^[[:space:]]*#' "${sh[@]}" | grep -E 'python3 -I' | grep -vF 'python3 -I -B "$HELPER" ')
  [ -z "$p" ] || ERRS+=("python3 -I call that does not run the helper: $p")
}

# Faugus is isolated: no shell source but lib/faugus.sh locates or reads a Faugus file, calls a Faugus helper or runs a Faugus process
# operation, and the contract reads inside lib/faugus.sh sit in faugus_backend. Prose that only names games.json in a message is allowed.
t_static_faugus_isolation() {
  local re o n inside outside others=("$SCRIPT") f
  for f in "$ROOT"/lib/*.sh; do [ "$f" = "$ROOT/lib/faugus.sh" ] || others+=("$f"); done
  # shellcheck disable=SC2016 # the literal text of the script's lines
  re='\b(GAMES_JSON|RUNNING_GAMES|FLATPAK_JSON|DATA_HOME|CONFIG_HOME|FAUGUS_PY_DIR|py_entry|py_env|py_games|py_faugus_version)\b|faugus-launcher/|faugus-launcher --game|type -P faugus-launcher|version\.txt|config\.json|envar\.json|running-games|pacman -Q|faugus\\\.|"\$HELPER" (entry|env|games|faugus-version)'
  o=$(grep -nvE '^[[:space:]]*#' "${others[@]}" | grep -E "$re")
  [ -z "$o" ] || ERRS+=("Faugus code outside lib/faugus.sh: $o")
  # not vacuous: the pattern matches code in lib/faugus.sh, which the entry sources
  grep -vE '^[[:space:]]*#' "$ROOT/lib/faugus.sh" | grep -qE "$re" || ERRS+=('the isolation pattern matches nothing in lib/faugus.sh')
  grep -qF 'LIB_DIR/faugus.sh' "$SCRIPT" || ERRS+=('w3c-linux.sh does not source lib/faugus.sh')
  # one reader: faugus_backend is defined once and is the only function that calls the contract readers
  n=$(grep -c '^faugus_backend() {$' "$ROOT/lib/faugus.sh")
  [ "$n" = 1 ] || ERRS+=("faugus_backend is defined $n times in lib/faugus.sh")
  inside=$(awk '/^[a-z_0-9]+\(\) \{$/ {fn = $1; sub(/\(\).*/, "", fn); next} /^\}$/ {fn = ""; next} /^[[:space:]]*#/ {next} fn == "faugus_backend" && /(^|[^a-z_])(py_entry|py_env|py_faugus_version)([^a-z_]|$)|pacman -Q/' "$ROOT/lib/faugus.sh")
  [ -n "$inside" ] || ERRS+=('faugus_backend calls no contract reader')
  outside=$(awk '/^[a-z_0-9]+\(\) \{$/ {fn = $1; sub(/\(\).*/, "", fn); next} /^\}$/ {fn = ""; next} /^[[:space:]]*#/ {next} fn != "faugus_backend" && /(^|[^a-z_])(py_entry|py_env|py_faugus_version)([^a-z_]|$)|pacman -Q/ {print FNR ": " $0}' "$ROOT/lib/faugus.sh")
  [ -z "$outside" ] || ERRS+=("contract read outside faugus_backend: $outside")
}

# The entry finds lib/ through a symlink and stops with one stderr line when lib/ is absent.
t_lib_layout() {
  local o e r
  run "$T" doctor
  o=$OUT e=$ERR r=$RC
  ln -s "$SCRIPT" "$T/w3c"
  mkdir "$T/solo"
  cp "$SCRIPT" "$T/solo/w3c-linux.sh"
  local SCRIPT=$T/w3c   # run reads SCRIPT dynamically
  run "$T" doctor
  { [ "$OUT" = "$o" ] && [ "$ERR" = "$e" ] && [ "$RC" = "$r" ]; } || ERRS+=("run through a symlink differs from the direct run")
  SCRIPT=$T/solo/w3c-linux.sh
  run "$T" doctor
  rc_is 1
  err_has 'keep the lib directory next to w3c-linux.sh'
  [ -z "$OUT" ] || ERRS+=("stdout is not empty without lib/: $OUT")
  # no vacuous scan: every file the static checks read exists and each subcommand is defined exactly once
  local f c n
  for f in "${SOURCES[@]}"; do [ -f "$f" ] || ERRS+=("SOURCES entry is not a regular file: $f"); done
  for c in doctor install revert update launch monitor report; do
    n=$(cat "${SOURCES[@]}" | grep -cE "^cmd_$c\\(\\) \\{")
    [ "$n" = 1 ] || ERRS+=("cmd_$c is defined $n times across SOURCES")
  done
}

# ---------- install and prompt cases ----------

LATER='arrive in later phases'

# prompt_text: the UX prompt 1 block the healthy fixture must produce on stderr.
prompt_text() {
  printf 'Found Faugus Battle.net:\n\n    prefix %s\n    runner Proton-GE Latest\n    Warcraft III 3.0.0.24268\n    Battle.net present\n\nContinue? [Y/n]' \
    "$(realpath "$T/home/Faugus/battlenet")"
}

# no_pass_lines: quiet pass, so no line of OUT starts with pass or skip.
no_pass_lines() { grep -qE '^(pass|skip)  ' <<< "$OUT" && ERRS+=('install printed a pass or skip line'); return 0; }

t_install_no() {
  FEED=$'n\n'
  run "$T" install
  rc_is 0
  err_has "$(prompt_text)"
  out_has 'Declined; nothing was changed.'
  lacks_text "$LATER"
  no_pass_lines
}

t_fv_install_warn() {
  FEED=$'n\n'
  run "$T" install
  lacks_text 'faugus version'
  fv_launcher "$T" 'VERSION = "3.0.1"'
  FEED=$'n\n'
  run "$T" install
  rc_is 0
  has_line warn 'faugus version' 'untested Faugus major 3: games.json/envar.json format may differ'
  err_has "$(prompt_text)"
  out_has 'Declined; nothing was changed.'
  no_pass_lines
}

t_prompt_answers() {
  local a
  for a in n No; do
    FEED=$a$'\n'
    run "$T" install
    rc_is 0
    out_has 'Declined; nothing was changed.'
  done
}

t_prompt_eof() {
  unset FEED
  run "$T" install
  rc_is 1
  err_has 'no answer (stdin closed); run in a terminal'
  lacks_text "$LATER"
}

t_prompt_zenity_nodisplay() {
  add_shim "$T" zenity 1
  CASE_ENV=(DISPLAY= WAYLAND_DISPLAY=)
  FEED=$'n\n'
  run "$T" install
  rc_is 0
  err_has '[Y/n]'
  [ ! -e "$T/marks/zenity" ] || ERRS+=('zenity ran without a display')
}

t_prompt_zenity_display() {
  local m=$T/marks/zenity
  add_shim "$T" zenity 1
  CASE_ENV=(DISPLAY=:0)
  unset FEED
  run "$T" install
  rc_is 0
  out_has 'Declined'
  if [ -s "$m" ]; then
    grep -qF -- '--question' "$m" || ERRS+=('zenity lacks --question')
    grep -qF -- '--no-markup' "$m" || ERRS+=('zenity lacks --no-markup')
    grep -qF -- 'Found Faugus Battle.net:' "$m" || ERRS+=('zenity lacks the prompt text')
    ! grep -qF -- '--default-cancel' "$m" || ERRS+=('zenity has --default-cancel on a default-Yes question')
  else
    ERRS+=('zenity was not invoked')
  fi
  case $ERR in *'[Y/n]'*) ERRS+=('terminal prompt shown next to zenity') ;; esac
}

t_install_warn_only() {
  rmdir "$T/home/Faugus/battlenet/drive_c/users/steamuser/Documents/Warcraft III"
  FEED=$'n\n'
  run "$T" install
  rc_is 0
  out_has 'warn  wc3 user data'
  err_has 'Continue? [Y/n]'
}

t_install_fail() {
  rm "$T/home/Faugus/battlenet/drive_c/Program Files (x86)/Battle.net/Battle.net.exe"
  FEED=$'y\n'
  run "$T" install
  rc_is 1
  out_has 'fail  Battle.net.exe'
  out_has 'install: fix the failed checks above, then rerun (w3c-linux.sh doctor shows every check)'
  case $ERR in *'Continue?'*) ERRS+=('prompt shown after a fail') ;; esac
}

t_dispatch_noarg() {
  local v l1 l2
  v=$(sed -n 's/^W3C_LINUX_VERSION=//p' "$ROOT/w3c-linux.sh")
  run "$T"
  l1=${OUT%%$'\n'*}
  l2=${OUT#*$'\n'}
  l2=${l2%%$'\n'*}
  { [ "$RC" = 0 ] && [ "$l1" = "w3c-linux $v" ] && [ "$l2" = 'usage: w3c-linux.sh <subcommand>' ]; } || ERRS+=('no-argument run does not print the version and usage')
}

t_static_prompt_default_no() {
  grep -qF '[y/N]' "${SOURCES[@]}" || ERRS+=('script lacks [y/N]')
  grep -qF -e '--default-cancel' "${SOURCES[@]}" || ERRS+=('script lacks --default-cancel')
}

# ---------- doctor-wide, prohibition and static cases ----------

DOCTOR_ORDER=(version 'faugus version' games.json battlenet prefix runner launch_arguments path PREFIX APPID W3C_EXE launch-client umu-run 'umu version'
  system.reg Battle.net.exe 'wc3 dir' 'wc3 exe' 'wc3 build' 'wc3 user data' 'required tools' 'optional tool' ptrace_scope
  'compat tools' config.json envar.json 'faugus env' 'launch env' 'w3c build' 'runner build' 'runner dir' 'prefix version' 'prefix runner'
  webview2 'webview2 winver' 'local files' 'windows version' launcher 'launcher version' 'desktop entry')

# warn_only_tree T: the Warcraft III user-data folder is gone, which is a warn and not a fail.
warn_only_tree() { rmdir "$1/home/Faugus/battlenet/drive_c/users/steamuser/Documents/Warcraft III"; }

t_doctor_repeat() {
  local a
  run "$T" doctor
  a=$OUT
  run "$T" doctor
  [ "$OUT" = "$a" ] || ERRS+=('healthy tree: two doctor runs differ')
  warn_only_tree "$T"
  run "$T" doctor
  a=$OUT
  run "$T" doctor
  [ "$OUT" = "$a" ] || ERRS+=('warn-only tree: two doctor runs differ')
}

t_doctor_format() {
  local bad
  run "$T" doctor
  bad=$(grep -cvE '^(pass|warn|fail|skip)  .{16}  ' <<< "$OUT")
  [ "$bad" = 0 ] || ERRS+=("healthy tree: $bad malformed lines")
  rm -rf "${T:?}/home"
  mkdir "$T/home"
  run "$T" doctor
  bad=$(grep -cvE '^(pass|warn|fail|skip)  .{16}  ' <<< "$OUT")
  [ "$bad" = 0 ] || ERRS+=("empty home: $bad malformed lines")
}

t_doctor_order() {
  local ln lab seen='' prev='' want
  run "$T" doctor
  while IFS= read -r ln; do
    lab=${ln:6:16}
    lab=${lab%"${lab##*[![:space:]]}"}
    [ "$lab" = "$prev" ] || seen+="$lab|"
    prev=$lab
  done <<< "$OUT"
  want=$(printf '%s|' "${DOCTOR_ORDER[@]}")
  [ "$seen" = "$want" ] || ERRS+=("row order: want [$want] got [$seen]")
}

t_doctor_empty_home() {
  local l
  rm -rf "${T:?}/home"
  mkdir "$T/home"
  run "$T" doctor
  rc_is 1
  has_line fail games.json 'Install Faugus and add Battle.net (Add game -> Battle.net)'
  has_line fail umu-run 'Launch any game once in Faugus so it downloads umu-run'
  for l in battlenet prefix runner launch_arguments path PREFIX APPID W3C_EXE system.reg Battle.net.exe 'wc3 dir' 'wc3 exe' \
    'wc3 build' 'wc3 user data' 'launch env'; do
    has_line skip "$l" 'needs: games.json'
  done
  has_line skip 'umu version' 'needs: umu-run'
  has_line warn 'w3c build' 'none recorded: run w3c-linux.sh install'
  for l in 'runner build' 'runner dir' 'prefix version' 'prefix runner' webview2 'webview2 winver' 'local files' 'windows version' launcher 'launcher version'; do
    has_line skip "$l" 'needs: games.json'
  done
  values_are 'faugus env' '(none)'
  [ "$(grep -c '^fail' <<< "$OUT")" = 2 ] || ERRS+=("want exactly two fail lines, got: $(grep '^fail' <<< "$OUT")")
}

t_doctor_exit() {
  warn_only_tree "$T"
  run "$T" doctor
  rc_is 0
  grep -q '^warn' <<< "$OUT" || ERRS+=('warn-only tree printed no warn line')
  rm "$T/home/Faugus/battlenet/drive_c/Program Files (x86)/Battle.net/Battle.net.exe"
  run "$T" doctor
  rc_is 1
}

t_doctor_busy() {
  local a s=$T/home/.local/state/faugus-launcher
  run "$T" doctor
  a=$OUT
  mkdir -p "$s"
  printf '%s\n' '{"battlenet": {"pid": 4242}}' > "$s/running-games.json"
  run "$T" doctor
  rc_is 0
  [ "$OUT" = "$a" ] || ERRS+=('doctor output changed while Battle.net is marked running')
}

t_doctor_color() {
  local cmd o esc=$'\033'
  if ! type -P script > /dev/null; then
    ERRS+=('script (util-linux) missing')
    return 0
  fi
  cmd=$(printf '%q ' env -i HOME="$T/home" PATH="$T/bin" MARK="$T/marks" W3C_PTRACE_SCOPE_FILE="$T/ptrace_scope" "$BASH_BIN" "$SCRIPT" doctor)
  o=$(script -qec "$cmd" /dev/null < /dev/null)
  case $o in *"${esc}[32mpass"*) ;; *) ERRS+=('tty output has no colored pass') ;; esac
  cmd=$(printf '%q ' env -i HOME="$T/home" PATH="$T/bin" MARK="$T/marks" W3C_PTRACE_SCOPE_FILE="$T/ptrace_scope" NO_COLOR=1 "$BASH_BIN" "$SCRIPT" doctor)
  o=$(script -qec "$cmd" /dev/null < /dev/null)
  case $o in *"$esc"*) ERRS+=('NO_COLOR output still has an escape byte') ;; esac
  run "$T" doctor
  case $OUT in *"$esc"*) ERRS+=('piped output has an escape byte') ;; esac
}

# three_runs T: doctor, then install answered n at prompt 1 (Phase 2 installs write by design, so only the decline path stays read-only);
# run enforces the snapshot and marker invariants, which now cover curl and pgrep.
three_runs() {
  run "$1" doctor
  FEED=$'n\n'
  run "$1" install
  rc_is 0
}

t_neg_readonly() {
  rmdir "$T/home/.local/share/Steam/compatibilitytools.d"
  three_runs "$T"
  [ ! -e "$T/home/.local/state/w3c-linux" ] || ERRS+=('state directory was created')
  [ ! -e "$T/home/.local/share/Steam/compatibilitytools.d" ] || ERRS+=('compatibilitytools.d was created')
}

t_neg_readonly_symlink() {
  mk_symlink_prefix "$T"
  three_runs "$T"
  [ ! -e "$T/home/.local/state/w3c-linux" ] || ERRS+=('state directory was created')
}

t_neg_no_forbidden_calls() {
  local m
  three_runs "$T"
  # curl is allowed only for doctor's latest.json GET, which run enforces
  for m in "$T/marks"/*; do
    [ ! -e "$m" ] || [ "${m##*/}" = curl ] || ERRS+=("a command marker exists: ${m##*/}")
  done
}

# That doctor never lists processes or reads Faugus's running state is proven behaviourally: the pgrep marker plus t_doctor_busy.
# Exactly one process-killing line, inside kill_updater, scoped to the user's own processes.
t_static_no_kill() {
  local o n inside
  o=$(grep -nwE 'pkill|killall' "${SOURCES[@]}")
  n=$(cat "${SOURCES[@]}" | grep -cwE 'pkill|killall')
  [ "$n" = 1 ] || ERRS+=("want one process-killing line, got $n: $o")
  inside=$(awk '/^kill_updater\(\) \{$/ {f = 1; next} f && /^\}$/ {f = 0} f' "${SOURCES[@]}" | grep -wE 'pkill|killall')
  [ -n "$inside" ] || ERRS+=('the process-killing line is not inside kill_updater')
  # shellcheck disable=SC2016 # the literal text of the script's line
  case $inside in *'-u "$UID"'*) ;; *) ERRS+=("the kill is not scoped with -u \"\$UID\": $inside") ;; esac
}

t_static_no_home_literal() {
  local o
  o=$(grep -nE '/home/[a-z]' "${SOURCES[@]}")
  [ -z "$o" ] || ERRS+=("script has an absolute home path: $o")
}

# ---------- runner ----------

main() {
  local glob=${1:-*} fn name passed=0 failed=0 selected=0
  for fn in $(compgen -A function t_); do
    name=${fn#t_}
    name=${name//_/-}
    # shellcheck disable=SC2254 # the filter is deliberately a glob pattern
    case $name in $glob) ;; *) continue ;; esac
    selected=$((selected + 1))
    T=$(mktemp -d "$TMPROOT/c.XXXXXX")
    mk_tree "$T"
    CASE_ENV=() ERRS=()
    unset FEED
    "$fn"
    if [ "${#ERRS[@]}" -eq 0 ]; then
      printf 'ok - %s\n' "$name"
      passed=$((passed + 1))
    else
      printf 'not ok - %s: %s\n' "$name" "$(IFS=';'; printf '%s' "${ERRS[*]}")"
      failed=$((failed + 1))
    fi
  done
  printf '# %d passed, %d failed\n' "$passed" "$failed"
  [ "$selected" -gt 0 ] && [ "$failed" -eq 0 ]
}

main "$@"
