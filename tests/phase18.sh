#!/usr/bin/env bash
# Phase 18 fixture check: the Steam backend (finder, doctor rows, backend set steam, the D-15 guard). It runs on the harness of
# tests/phase10.sh, so the same fake HOME, shims and invariants apply; the recorded Phase 16 files in tests/fixtures/steam are laid out the
# way Steam lays them out. No case runs Steam, Wine or a network call.
# Usage: bash tests/phase18.sh [GLOB]   (GLOB filters on display names such as steam-backend-set)
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=phase10.sh
source "$(dirname "${BASH_SOURCE[0]}")/phase10.sh"

# this suite has its own cases only
mapfile -t P10_CASES < <(compgen -A function t_)
unset -f "${P10_CASES[@]}"

# nothing here may start Steam, Wine, Faugus or umu; the shims write a marker file when one runs and the case then fails
FORBIDDEN=(wine wineserver faugus-launcher steam-runtime-launch-client pkill pgrep sudo umu-run nft iptables notify-send steam)

FIX18=$ROOT/tests/fixtures/steam
SR=''   # mk_steam sets it: the realpath of the Steam root
SKIPS='needs: Faugus (backend: steam)'

# ---------- helpers ----------

# mk_steam [ROOT]: the recorded fixtures laid out as Steam does (account 12345678 is the loginusers key 76561197972611406 & 0xFFFFFFFF), the
# Faugus fixture prefix as the shortcut's compatdata prefix, and the W3C build in the root's compatibilitytools.d. Sets SR.
mk_steam() {
  local root=${1:-$T/home/.local/share/Steam}
  mkdir -p "$root/config" "$root/steamapps/compatdata/3389133332" "$root/userdata/12345678/config" "$root/compatibilitytools.d" "$T/home/.steam"
  SR=$(realpath "$root")
  cp "$FIX18/loginusers.vdf" "$root/config/loginusers.vdf"
  cp "$FIX18/shortcuts.vdf" "$root/userdata/12345678/config/shortcuts.vdf"
  # the recorded library path is redacted to a literal Steam path; the finder reads library paths from this file
  sed "s#/home/user/.local/share/Steam#$SR#g" "$FIX18/libraryfolders.vdf" > "$root/steamapps/libraryfolders.vdf"
  {
    printf '"InstallConfigStore"\n{\n"Software"\n{\n"Valve"\n{\n"Steam"\n{\n'
    cat "$FIX18/compat-tool-mapping.vdf"
    printf '}\n}\n}\n}\n'
  } > "$root/config/config.vdf"
  cp -a "$T/home/Faugus/battlenet" "$root/steamapps/compatdata/3389133332/pfx"
  # Steam keeps the prefix version and config_info beside pfx/, not in it (verified on a real compatdata directory)
  printf 'GE-Proton11-7\n' > "$root/steamapps/compatdata/3389133332/version"
  printf 'x\nx\n%s/compatibilitytools.d/%s/files/lib/\n' "$SR" "$TAG" > "$root/steamapps/compatdata/3389133332/config_info"
  fill_build "$SR/compatibilitytools.d/$TAG" "$TAG"
  cp "$FIX18/toolmanifest.vdf" "$SR/compatibilitytools.d/$TAG/toolmanifest.vdf"
  cp "$FIX18/appmanifest_4183110.acf" "$SR/steamapps/appmanifest_4183110.acf"
  seed_tag "$T" "$TAG"
  ln -sfn "$SR" "$T/home/.steam/root"
  ln -sfn "$SR" "$T/home/.steam/steam"
  add_shim "$T" steam
}

# mk_mapping APPID:NAME...: rewrite the root's config.vdf with exactly these CompatToolMapping entries, shaped as the fixture's.
mk_mapping() {
  local e
  {
    printf '"InstallConfigStore"\n{\n"Software"\n{\n"Valve"\n{\n"Steam"\n{\n"CompatToolMapping"\n{\n'
    for e in "$@"; do printf '"%s"\n{\n"name"\t\t"%s"\n"config"\t\t""\n"priority"\t\t"250"\n}\n' "${e%%:*}" "${e#*:}"; done
    printf '}\n}\n}\n}\n}\n'
  } > "$SR/config/config.vdf"
}

# steam_on: the saved backend file says steam.
steam_on() { bf_put BACKEND=steam; }

# mk_users ENTRY...: rewrite the root's loginusers.vdf. An ENTRY is STEAMID64:ACCOUNTNAME or STEAMID64:ACCOUNTNAME:1 (the 1 adds MostRecent);
# every user gets a PersonaName of ACCOUNTNAME and " display", so the privacy assertions have a value to look for.
mk_users() {
  local e id rest name
  {
    printf '"users"\n{\n'
    for e in "$@"; do
      id=${e%%:*} rest=${e#*:} name=${rest%%:*}
      printf '\t"%s"\n\t{\n\t\t"AccountName"\t\t"%s"\n\t\t"PersonaName"\t\t"%s display"\n' "$id" "$name" "$name"
      [ "$rest" = "$name" ] || printf '\t\t"MostRecent"\t\t"1"\n'
      printf '\t}\n'
    done
    printf '}\n'
  } > "$SR/config/loginusers.vdf"
}

# mk_registry NAME: ~/.steam/registry.vdf with AutoLoginUser NAME.
mk_registry() {
  printf '"Registry"\n{\n"HKCU"\n{\n"Software"\n{\n"Valve"\n{\n"Steam"\n{\n"AutoLoginUser"\t\t"%s"\n}\n}\n}\n}\n}\n' "$1" > "$T/home/.steam/registry.vdf"
}

# default_opts [COMMAND]: the default Launch Options string (Phase 20 D-09), with COMMAND as the wrap command: by default the repo script's real
# path, which is what a clone prints. opts_warn PROBLEMS: the text of the warn row for a stored string with those problems.
default_opts() {
  printf 'W3C_SHARED_QUERY=1 WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--no-sandbox PROTON_ENABLE_WAYLAND=0 WINE_SIMULATE_WRITECOPY=1 %s steam-wrap %%command%%' "${1:-$(realpath "$SCRIPT")}"
}
opts_warn() { printf "%s; set the shortcut's Launch Options to: %s" "$1" "$(default_opts)"; }
OPTS_ALL='missing W3C_SHARED_QUERY=1, WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--no-sandbox, PROTON_ENABLE_WAYLAND=0, WINE_SIMULATE_WRITECOPY=1, steam-wrap, %command%'

# sc_edit FILE OP ARGS...: rewrite a binary shortcuts.vdf in place with the parser and encoder of the Phase 16 notes (the root's terminator
# byte included). add NAME APPID EXE copies the entry whose appid is 3389133332 under the next index key; set APPID KEY VALUE sets a key of
# the entry with that appid (an int for appid); noappid APPID drops that entry's appid; badtype turns the first string node's type byte to 0x07.
sc_edit() {
  python3 -I - "$@" <<'PY'
import sys

path, op, args = sys.argv[1], sys.argv[2], sys.argv[3:]
b = open(path, "rb").read()
if op == "badtype":
    i = b.index(b"\x01AppName\0")
    open(path, "wb").write(b[:i] + b"\x07" + b[i + 1:])
    sys.exit(0)


def dec(b):
    pos = 0

    def cstr():
        nonlocal pos
        e = b.index(b"\0", pos)
        s = b[pos:e].decode("utf-8", "surrogateescape")
        pos = e + 1
        return s

    def obj():
        nonlocal pos
        d = {}
        while True:
            t = b[pos]
            pos += 1
            if t == 8:
                return d
            k = cstr()
            if t == 0:
                d[k] = obj()
            elif t == 1:
                d[k] = cstr()
            else:
                d[k] = int.from_bytes(b[pos:pos + 4], "little")
                pos += 4

    return obj()


def enc(d):
    o = b""
    for k, v in d.items():
        kb = k.encode("utf-8", "surrogateescape") + b"\0"
        if isinstance(v, dict):
            o += b"\0" + kb + enc(v)
        elif isinstance(v, int):
            o += b"\2" + kb + v.to_bytes(4, "little")
        else:
            o += b"\1" + kb + v.encode("utf-8", "surrogateescape") + b"\0"
    return o + b"\x08"


root = dec(b)
sc = root["shortcuts"]
if op == "add":
    new = dict(next(e for e in sc.values() if e["appid"] == 3389133332))
    new["AppName"], new["appid"], new["Exe"] = args[0], int(args[1]), args[2]
    sc[str(len(sc))] = new
else:
    e = next(e for e in sc.values() if e["appid"] == int(args[0]))
    if op == "set":
        e[args[1]] = int(args[2]) if args[1] == "appid" else args[2]
    elif op == "noappid":
        del e["appid"]
open(path, "wb").write(enc(root))
PY
}

# nowrite_sh FILE: every line of the shell FILE that could write a file, as "N: line". Comments, quoted strings and the allowed forms
# (> /dev/null, 2> /dev/null, >&N) are removed first; then a remaining > or sed -i, or one of the file-changing words as a whole word, is
# reported. This means lib/steam.sh must not name a variable after one of those words.
nowrite_sh() {
  python3 -I - "$1" <<'PY'
import re
import sys

words = "rm mv cp mkdir rmdir touch tee ln install chmod chown truncate dd mkfifo write_state backend_file_write".split()
word = re.compile(r"(?<![A-Za-z0-9_-])(?:" + "|".join(words) + r")(?![A-Za-z0-9_-])")
for n, line in enumerate(open(sys.argv[1], errors="replace"), 1):
    t = line.rstrip("\n")
    if re.match(r"\s*#", t):
        continue
    t = re.sub(r'"(?:[^"\\]|\\.)*"', '""', t)
    t = re.sub(r"'[^']*'", "''", t)
    t = re.sub(r"(^|\s)#.*", "", t)
    t = re.sub(r"\d?>\s*/dev/null", "", t)
    t = re.sub(r">&\d", "", t)
    if ">" in t or re.search(r"\bsed\s+-\S*i", t) or word.search(t):
        print("%d: %s" % (n, line.rstrip("\n")))
PY
}

# nowrite_py FILE: what the steam_ and vdf_ blocks of the Python FILE do that could write. A block runs from its column-0 header to the next
# column-0 line. The eight blocks must exist (so the scan is not vacuous); across them there is exactly one open(, inside steam_read and in
# mode "rb"; and no os, shutil, tempfile, subprocess or .write( call other than sys.stdout.buffer.write(. The file imports shutil and
# tempfile for other operations, so this scans blocks, not imports.
nowrite_py() {
  python3 -I - "$1" <<'PY'
import re
import sys

blocks = []
for i, line in enumerate(open(sys.argv[1], errors="replace").read().split("\n"), 1):
    if line and not line[0].isspace():
        blocks.append((line, []))
    if blocks:
        blocks[-1][1].append((i, line))
kept = [b for b in blocks if re.match(r"def (steam_|vdf_)", b[0])]
names = {re.match(r"def (\w+)", b[0]).group(1) for b in kept}
for need in "steam_read steam_clean steam_out steam_find steam_tool vdf_binary vdf_text vdf_get".split():
    if need not in names:
        print("no block " + need)
opens = [(i, line, b[0]) for b in kept for i, line in b[1] if re.search(r"\bopen\(", line)]
if len(opens) != 1:
    print("open( appears %d times in the steam_ and vdf_ blocks, want 1" % len(opens))
elif not opens[0][2].startswith("def steam_read(") or '"rb"' not in opens[0][1]:
    print("%d: the one open( is not steam_read's rb: %s" % (opens[0][0], opens[0][1].strip()))
bad = re.compile(r"\bos\.(remove|unlink|rename|replace|mkdir|makedirs|rmdir|chmod|chown|symlink|link|utime|truncate|mkfifo|system|popen)\b|\bshutil\.|\btempfile\.|\bsubprocess\b|\.write\(")
for b in kept:
    for i, line in b[1]:
        if bad.search(line.replace("sys.stdout.buffer.write(", "")):
            print("%d: %s" % (i, line.strip()))
PY
}

# ---------- STEAM-02, STEAM-03: backend set steam, then doctor shows the shortcut ----------

# the tracer: set writes exactly BACKEND=steam (no appid), doctor reads the appid from the binary shortcuts.vdf and writes nothing
t_steam_backend_set() {
  local bf f
  bf=$(BF)
  mk_steam
  bf_allow
  run "$T" backend set steam
  rc_is 0
  out_has "Saved the Steam backend in $bf (Steam root $SR). Next: w3c-linux.sh doctor"
  [ "$(cat "$bf")" = BACKEND=steam ] || ERRS+=("file content: $(tr '\n' '|' < "$bf")")
  for f in "$T"/home/.config/w3c-linux/.backend.*; do
    [ ! -e "$f" ] || ERRS+=("temp file left: $f")
  done
  changed_is home/.config/w3c-linux home/.config/w3c-linux/backend
  run "$T" doctor
  has_line pass 'steam root' "$SR (~/.steam/root)"
  has_line skip games.json "$SKIPS"
  has_line pass shortcut 'Battle.net (appid 3389133332, target W3Champions.exe)'
  changed_is
}

# the exact ST_ERR texts of lib/steam.sh, which `backend set steam` prints after `backend: ` and before ` Nothing was saved.`
NOSTEAM='no native Steam found (~/.steam/root, ~/.steam/steam, ~/.local/share/Steam, ~/.steam/debian-installation): install Steam, start it and sign in once'
FLATPAK='only Flatpak Steam found (~/.var/app/com.valvesoftware.Steam): w3c-linux reads native Steam only; install the native Steam package'
# the usage line of the backend subcommand
BUSAGE='usage: w3c-linux.sh backend set umu PREFIX RUNNER | backend set steam | backend show | backend clear'

# ---------- STEAM-02: selecting, clearing and refusing the Steam backend (D-13) ----------

# clear removes the file and doctor is back on the Faugus rows
t_steam_backend_clear() {
  local bf
  bf=$(BF)
  mk_steam
  bf_allow
  run "$T" backend set steam
  rc_is 0
  run "$T" backend clear
  rc_is 0
  out_has "Removed $bf; the Faugus backend is used unless W3C_PREFIX and W3C_PROTON are set"
  [ ! -e "$bf" ] || ERRS+=('file still there after clear')
  run "$T" doctor
  has_line pass 'faugus version' 2.4.2
}

# no native Steam root: refused, nothing saved. The plain tree has ~/.local/share/Steam with only compatibilitytools.d, which is no Steam
# root; a dangling ~/.steam/root is no root either
t_steam_backend_refuse_none() {
  run "$T" backend set steam
  rc_is 1
  [ "$ERR" = "backend: $NOSTEAM. Nothing was saved." ] || ERRS+=("stderr: $ERR")
  changed_is
  [ ! -e "$(BF)" ] || ERRS+=('file was written')
  mkdir -p "$T/home/.steam"
  ln -s "$T/home/gone" "$T/home/.steam/root"
  run "$T" backend set steam
  rc_is 1
  [ "$ERR" = "backend: $NOSTEAM. Nothing was saved." ] || ERRS+=("stderr with a dangling link: $ERR")
  changed_is
  [ ! -e "$(BF)" ] || ERRS+=('file was written')
}

# Flatpak Steam only: refused with the one-line reason
t_steam_backend_refuse_flatpak() {
  mkdir -p "$T/home/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps"
  run "$T" backend set steam
  rc_is 1
  [ "$ERR" = "backend: $FLATPAK. Nothing was saved." ] || ERRS+=("stderr: $ERR")
  changed_is
  [ ! -e "$(BF)" ] || ERRS+=('file was written')
}

# W3C_PREFIX and W3C_PROTON win over a steam file; set still saves the file and says so
t_steam_backend_env_wins() {
  mk_steam
  steam_on
  ovr_env "$(pfx)" "$TAG"
  run "$T" doctor
  has_line pass backend "umu: prefix and runner from W3C_PREFIX and W3C_PROTON; Faugus's games.json is not read or written"
  lacks_text 'steam root'
  bf_allow
  run "$T" backend set steam
  rc_is 0
  out_has 'W3C_PREFIX and W3C_PROTON are set and win over this file until you unset them'
}

# Steam is never auto-selected: with no backend file doctor equals the Faugus golden of the Steam-present setup although a complete Steam tree is there
t_steam_backend_never_auto() {
  mk_steam
  snap_doctor
  rc_is 0
  golden_is "$GOLDEN_DIR/v031-faugus-steam-doctor.txt"
}

# the usage line and the unknown-backend line name steam; help names backend set steam
t_steam_backend_usage() {
  run "$T" backend set steam extra
  rc_is 2
  err_has "$BUSAGE"
  changed_is
  run "$T" backend set lutris a b
  rc_is 2
  err_has 'backend: unknown backend lutris; use umu or steam'
  changed_is
  run "$T" help
  rc_is 0
  out_has 'backend set steam'
  changed_is
  [ ! -e "$(BF)" ] || ERRS+=('file was written')
}

# ---------- STEAM-02: the lenient backend file ----------

# key order and stray keys do not matter: the last BACKEND line wins and PREFIX and RUNNER are ignored under steam
t_steam_file_lenient() {
  mk_steam
  bf_put RUNNER=x PREFIX=/x junk=1 BACKEND=umu BACKEND=steam
  run "$T" doctor
  has_line pass shortcut 'Battle.net (appid 3389133332, target W3Champions.exe)'
}

# an empty or unknown BACKEND value is a malformed file, not a silent fallback
t_steam_file_unknown() {
  local v bf
  bf=$(BF)
  mk_steam
  for v in BACKEND=lutris BACKEND=; do
    bf_put "$v"
    run "$T" doctor
    rc_is 2
    err_has "$bf is not a valid umu backend file"
    err_has 'w3c-linux.sh backend clear'
  done
}

# doctor under Steam sends the user to install and update, which both work now (Phase 19): no hint carries a suffix
t_steam_doctor_install_hint() {
  local l
  mk_steam
  steam_on
  rm -f "$T/home/.local/state/w3c-linux/proton-tag"
  run "$T" doctor
  has_line warn 'w3c build' 'none recorded: run w3c-linux.sh install'
  while IFS= read -r l; do
    case $l in *'(not available'*) ERRS+=("a hint carries a rewrite suffix: $l") ;; esac
  done <<< "$OUT"
  changed_is
}

# WR-02: a // comment as the last thing in a text VDF is skipped, whatever its word count, so a good file is not reported unreadable
t_steam_vdf_trailing_comment() {
  local c
  mk_steam
  steam_on
  for c in '// hi' '// hello world' '// comment'; do
    mk_steam
    printf '%s\n' "$c" >> "$SR/config/loginusers.vdf"
    printf '%s\n' "$c" >> "$SR/config/config.vdf"
    run "$T" doctor
    has_line pass shortcut 'Battle.net (appid 3389133332, target W3Champions.exe)'
    case $OUT in *unreadable*) ERRS+=("a trailing comment made a file unreadable: $c") ;; esac
  done
  changed_is
}

# ---------- STEAM-03: the Steam root rules (D-07) ----------

# a dangling ~/.steam/root is skipped; ~/.steam/steam is next
t_steam_root_steam_link() {
  mk_steam
  steam_on
  rm "$T/home/.steam/root"
  ln -s "$T/home/gone" "$T/home/.steam/root"
  run "$T" doctor
  has_line pass 'steam root' "$SR (~/.steam/steam)"
  changed_is
}

t_steam_root_local() {
  mk_steam
  steam_on
  rm "$T/home/.steam/root" "$T/home/.steam/steam"
  run "$T" doctor
  has_line pass 'steam root' "$SR (~/.local/share/Steam)"
  changed_is
}

# Debian and Ubuntu's own packages keep Steam in ~/.steam/debian-installation; the bare ~/.local/share/Steam of the tree has no steamapps
t_steam_root_debian() {
  mk_steam "$T/home/.steam/debian-installation"
  steam_on
  rm "$T/home/.steam/root" "$T/home/.steam/steam"
  run "$T" doctor
  has_line pass 'steam root' "$SR (~/.steam/debian-installation)"
  has_line pass shortcut 'Battle.net (appid 3389133332, target W3Champions.exe)'
  changed_is
}

t_steam_root_native_wins() {
  mk_steam
  steam_on
  mkdir -p "$T/home/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps"
  run "$T" doctor
  has_line pass 'steam root' "$SR (~/.steam/root)"
  changed_is
}

t_steam_root_flatpak_only() {
  steam_on
  mkdir -p "$T/home/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps"
  run "$T" doctor
  rc_is 1
  has_line fail 'steam root' "$FLATPAK"
  has_line skip account 'needs: Steam root'
  has_line skip shortcut 'needs: Steam root'
  has_line skip PREFIX 'needs: Steam root'
  has_row pass 'required tools' curl
  has_line pass distro unknown
  changed_is
}

t_steam_root_none() {
  steam_on
  run "$T" doctor
  rc_is 1
  has_line fail 'steam root' "$NOSTEAM"
  changed_is
}

# ---------- STEAM-03: the account row (D-05, D-06) ----------

# the userdata account id is the only identity doctor shows: no login name, display name or steamid64
t_steam_account_only() {
  mk_steam
  steam_on
  run "$T" doctor
  has_line pass account '12345678 (only account)'
  lacks_text w3cspikeuser
  lacks_text 'W3C Spike'
  lacks_text 76561197972611406
  changed_is
}

# a second account with its own shortcuts.vdf (Battle.net appid 222)
mk_second() {
  mkdir -p "$SR/userdata/23456789/config"
  cp "$FIX18/shortcuts.vdf" "$SR/userdata/23456789/config/shortcuts.vdf"
  sc_edit "$SR/userdata/23456789/config/shortcuts.vdf" set 3389133332 appid 222
}

t_steam_account_mostrecent() {
  mk_steam
  steam_on
  mk_users 76561197972611406:w3cspikeuser 76561197983722517:seconduser:1
  mk_second
  run "$T" doctor
  has_line pass account '23456789 (MostRecent)'
  has_line pass shortcut 'Battle.net (appid 222, target W3Champions.exe)'
  changed_is
}

# AutoLoginUser names the account, compared without regard to case
t_steam_account_autologin() {
  mk_steam
  steam_on
  mk_users 76561197972611406:w3cspikeuser 76561197983722517:seconduser
  mk_second
  mk_registry SecondUser
  run "$T" doctor
  has_line pass account '23456789 (AutoLoginUser)'
  has_line pass shortcut 'Battle.net (appid 222, target W3Champions.exe)'
  changed_is
}

# no rule settles it: every account is scanned (a missing shortcuts.vdf is zero shortcuts; userdata/0 is never read)
t_steam_account_all() {
  mk_steam
  steam_on
  mk_users 76561197972611406:w3cspikeuser 76561197983722517:seconduser
  mkdir -p "$SR/userdata/0/config"
  printf 'not a shortcuts file' > "$SR/userdata/0/config/shortcuts.vdf"
  run "$T" doctor
  has_line pass account '12345678 23456789 (all accounts)'
  has_line pass shortcut 'Battle.net (appid 3389133332, target W3Champions.exe)'
  case $OUT in *'unreadable or malformed'*) ERRS+=('a bad row appeared') ;; esac
  lacks_text w3cspikeuser
  lacks_text seconduser
  lacks_text 'w3cspikeuser display'
  lacks_text 'seconduser display'
  lacks_text 76561197972611406
  lacks_text 76561197983722517
  changed_is
}

t_steam_account_none() {
  mk_steam
  steam_on
  rm "$SR/config/loginusers.vdf"
  run "$T" doctor
  has_line fail account "no Steam account in $SR/config/loginusers.vdf: start Steam and sign in once"
  has_line skip shortcut 'needs: Steam account'
  changed_is
}

# ---------- STEAM-04: several, none and W3C_STEAM_APPID (D-02, D-03, D-04); the appid and launch options rows (D-12) ----------

CLICK='no Battle.net shortcut in Steam: Games -> Add a Non-Steam Game to My Library -> Browse... -> the Battle.net installer -> Add Selected Programs'
SEVERAL='more than one shortcut matches: set W3C_STEAM_APPID=<appid> to pick one'
HINT='if one of these starts Battle.net, set W3C_STEAM_APPID=<appid>'
NEEDONE='needs: one Battle.net shortcut'
SCV='userdata/12345678/config/shortcuts.vdf'
BADAPPID='W3C_STEAM_APPID is not an appid (digits only, at most 4294967295)'

# a second shortcut that also starts Battle.net
mk_two() { sc_edit "$SR/$SCV" add Battle.net 111 '"/x/Battle.net Launcher.exe"'; }

# two matches: every one is listed with its appid, the finder stops, and nothing is picked
t_steam_multi_two() {
  local l
  mk_steam
  steam_on
  mk_two
  run "$T" doctor
  rc_is 1
  has_line fail shortcut 'Battle.net (appid 3389133332)'
  has_line fail shortcut 'Battle.net (appid 111)'
  has_line fail shortcut "$SEVERAL"
  values_are shortcut 'Battle.net (appid 3389133332)' 'Battle.net (appid 111)' "$SEVERAL"
  for l in appid 'launch options' PREFIX system.reg; do has_line skip "$l" "$NEEDONE"; done
  has_row pass 'required tools' curl
  has_line pass distro unknown
  changed_is
}

# W3C_STEAM_APPID picks one; empty counts as unset; leading zeros do not matter
t_steam_multi_pick() {
  mk_steam
  steam_on
  mk_two
  CASE_ENV=(W3C_STEAM_APPID=)
  run "$T" doctor
  values_are shortcut 'Battle.net (appid 3389133332)' 'Battle.net (appid 111)' "$SEVERAL"
  CASE_ENV=(W3C_STEAM_APPID=111)
  run "$T" doctor
  has_line pass shortcut 'Battle.net (appid 111, target Battle.net Launcher.exe)'
  has_line pass appid '111 (W3C_STEAM_APPID)'
  changed_is
  CASE_ENV=(W3C_STEAM_APPID=0111)
  run "$T" doctor
  has_line pass shortcut 'Battle.net (appid 111, target Battle.net Launcher.exe)'
  has_line pass appid '111 (W3C_STEAM_APPID)'
  changed_is
  CASE_ENV=()
}

# the override picks any shortcut of the chosen shortcuts.vdf, matched or not
t_steam_multi_pick_unmatched() {
  mk_steam
  steam_on
  CASE_ENV=(W3C_STEAM_APPID=3737374814)
  run "$T" doctor
  has_line pass shortcut 'AppidProbe (appid 3737374814, target notepad.exe)'
  has_line pass appid '3737374814 (W3C_STEAM_APPID)'
  has_line warn 'launch options' "$(opts_warn "$OPTS_ALL")"
  changed_is
  CASE_ENV=()
}

# an appid that is not in shortcuts.vdf: say so, list what is there
t_steam_multi_unknown() {
  mk_steam
  steam_on
  CASE_ENV=(W3C_STEAM_APPID=999)
  run "$T" doctor
  has_line fail shortcut 'W3C_STEAM_APPID=999 names no shortcut in shortcuts.vdf'
  has_line warn shortcut 'AppidProbe (appid 3737374814, target notepad.exe)'
  has_line warn shortcut 'Battle.net (appid 3389133332, target W3Champions.exe)'
  has_line warn shortcut "$HINT"
  values_are shortcut 'W3C_STEAM_APPID=999 names no shortcut in shortcuts.vdf' 'AppidProbe (appid 3737374814, target notepad.exe)' \
    'Battle.net (appid 3389133332, target W3Champions.exe)' "$HINT"
  changed_is
  CASE_ENV=()
}

# a value that is not an appid is refused and never echoed (T-18-07); the usage names the variable
t_steam_multi_bad_override() {
  local v
  mk_steam
  steam_on
  for v in 12a -1 4294967296 "$(printf '\xef\xbc\x91\xef\xbc\x92')"; do
    CASE_ENV=("W3C_STEAM_APPID=$v")
    run "$T" doctor
    has_line fail shortcut "$BADAPPID"
    case $OUT in *"$v"*) ERRS+=("the value was echoed: $v") ;; esac
    changed_is
  done
  CASE_ENV=()
  run "$T" help
  out_has W3C_STEAM_APPID
}

# no shortcut starts Battle.net: the click path, the account's other shortcuts and the hint
t_steam_multi_none() {
  mk_steam
  steam_on
  sc_edit "$SR/$SCV" set 3389133332 Exe '"/x/Launcher.bat"'
  run "$T" doctor
  has_line fail shortcut "$CLICK"
  has_line warn shortcut 'AppidProbe (appid 3737374814, target notepad.exe)'
  has_line warn shortcut 'Battle.net (appid 3389133332, target Launcher.bat)'
  has_line warn shortcut "$HINT"
  changed_is
}

# no shortcuts.vdf at all is zero shortcuts, not a malformed file
t_steam_multi_none_empty() {
  mk_steam
  steam_on
  rm "$SR/$SCV"
  run "$T" doctor
  values_are shortcut "$CLICK"
  changed_is
}

# the same appid in two accounts is two matches; each says which account
t_steam_multi_accounts() {
  mk_steam
  steam_on
  mk_users 76561197972611406:w3cspikeuser 76561197983722517:seconduser
  mkdir -p "$SR/userdata/23456789/config"
  cp "$SR/$SCV" "$SR/userdata/23456789/config/shortcuts.vdf"
  run "$T" doctor
  values_are shortcut 'Battle.net (appid 3389133332, account 12345678)' 'Battle.net (appid 3389133332, account 23456789)' "$SEVERAL"
  changed_is
}

# the appid is read from the file on every run, and nothing is saved about it
t_steam_find_reread() {
  mk_steam
  steam_on
  run "$T" doctor
  has_line pass shortcut 'Battle.net (appid 3389133332, target W3Champions.exe)'
  sc_edit "$SR/$SCV" set 3389133332 appid 222
  run "$T" doctor
  has_line pass shortcut 'Battle.net (appid 222, target W3Champions.exe)'
  changed_is
  [ "$(cat "$(BF)")" = BACKEND=steam ] || ERRS+=("backend file: $(tr '\n' '|' < "$(BF)")")
}

# the chosen shortcut's appid with its source, and its launch options as stored
t_steam_doctor_selected() {
  mk_steam
  steam_on
  run "$T" doctor
  has_line pass appid '3389133332 (target match)'
  has_line warn 'launch options' "$(opts_warn 'missing steam-wrap')"
  sc_edit "$SR/$SCV" set 3389133332 LaunchOptions ''
  run "$T" doctor
  has_line warn 'launch options' "$(opts_warn "$OPTS_ALL")"
  changed_is
}

# ---------- STEAM-03, D-10: bad Steam files fail closed on a named row and never stop doctor ----------

BADSC="shortcuts.vdf is unreadable or malformed:"
HEAL='(if Steam is writing it, rerun doctor)'

# a truncated file (a concurrent Steam write), trailing bytes, an unknown type byte and an entry without an appid: no partial list is used
t_steam_bad_shortcuts() {
  local v n
  mk_steam
  steam_on
  for v in truncated trailing badtype noappid; do
    cp "$FIX18/shortcuts.vdf" "$SR/$SCV"
    case $v in
      truncated) n=$(wc -c < "$FIX18/shortcuts.vdf"); head -c $((n - 3)) "$FIX18/shortcuts.vdf" > "$SR/$SCV" ;;
      trailing) printf '\010' >> "$SR/$SCV" ;;
      badtype) sc_edit "$SR/$SCV" badtype ;;
      noappid) sc_edit "$SR/$SCV" noappid 3389133332 ;;
    esac
    run "$T" doctor
    rc_is 1
    has_line fail shortcut "$BADSC $SR/$SCV $HEAL"
    has_line skip appid 'needs: shortcuts.vdf'
    changed_is
  done
}

# a text file that does not parse; the registry is consulted only when no account is marked MostRecent
t_steam_bad_text() {
  mk_steam
  steam_on
  printf '"users"\n{\n' > "$SR/config/loginusers.vdf"
  run "$T" doctor
  has_line fail account "loginusers.vdf is unreadable or malformed: $SR/config/loginusers.vdf $HEAL"
  changed_is
  cp "$FIX18/loginusers.vdf" "$SR/config/loginusers.vdf"
  printf '"Registry"\n{\n' > "$T/home/.steam/registry.vdf"
  run "$T" doctor
  has_line fail account "registry.vdf is unreadable or malformed: $T/home/.steam/registry.vdf $HEAL"
  changed_is
}

# a FIFO must not block doctor; a directory and an unreadable file fail closed too
t_steam_bad_special() {
  local v
  mk_steam
  steam_on
  for v in fifo dir unreadable; do
    rm -rf "${SR:?}/$SCV"
    case $v in
      fifo) mkfifo "$SR/$SCV" ;;
      dir) mkdir "$SR/$SCV" ;;
      unreadable)
        # root reads a mode-000 file, so this variant means nothing there (DEBT-03)
        [ "$(id -u)" != 0 ] || continue
        cp "$FIX18/shortcuts.vdf" "$SR/$SCV"
        chmod 000 "$SR/$SCV" ;;
    esac
    # the snapshot's sha256sum complains about the mode-000 file on stderr; the script's own stderr goes to a file and is not hidden
    run "$T" doctor 2> /dev/null
    has_line fail shortcut "$BADSC $SR/$SCV $HEAL"
    changed_is
  done
}

# no python3: the rows that need it say so, and the host row names it
t_steam_bad_nopython() {
  mk_steam
  steam_on
  rm "$T/bin/python3"
  run "$T" doctor
  has_line skip account 'needs: python3'
  has_line skip shortcut 'needs: python3'
  has_row fail 'required tools' python3
  changed_is
}

# ---------- STEAM-04: the Exe match rules and the display cleaning ----------

# direct helper call with Exe values at the edges of the rule: Battle.net*.exe or W3Champions.exe by file name, ASCII case-folded, any
# quoting, either slash; the 3737374814 shortcut (notepad.exe) never matches
t_steam_find_match_rules() {
  local -a E=() exes=('"/x/Battle.net-Setup.exe"' '"/x/Battle.net Launcher.exe"' '/x/Battle.net.exe' ' "/x/W3Champions.exe"' '"/x/w3champions.EXE"'
    'C:\x\BATTLE.NET.EXE' '"/x/notepad.exe"' '"/x/Battle.net.exe.bak"' '"/x/xBattle.net.exe"')
  local i id want got
  mk_steam
  for i in "${!exes[@]}"; do sc_edit "$SR/$SCV" add "x$((i + 1))" "$((i + 1))" "${exes[i]}"; done
  sc_edit "$SR/$SCV" add x10 10 "\"/x/W3Champion$(printf '\xc5\xbf').exe\""
  mapfile -d '' -t E < <(python3 -I -B "$ROOT/lib/w3c_helper.py" steam-find "$SR" "$T/home/.steam/registry.vdf" '')
  [ "${E[0]-}" = ok ] || ERRS+=("steam-find status: ${E[0]-}")
  for ((i = 3; i + 5 < ${#E[@]}; i += 6)); do
    id=${E[i + 1]}
    want=0
    case $id in [1-6] | 3389133332) want=1 ;; esac
    got=${E[i + 5]}
    [ "$got" = "$want" ] || ERRS+=("appid $id: match $got, want $want (Exe ${E[i + 3]})")
  done
  [ "$(((${#E[@]} - 3) / 6))" = 12 ] || ERRS+=("shortcut records: $(((${#E[@]} - 3) / 6)), want 12")
}

# control bytes, newlines and tabs in a name or launch options become ?, so no ESC reaches the terminal or a pasted issue
t_steam_find_sanitized() {
  mk_steam
  steam_on
  sc_edit "$SR/$SCV" set 3389133332 AppName $'Bat\e[31mtle\nnet'
  sc_edit "$SR/$SCV" set 3389133332 LaunchOptions $'A=1\tB=2 %command%'
  run "$T" doctor
  has_line pass shortcut 'Bat?[31mtle?net (appid 3389133332, target W3Champions.exe)'
  has_line warn 'launch options' "$(opts_warn 'missing W3C_SHARED_QUERY=1, WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--no-sandbox, PROTON_ENABLE_WAYLAND=0, WINE_SIMULATE_WRITECOPY=1, steam-wrap')"
  case $OUT in *$'\e'*) ERRS+=('an ESC byte reached the output') ;; esac
  changed_is
}

# ---------- STEAM-03, STEAM-05: the library prefix, the mapped tool and the runtime it requires (D-08 to D-10) ----------

# the shortcut's prefix, the CompatToolMapping tool and its installed runtime; every prefix row then reads that prefix
t_steam_doctor_resolved() {
  local p
  mk_steam
  steam_on
  run "$T" doctor
  p=$SR/steamapps/compatdata/3389133332/pfx
  has_line pass prefix "$p"
  has_line pass runner 'GE-Proton11-7-W3C (CompatToolMapping)'
  has_line pass runtime '4183110 installed (required by GE-Proton11-7-W3C)'
  has_line pass PREFIX "$p"
  has_line pass system.reg "$p/system.reg"
  has_line pass launcher "$p/drive_c/Program Files/W3Champions/W3Champions.exe"
  changed_is
}

# the first library (numeric key order) holding compatdata/<appid>/pfx; a relative library path is skipped
t_steam_find_library() {
  local l2
  mk_steam
  steam_on
  l2=$T/home/lib2
  mkdir -p "$l2/steamapps/compatdata"
  mv "$SR/steamapps/compatdata/3389133332" "$l2/steamapps/compatdata/"
  printf '"libraryfolders"\n{\n"0"\n{\n"path"\t\t"%s"\n}\n"1"\n{\n"path"\t\t"%s"\n}\n"2"\n{\n"path"\t\t"rel/lib"\n}\n}\n' "$SR" "$l2" > "$SR/steamapps/libraryfolders.vdf"
  run "$T" doctor
  has_line pass prefix "$l2/steamapps/compatdata/3389133332/pfx"
  changed_is
  mkdir -p "$SR/steamapps/compatdata"
  cp -a "$l2/steamapps/compatdata/3389133332" "$SR/steamapps/compatdata/"
  run "$T" doctor
  has_line pass prefix "$SR/steamapps/compatdata/3389133332/pfx"
  changed_is
}

# no pfx in any library: the prefix row says how to get one, the prefix rows skip, the runner rows still run
t_steam_find_no_pfx() {
  mk_steam
  steam_on
  rm -rf "$SR/steamapps/compatdata/3389133332"
  run "$T" doctor
  rc_is 1
  has_line fail prefix 'no compatdata/3389133332/pfx in any Steam library: press Play on the shortcut once so Steam creates it'
  has_line pass runner 'GE-Proton11-7-W3C (CompatToolMapping)'
  has_line skip system.reg 'needs: prefix'
  changed_is
}

# no CompatToolMapping entry for the appid: the runner row says where to choose one and the rows that need a tool skip
t_steam_doctor_no_mapping() {
  mk_steam
  steam_on
  mk_mapping 1000000:proton_9
  run "$T" doctor
  has_line fail runner "no CompatToolMapping entry for appid 3389133332: in Steam, open the shortcut's Properties -> Compatibility and select a compatibility tool"
  has_line skip runtime 'needs: CompatToolMapping'
  has_line skip 'runner build' 'needs: CompatToolMapping'
  has_line skip 'runner dir' 'needs: CompatToolMapping'
  has_line pass prefix "$SR/steamapps/compatdata/3389133332/pfx"
  changed_is
}

# the required runtime: StateFlags with bit 4 are installed (4, 6), anything else or no appmanifest is a warn
t_steam_runtime_states() {
  local f v miss='4183110 required by GE-Proton11-7-W3C is not installed (Steam may download it on the next Play of the shortcut)'
  mk_steam
  steam_on
  f=$SR/steamapps/appmanifest_4183110.acf
  for v in 4 6; do
    sed -i "s/\"StateFlags\"\t\t\"4\"/\"StateFlags\"\t\t\"$v\"/" "$f"
    run "$T" doctor
    has_line pass runtime '4183110 installed (required by GE-Proton11-7-W3C)'
    sed -i "s/\"StateFlags\"\t\t\"$v\"/\"StateFlags\"\t\t\"4\"/" "$f"
  done
  for v in 2 1026; do
    sed -i "s/\"StateFlags\"\t\t\"4\"/\"StateFlags\"\t\t\"$v\"/" "$f"
    run "$T" doctor
    has_line warn runtime "$miss"
    sed -i "s/\"StateFlags\"\t\t\"$v\"/\"StateFlags\"\t\t\"4\"/" "$f"
  done
  rm "$f"
  run "$T" doctor
  has_line warn runtime "$miss"
  changed_is
}

# a toolmanifest.vdf without require_tool_appid needs no runtime
t_steam_runtime_no_require() {
  mk_steam
  steam_on
  printf '"manifest"\n{\n  "version" "2"\n}\n' > "$SR/compatibilitytools.d/$TAG/toolmanifest.vdf"
  run "$T" doctor
  has_line pass runtime 'none required by GE-Proton11-7-W3C'
  changed_is
}

# a tool outside compatibilitytools.d (Valve's proton_9) has no toolmanifest.vdf there: the row skips, it does not warn
t_steam_runtime_official_tool() {
  mk_steam
  steam_on
  mk_mapping 3389133332:proton_9
  run "$T" doctor
  has_line pass runner 'proton_9 (CompatToolMapping)'
  has_line skip runtime 'needs: toolmanifest.vdf'
  changed_is
}

# a malformed Steam file, or a tool name that is a path, fails closed on the prefix row naming the file; nothing is built from the name
t_steam_bad_tool() {
  local v f
  for v in library config mapping manifest; do
    T=$(mktemp -d "$TMPROOT/c.XXXXXX")
    mk_tree "$T"
    mk_steam
    steam_on
    case $v in
      library) f=libraryfolders.vdf; printf '"libraryfolders"\n{\n' > "$SR/steamapps/libraryfolders.vdf" ;;
      config) f=config.vdf; printf '"InstallConfigStore"\n{\n' > "$SR/config/config.vdf" ;;
      mapping) f=config.vdf; mk_mapping 3389133332:../../x ;;
      manifest) f=toolmanifest.vdf; printf '"manifest"\n{\n' > "$SR/compatibilitytools.d/$TAG/toolmanifest.vdf" ;;
    esac
    run "$T" doctor
    rc_is 1
    case $f in
      libraryfolders.vdf) has_line fail prefix "$f is unreadable or malformed: $SR/steamapps/$f $HEAL" ;;
      toolmanifest.vdf) has_line fail prefix "$f is unreadable or malformed: $SR/compatibilitytools.d/$TAG/$f $HEAL" ;;
      *) has_line fail prefix "$f is unreadable or malformed: $SR/config/$f $HEAL" ;;
    esac
    has_line skip runner "needs: $f"
    changed_is
  done
}

# ---------- STEAM-05, D-09: the existing runner rows on the found root, APPID and launch-client under Steam ----------

# the W3C build, the mapped tool's directory and the prefix's version and config_info (read beside pfx/) judge the Steam root
t_steam_doctor_runner_rows() {
  mk_steam
  steam_on
  run "$T" doctor
  has_line pass 'w3c build' 'GE-Proton11-7-W3C (recorded)'
  has_line pass 'runner build' GE-Proton11-7-W3C
  has_line pass 'runner dir' "$SR/compatibilitytools.d/GE-Proton11-7-W3C"
  has_line pass 'prefix version' 'GE-Proton11-7 (Proton prefix format, same for stock and W3C builds)'
  has_line pass 'prefix runner' 'GE-Proton11-7-W3C (config_info line 3)'
  has_line skip APPID 'not used (backend: steam)'
  has_line skip launch-client 'not used (backend: steam)'
  has_line pass W3C_EXE "$SR/steamapps/compatdata/3389133332/pfx/drive_c/Program Files/W3Champions/W3Champions.exe"
  changed_is
}

# a prefix Steam has not started yet: the hint says to press Play on the shortcut, not to use Faugus
t_steam_doctor_runner_wording() {
  mk_steam
  steam_on
  rm "$SR/steamapps/compatdata/3389133332/version" "$SR/steamapps/compatdata/3389133332/config_info"
  run "$T" doctor
  has_line warn 'prefix version' 'absent: start Battle.net once with Play on the Steam shortcut'
  has_line skip 'prefix runner' 'needs: config_info (start Battle.net once with Play on the Steam shortcut)'
  changed_is
}

# a mapped tool that is not the recorded build: never read as managed by Faugus; its directory is judged under the Steam root
t_steam_doctor_runner_other() {
  mk_steam
  steam_on
  mk_mapping 3389133332:UMU-Latest
  run "$T" doctor
  has_line pass runner 'UMU-Latest (CompatToolMapping)'
  has_line warn 'runner dir' "missing: $SR/compatibilitytools.d/UMU-Latest (UMU-Latest is mapped but is no build in this root's compatibilitytools.d: a built-in Steam tool, or a tool whose name differs from its directory)"
  lacks_text 'managed by Faugus'
  has_row warn 'runner build' 'UMU-Latest, expected GE-Proton11-7-W3C'
  fill_build "$SR/compatibilitytools.d/GE-Proton10-1" GE-Proton10-1
  mk_mapping 3389133332:GE-Proton10-1
  run "$T" doctor
  has_row warn 'runner build' 'GE-Proton10-1, expected GE-Proton11-7-W3C'
  has_line pass 'runner dir' "$SR/compatibilitytools.d/GE-Proton10-1"
  changed_is
}

# a Steam root under ~/.steam/debian-installation: its compatibilitytools.d is the one doctor reads, and the compat tools row names it
t_steam_doctor_debian_compat() {
  mk_steam "$T/home/.steam/debian-installation"
  steam_on
  rm "$T/home/.steam/root" "$T/home/.steam/steam"
  run "$T" doctor
  has_line pass 'runner dir' "$SR/compatibilitytools.d/GE-Proton11-7-W3C"
  has_line pass 'compat tools' "present: $SR/compatibilitytools.d"
  changed_is
}

# ---------- STEAM-05, D-11: Steam running is the pid file plus a live steam process, read from files only ----------

t_steam_running_live() {
  mk_steam
  steam_on
  mkdir -p "$T/proc/4242"
  printf '4242\n' > "$T/home/.steam/steam.pid"
  printf 'steam\n' > "$T/proc/4242/comm"
  run "$T" doctor
  has_line pass 'steam running' 'pid 4242'
  changed_is
}

# no pid file, a stale pid, a pid file that is not digits and a recycled pid are all not running, and never a failure
t_steam_running_not() {
  local v
  mk_steam
  steam_on
  for v in nofile stale text recycled; do
    rm -rf "${T:?}/proc/4242" "$T/home/.steam/steam.pid"
    case $v in
      stale) printf '4242\n' > "$T/home/.steam/steam.pid" ;;
      text) printf 'abc\n' > "$T/home/.steam/steam.pid" ;;
      recycled) mkdir -p "$T/proc/4242"; printf '4242\n' > "$T/home/.steam/steam.pid"; printf 'bash\n' > "$T/proc/4242/comm" ;;
    esac
    run "$T" doctor
    has_line warn 'steam running' 'no: only launch needs Steam running'
    case $OUT in *'fail  steam running'*) ERRS+=("$v: steam running failed") ;; esac
    changed_is
  done
}

# ---------- STEAM-02, STEAM-05: the remaining doctor slots under Steam (D-08) ----------

# the version slot names the Steam source, every Faugus and umu row says why it does not apply, and the label order is the golden's with the
# Steam rows spliced in
t_steam_doctor_rows() {
  local l want got
  mk_steam
  steam_on
  run "$T" doctor
  rc_is 0
  has_line pass backend "steam: from $(BF); Steam's files are read, never written"
  for l in games.json battlenet path config.json envar.json 'faugus env'; do has_line skip "$l" "$SKIPS"; done
  for l in umu-run 'umu version'; do has_line skip "$l" 'not used (backend: steam)'; done
  has_line skip 'launch env' "not used (backend: steam): the shortcut's launch options carry the environment"
  lacks_text 'faugus version'
  for l in webview2 launcher 'launcher version' 'required tools' ptrace_scope; do has_row pass "$l" ''; done
  want=$(labels < "$GOLDEN_DIR/v031-faugus-healthy-doctor.txt" | sed \
    -e 's/^faugus version$/backend/' \
    -e 's/^prefix$/steam root\nsteam running\naccount\nshortcut\nappid\nprefix/' \
    -e 's/^runner$/runner\nruntime/' \
    -e 's/^launch_arguments$/launch options/')
  got=$(labels <<< "$OUT")
  [ "$want" = "$got" ] || ERRS+=("label order differs: $(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | head -n 6 | tr '\n' '|')")
  changed_is
}

# STEAM-05: no umu-run anywhere, and a healthy Steam tree has no fail row
t_steam_doctor_no_umu() {
  mk_steam
  steam_on
  no_bundled
  run "$T" doctor
  rc_is 0
  has_line skip umu-run 'not used (backend: steam)'
  case $OUT in 'fail '* | *$'\nfail '*) ERRS+=("a fail row: $(grep '^fail' <<< "$OUT" | head -n 3 | tr '\n' '|')") ;; esac
  changed_is
}

# ---------- STEAM-02, D-14, D-15: backend show and report under Steam ----------

# show: the source, the root, the shortcut with its appid and the prefix, resolved now; the appid is printed, never stored
t_steam_backend_show() {
  local bf want
  bf=$(BF)
  mk_steam
  steam_on
  run "$T" backend show
  rc_is 0
  want=$(printf 'backend: steam (from %s)\nroot: %s\nshortcut: Battle.net (appid 3389133332)\nprefix: %s/steamapps/compatdata/3389133332/pfx' "$bf" "$SR" "$SR")
  [ "$OUT" = "$want" ] || ERRS+=("show: $OUT")
  [ "$(cat "$bf")" = BACKEND=steam ] || ERRS+=("backend file: $(tr '\n' '|' < "$bf")")
  changed_is
}

# show stops where resolution stops, names what is missing, never fails
t_steam_backend_show_fail() {
  local bf head want
  bf=$(BF)
  head=$(printf 'backend: steam (from %s)' "$bf")
  steam_on
  run "$T" backend show
  rc_is 0
  [ "$OUT" = "$(printf '%s\nsteam: %s' "$head" "$NOSTEAM")" ] || ERRS+=("no Steam: $OUT")
  changed_is
  mk_steam
  mk_two
  run "$T" backend show
  rc_is 0
  want=$(printf '%s\nroot: %s\nsteam: needs: one Battle.net shortcut; run w3c-linux.sh doctor' "$head" "$SR")
  [ "$OUT" = "$want" ] || ERRS+=("two shortcuts: $OUT")
  changed_is
  mk_steam
  rm -rf "$SR/steamapps/compatdata/3389133332"
  run "$T" backend show
  rc_is 0
  want=$(printf '%s\nroot: %s\nshortcut: Battle.net (appid 3389133332)\nsteam: needs: prefix; run w3c-linux.sh doctor' "$head" "$SR")
  [ "$OUT" = "$want" ] || ERRS+=("no prefix: $OUT")
  changed_is
}

# D-15: report runs under Steam with unknown Faugus and umu versions, the mapped tool as the runner, the Steam prefix's launcher, and no network
t_steam_guard_report() {
  local l
  mk_steam
  steam_on
  run "$T" report
  rc_is 0
  for l in "$(printf '%-10s %s' faugus unknown)" "$(printf '%-10s %s' umu unknown)" "$(printf '%-10s %s' runner GE-Proton11-7-W3C)" \
    "$(printf '%-10s %s' launcher 'installed 1.6.16, recorded 1.6.16')"; do
    grep -qxF -- "$l" <<< "$OUT" || ERRS+=("report lacks: [$l]")
  done
  [ ! -e "$T/marks/curl" ] || ERRS+=('curl ran during report')
  changed_is
}

# STEAM-03: doctor, show and report on a full tree with Steam running write nothing and print no account name, display name or steamid64
t_steam_nowrite_tree() {
  local all='' v
  mk_steam
  steam_on
  mkdir -p "$T/proc/4242"
  printf '4242\n' > "$T/home/.steam/steam.pid"
  printf 'steam\n' > "$T/proc/4242/comm"
  for v in doctor 'backend show' report; do
    # shellcheck disable=SC2086 # the verb is one or two words
    run "$T" $v
    all+=$OUT$'\n'
    changed_is
  done
  OUT=$all
  lacks_text w3cspikeuser
  lacks_text 'W3C Spike'
  lacks_text 76561197972611406
}

# ---------- STEAM-03: nothing in the Steam code can write ----------

t_steam_nowrite_static() {
  local o f=$T/plant.sh g=$T/plant.py
  o=$(nowrite_sh "$ROOT/lib/steam.sh")
  [ -z "$o" ] || ERRS+=("lib/steam.sh may write: $o")
  o=$(nowrite_py "$ROOT/lib/w3c_helper.py")
  [ -z "$o" ] || ERRS+=("the helper's Steam code may write: $o")
  # not vacuous: planted writes are reported, one line each
  # shellcheck disable=SC2016 # the planted lines are literal shell text
  printf '%s\n' 'printf x > "$f"' 'rm -f -- "$f"' "printf '%s' \"\$x\" >> \"\$log\"" > "$f"
  [ "$(nowrite_sh "$f" | wc -l)" = 3 ] || ERRS+=("the shell scan missed a planted write: $(nowrite_sh "$f" | tr '\n' '|')")
  # a quoted arrow and a redirect to /dev/null are not writes
  # shellcheck disable=SC2016 # the planted lines are literal shell text
  printf '%s\n' "emit fail shortcut 'Games -> Add'" 'python3 -I -B "$HELPER" steam-find "$1" 2> /dev/null' > "$f"
  o=$(nowrite_sh "$f")
  [ -z "$o" ] || ERRS+=("the shell scan reported a quoted arrow or /dev/null: $o")
  # a complete set of blocks is clean; each planted write is reported
  {
    for o in steam_clean steam_out steam_find steam_tool vdf_binary vdf_text vdf_get; do printf 'def %s():\n    return 1\n\n\n' "$o"; done
    printf 'def steam_read(p):\n    with open(p, "rb") as fh:\n        return fh.read()\n\n\nimport shutil\nshutil.copy\n'
  } > "$g"
  o=$(nowrite_py "$g")
  [ -z "$o" ] || ERRS+=("the Python scan reported a clean file: $o")
  printf 'def steam_x():\n    open(p, "w").write("x")\n' >> "$g"
  [ -n "$(nowrite_py "$g")" ] || ERRS+=('the Python scan missed a planted open(p, "w")')
  head -n -2 "$g" > "$g.2"
  printf 'def vdf_x():\n    os.remove(p)\n' >> "$g.2"
  [ -n "$(nowrite_py "$g.2")" ] || ERRS+=('the Python scan missed a planted os.remove')
}

# ---------- main ----------

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
