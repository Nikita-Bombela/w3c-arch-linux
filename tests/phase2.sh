#!/usr/bin/env bash
# Phase 2 fixture check: runs the real w3c-linux.sh under env -i against a fake HOME per case.
# curl and pgrep are fixture shims here: curl serves files from T/fix by URL, pgrep reads T/fix/procs.
# umu-run is a recording shim: argv in marks/umu-run, its environment in marks/umu-run.env, and T/fix/on-umu.sh (when a case writes one)
# plays the file effects of Wine. tests/phase3.sh sources this file for the harness.
# Usage: bash tests/phase2.sh [GLOB]   (GLOB filters on display names such as install-fresh)
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=$ROOT/w3c-linux.sh
SOURCES=("$SCRIPT" "$ROOT"/lib/*.sh "$ROOT"/lib/*.py)   # every file the static checks scan: the entry plus lib/
BASH_BIN=$(type -P bash)   # resolved before any PATH narrowing
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

T='' CASE_ENV=() OUT='' ERR='' RC=0 ERRS=() CHANGED=() ALLOW_EXTRA=()
TAG=GE-Proton11-7-W3C
BOOT_ID=0b5e1d2c-0000-4000-8000-000000000001   # the fake boot id mk_tree seeds; the nat-applied marker holds it too, so install prompt 8 asks nothing
FORBIDDEN=(wine wineserver faugus-launcher steam-runtime-launch-client pkill sudo umu-run nft iptables notify-send)

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

# curl shim: logs argv, serves $FIX/<last URL component> (the fork's API URL maps to $FIX/latest and other fixed URLs to named files), exit 22 when absent.
write_curl_shim() {
  cat > "$1/bin/curl" <<'SH'
#!/bin/sh
printf '%s\n' "$0 $*" >> "$MARK/curl"
url='' out='' prev=''
for a in "$@"; do
  case $a in https://*) url=$a ;; esac
  [ "$prev" = -o ] && out=$a
  prev=$a
done
case $url in
  https://api.github.com/repos/davex32/*) f=$FIX/latest ;;
  https://api.github.com/repos/w3champions/w3champions-issues/issues/57) f=$FIX/issue57 ;;
  https://api.github.com/repos/GloriousEggroll/*) f=$FIX/ge-latest ;;
  https://raw.githubusercontent.com/*) f=$FIX/protocol.def ;;
  https://go.microsoft.com/*) f=$FIX/webview2.exe ;;
  *) f=$FIX/${url##*/} ;;
esac
[ -f "$f" ] || exit 22
if [ -n "$out" ]; then cp "$f" "$out" || exit 23; else cat "$f"; fi
SH
  chmod +x "$1/bin/curl"
}

# umu-run shim: logs argv to marks/umu-run and its environment to marks/umu-run.env, then sources $FIX/on-umu.sh with the same arguments when present.
write_umu_shim() {
  mkdir -p "${1%/*}"
  cat > "$1" <<'SH'
#!/bin/sh
printf '%s\n' "$0 $*" >> "$MARK/umu-run"
{ echo '== call =='; env; } >> "$MARK/umu-run.env"
[ -f "$FIX/on-umu.sh" ] && . "$FIX/on-umu.sh"
exit 0
SH
  chmod +x "$1"
}

# pgrep shim: logs argv; $FIX/pgrep-rc forces an exit status; else $FIX/procs (pid|comm|cmdline) answers -f REGEX and -x NAME.
# Late seam: when $FIX/late-after holds N and at least N earlier calls asked -x wineserver (the last query of every idle_check, so N counts
# finished idle checks), $FIX/procs.late answers instead of $FIX/procs. Builtins plus the linked grep only.
write_pgrep_shim() {
  cat > "$1/bin/pgrep" <<'SH'
#!/bin/sh
procs=$FIX/procs
if [ -f "$FIX/late-after" ]; then
  read -r need < "$FIX/late-after"
  seen=$(grep -c -e '-x wineserver' "$MARK/pgrep" 2> /dev/null)
  [ "${seen:-0}" -ge "$need" ] && procs=$FIX/procs.late
fi
printf '%s\n' "$0 $*" >> "$MARK/pgrep"
if [ -f "$FIX/pgrep-rc" ]; then read -r rc < "$FIX/pgrep-rc"; exit "$rc"; fi
mode=f regex='' name=''
while [ $# -gt 0 ]; do
  case $1 in
    -u) shift ;;
    -f) mode=f; shift; regex=$1 ;;
    -x) mode=x; shift; name=$1 ;;
  esac
  shift
done
[ -f "$procs" ] || exit 1
found=1
while IFS='|' read -r pid comm cmd; do
  [ -n "$pid" ] || continue
  case $mode in
    f) if printf '%s\n' "$cmd" | grep -Eq -- "$regex"; then echo "$pid"; found=0; fi ;;
    x) if [ "$comm" = "$name" ]; then echo "$pid"; found=0; fi ;;
  esac
done < "$procs"
exit $found
SH
  chmod +x "$1/bin/pgrep"
}

# mk_tree T: a healthy Faugus tree. games.json is written the way Faugus writes it (indent 4, ensure_ascii False, no trailing newline, 0600).
mk_tree() {
  local t=$1 h=$1/home p=$1/home/Faugus/battlenet
  local fg=$h/.local/share/faugus-launcher w=$p/drive_c/Program\ Files\ \(x86\)
  local n bi
  mkdir -p "$t/bin" "$t/marks" "$t/fix" "$fg" "$h/.config/faugus-launcher" "$p/drive_c/Program Files/W3Champions"
  mkdir -p "$w/Battle.net" "$w/Warcraft III/_retail_/x86_64" "$p/drive_c/users/steamuser/Documents/Warcraft III"
  mkdir -p "$h/.local/share/Steam/compatibilitytools.d"
  printf '1\n' > "$t/ptrace_scope"
  for n in python3 realpath md5sum awk grep sed sha256sum tar gzip cat cp find stat readlink date mv rm rmdir mktemp mkdir head sort diff cmp env sleep flock; do
    add_link "$t" "$n"
  done
  # a fixed list, so a suite whose FORBIDDEN omits one of these still gets its marker shim; FORBIDDEN decides which markers fail a case
  for n in wine wineserver faugus-launcher steam-runtime-launch-client pkill sudo nft iptables notify-send; do add_shim "$t" "$n"; done
  write_curl_shim "$t"
  write_pgrep_shim "$t"
  python3 - "$fg/games.json" "$p" <<'PY'
import json, os, sys
f, p = sys.argv[1:3]
fields = ["gameid", "title", "path", "prefix", "launch_arguments", "game_arguments", "mangohud", "gamemode", "sdl_enabled",
          "protonfix", "runner", "addapp_enabled", "addapp", "addapp_bat", "addapp_delay", "addapp_first", "cover",
          "lossless_enabled", "lossless_multiplier", "lossless_flow", "lossless_performance", "lossless_hdr",
          "lossless_present", "playtime", "hidden", "no_sleep", "category", "icon", "steamgriddb_id", "pre_launch",
          "post_launch", "steam_user", "disable_umu", "runtime", "last_played"]
assert len(fields) == 35
def entry(**kw):
    e = {k: "" for k in fields}
    e.update(playtime=0, hidden=False, no_sleep=False, category=[], disable_umu=False, runtime="", last_played=0)
    e.update(kw)
    return e
data = [
    entry(gameid="other", title="Ünïcødé", prefix="/nonexistent/other", runner="GE-Proton", path="/nonexistent/other.exe",
          icon="/nonexistent/other.png"),
    entry(gameid="battlenet", title="Battle.net", prefix=p, runner="Proton-GE Latest",
          launch_arguments="WINE_SIMULATE_WRITECOPY=1 PROTON_ENABLE_WAYLAND=0",
          path=p + "/drive_c/Program Files (x86)/Battle.net/Battle.net.exe", gamemode="False", mangohud="False"),
]
with open(f, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=4, ensure_ascii=False)
os.chmod(f, 0o600)
PY
  cp "$fg/games.json" "$t/orig-games.json"
  write_umu_shim "$fg/umu-run"
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

[Software\\Microsoft\\Windows NT\\CurrentVersion] 1700000000
"CurrentBuild"="19045"
"ProductName"="Windows 10 Pro"

[Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{6C2A7B21-0000-4000-8000-000000000001}] 1700000000
"DisplayName"="W3Champions"
"DisplayVersion"="1.6.16"

REG
  # Phase 3 baseline: every in-prefix step is already satisfied, so install asks nothing new and runs no Wine
  mkdir -p "$p/drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application/149.0.4022.98" "$h/.local/state/w3c-linux"
  : > "$p/drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application/149.0.4022.98/msedgewebview2.exe"
  : > "$p/drive_c/Program Files/W3Champions/W3Champions.exe"
  cat > "$p/user.reg" <<'REG'
WINE REGISTRY Version 2

[Software\\Blizzard Entertainment\\Warcraft III] 1700000000
#time=1d0000000000000
"Allow Local Files"=dword:00000001

[Software\\Wine\\AppDefaults\\msedgewebview2.exe] 1700000000
#time=1d0000000000000
"Version"="win7"

REG
  printf '1.6.16\n' > "$h/.local/state/w3c-linux/launcher-version"
  # Phase 5 baseline: the LAN-test NAT rule counts as applied this boot, so install prompt 8 prints one line and asks nothing
  mkdir -p "$t/proc/sys/kernel/random"
  printf '%s\n' "$BOOT_ID" > "$t/proc/sys/kernel/random/boot_id"
  printf '%s\n' "$BOOT_ID" > "$h/.local/state/w3c-linux/nat-applied"
  cat > "$t/fix/latest.json" <<'JSON'
{"version": "1.6.16", "notes": "", "pub_date": "2026-10-08T10:10:26Z", "platforms": {"windows-x86_64-msi": {"signature": "sig", "url": "https://github.com/w3champions/launcher-e-release/releases/download/1.6.16/W3Champions_1.6.16_x64_en-US.msi"}}}
JSON
  printf 'fake launcher msi\n' > "$t/fix/launcher-e"
  printf 'fake webview2 installer\n' > "$t/fix/webview2.exe"
  : > "$w/Battle.net/Battle.net.exe"
  : > "$w/Warcraft III/_retail_/x86_64/Warcraft III.exe"
  printf '%s\n' 'Branch!STRING:0|Active!DEC:1|Build Key!HEX:16|CDN Key!HEX:16|Install Key!HEX:16|IM Size!DEC:4|CDN Path!STRING:0|CDN Hosts!STRING:0|CDN Servers!STRING:0|Tags!STRING:0|Armadillo!STRING:0|Last Activated!STRING:0|Version!STRING:0|KeyRing!HEX:16|Product!STRING:0' > "$w/Warcraft III/.build.info"
  bi=(eu 1 '' '' '' '' '' '' '' '' '' '' 3.0.0.24268 abcd w3)
  ( IFS='|'; printf '%s\n' "${bi[*]}" ) >> "$w/Warcraft III/.build.info"
  write_shim "$h/.local/share/umu/steamrt4/pressure-vessel/bin/steam-runtime-launch-client" steam-runtime-launch-client
}

# fill_build DIR TAG: the four entries of a complete build.
fill_build() {
  mkdir -p "$1/files/bin"
  : > "$1/proton"
  chmod +x "$1/proton"
  printf '"compatibilitytools"\n{\n}\n' > "$1/compatibilitytool.vdf"
  printf '1700000000 %s\n' "$2" > "$1/version"
  : > "$1/files/bin/wine"
}

# mk_release T [TAG]: T/fix holds TAG.tar.gz, SHA256SUMS (the real shape: sha512sum line plus tarball line) and latest (API JSON).
# Built once per tag under TMPROOT, then copied into each case.
mk_release() {
  local t=$1 tag=${2:-$TAG} src=$TMPROOT/rel-${2:-$TAG} h
  if [ ! -d "$src" ]; then
    mkdir -p "$src" "$TMPROOT/stage-$tag"
    fill_build "$TMPROOT/stage-$tag/$tag" "$tag"
    tar -czf "$src/$tag.tar.gz" -C "$TMPROOT/stage-$tag" "$tag"
    h=$(sha256sum "$src/$tag.tar.gz")
    printf '%s  %s.sha512sum\n%s  %s.tar.gz\n' "$(printf %s "$tag" | sha256sum | cut -d' ' -f1)" "$tag" "${h%% *}" "$tag" > "$src/SHA256SUMS"
    python3 - "$src/latest" "$tag" <<'PY'
import json, sys
f, tag = sys.argv[1:3]
base = "https://github.com/davex32/proton-ge-w3c/releases/download/" + tag + "/"
assets = [{"name": tag + ".tar.gz", "size": 1088358492}, {"name": tag + ".sha512sum", "size": 164}, {"name": "SHA256SUMS", "size": 185}]
for a in assets:
    a["browser_download_url"] = base + a["name"]
with open(f, "w", encoding="utf-8") as fh:
    json.dump({"tag_name": tag, "draft": False, "prerelease": False, "assets": assets}, fh)
PY
  fi
  cp "$src"/* "$t/fix/"
}

# mk_installed T [TAG]: a complete compatibilitytools.d/TAG; proton-tag is not written.
mk_installed() {
  fill_build "$1/home/.local/share/Steam/compatibilitytools.d/${2:-$TAG}" "${2:-$TAG}"
}

# add_proc T PID COMM CMDLINE: one more process for the pgrep shim.
add_proc() { printf '%s|%s|%s\n' "$2" "$3" "$4" >> "$1/fix/procs"; }

# add_wineserver T PID DIRNAME: a wineserver whose /proc/PID/cwd is a directory named DIRNAME.
add_wineserver() {
  mkdir -p "$1/wine-tmp/$3" "$1/proc/$2"
  ln -s "$1/wine-tmp/$3" "$1/proc/$2/cwd"
  add_proc "$1" "$2" wineserver '/usr/bin/wineserver -p'
}

# prefix_server_name T: the server dir name Wine derives from the prefix's device and inode, computed here without the script.
prefix_server_name() {
  python3 -c 'import os, sys; st = os.stat(sys.argv[1]); print("server-%x-%x" % (st.st_dev, st.st_ino))' "$1/home/Faugus/battlenet"
}

# set_running_games T TEXT: Faugus's running-games.json.
set_running_games() {
  mkdir -p "$1/home/.local/state/faugus-launcher"
  printf '%s' "$2" > "$1/home/.local/state/faugus-launcher/running-games.json"
}

# set_latest T PYTHON: mutate T/fix/latest. PYTHON sees r (the release object), a (its assets list), tag and base (the right URL prefix).
set_latest() {
  python3 - "$1/fix/latest" "$2" <<'PY'
import json, sys
f, code = sys.argv[1:3]
r = json.load(open(f, encoding="utf-8"))
a, tag = r["assets"], r["tag_name"]
base = "https://github.com/davex32/proton-ge-w3c/releases/download/"
exec(code)
json.dump(r, open(f, "w", encoding="utf-8"), ensure_ascii=False)
PY
}

# mk_bad_release T VARIANT [LINK_TARGET]: T/fix/<tag>.tar.gz built to fail structure validation, with a SHA256SUMS that matches it,
# so the structure checks, not the checksum, reject it. VARIANT: dotdot abs-member wrong-toplevel two-toplevels missing-files symlink-top.
mk_bad_release() {
  local t=$1 h
  python3 - "$t/fix/$TAG.tar.gz" "$TAG" "$2" "$TMPROOT/abs_evil_${t##*/}" "${3:-/}" <<'PY'
import io, sys, tarfile
out, tag, variant, absname, link = sys.argv[1:6]
tf = tarfile.open(out, "w:gz")
def add(name, data=b"", mode=0o644, typ=tarfile.REGTYPE, linkname=""):
    ti = tarfile.TarInfo(name)
    ti.type, ti.mode, ti.linkname = typ, mode, linkname
    if typ == tarfile.REGTYPE:
        ti.size = len(data)
        tf.addfile(ti, io.BytesIO(data))
    else:
        tf.addfile(ti)
def build(top, files=True):
    add(top, typ=tarfile.DIRTYPE, mode=0o755)
    add(top + "/proton", b"#!/bin/sh\n", 0o755)
    add(top + "/compatibilitytool.vdf", b'"compatibilitytools"\n{\n}\n')
    add(top + "/version", b"1700000000 x\n")
    if files:
        add(top + "/files", typ=tarfile.DIRTYPE, mode=0o755)
        add(top + "/files/bin", typ=tarfile.DIRTYPE, mode=0o755)
        add(top + "/files/bin/wine")
if variant == "dotdot":
    build(tag)
    add("../evil", b"x")
elif variant == "abs-member":
    build(tag)
    add(absname, b"x")
elif variant == "wrong-toplevel":
    build("GE-Proton11-7")
elif variant == "two-toplevels":
    build(tag)
    add("stray.txt", b"x")
elif variant == "missing-files":
    build(tag, files=False)
elif variant == "symlink-top":
    add(tag, typ=tarfile.SYMTYPE, linkname=link)
else:
    sys.exit("unknown variant " + variant)
tf.close()
PY
  h=$(sha256sum "$t/fix/$TAG.tar.gz")
  printf '%s  %s.tar.gz\n' "${h%% *}" "$TAG" > "$t/fix/SHA256SUMS"
}

# mk_siblings T: the target machine's real neighbours in compatibilitytools.d, complete trees that no install may touch.
mk_siblings() {
  fill_build "$1/home/.local/share/Steam/compatibilitytools.d/Proton-GE Latest" 'Proton-GE Latest'
  fill_build "$1/home/.local/share/Steam/compatibilitytools.d/GE-Proton11-WC3-CertFix" GE-Proton11-WC3-CertFix
}

# siblings_untouched: no changed path lies under either sibling runner.
siblings_untouched() {
  local p
  for p in "${CHANGED[@]}"; do
    case $p in
      *'/Proton-GE Latest' | *'/Proton-GE Latest/'* | */GE-Proton11-WC3-CertFix | */GE-Proton11-WC3-CertFix/*) ERRS+=("sibling runner touched: $p") ;;
    esac
  done
}

# cache_empty: the cache dir holds neither the tarball nor SHA256SUMS.
cache_empty() {
  [ -z "$(find "$T/home/.cache/w3c-linux" \( -name '*.tar.gz' -o -name SHA256SUMS \) 2> /dev/null)" ] || ERRS+=('the cache dir still holds a download')
}

# nothing_placed: no staging dir, no <tag> dir, no proton-tag, games.json untouched, siblings untouched.
nothing_placed() {
  local c=$T/home/.local/share/Steam/compatibilitytools.d
  ! compgen -G "$c/.w3c-staging.*" > /dev/null || ERRS+=('a staging dir is left')
  [ ! -e "$c/$TAG" ] || ERRS+=("compatibilitytools.d/$TAG exists")
  [ ! -e "$T/home/.local/state/w3c-linux/proton-tag" ] || ERRS+=('proton-tag exists')
  unchanged_games
  siblings_untouched
}

# ---------- run and invariants ----------

# snap ROOT: one row per path below ROOT (marks/ excluded). Directories carry type and mode only; files and symlinks add size, link target and sha256.
snap() {
  {
    find "$1" \( -path "$1/marks" -o -path "$1/home/.local/state/w3c-linux/lock" \) -prune -o -type f -exec sha256sum {} + | sed -E 's/^([0-9a-f]{64})  (.*)$/H\t\2\t\1/'
    find "$1" \( -path "$1/marks" -o -path "$1/home/.local/state/w3c-linux/lock" \) -prune -o -printf 'R\t%P\t%y\t%m\t%s\t%l\n'
  } | awk -F'\t' -v root="$1" '
    $1 == "H" { sha[substr($2, length(root) + 2)] = $3; next }
    $1 == "R" { if ($3 == "d") print $2 "\t" $3 "\t" $4; else print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" sha[$2] }' \
    | LC_ALL=C sort
}

# run_cmd T ARGS...: the real entry point under env -i; the one copy of the environment both run and run_fifo use.
run_cmd() {
  local t=$1
  shift
  # the W3C_ASSUME_TTY seam below makes phases 2 to 5 run launch on the terminal path; tests/phase6.sh clears it through CASE_ENV
  # W3C_SYS_ROOT is a path that never exists, so the suites never read the host's /usr (a maintainer with the package installed has
  # /usr/share/applications/w3c-linux.desktop); a case's own W3C_SYS_ROOT in CASE_ENV overrides it
  env -i HOME="$t/home" PATH="$t/bin" MARK="$t/marks" FIX="$t/fix" W3C_PTRACE_SCOPE_FILE="$t/ptrace_scope" W3C_PROC_DIR="$t/proc" \
    W3C_FAUGUS_PY_DIR="$t/faugus-py" W3C_ASSUME_TTY=1 W3C_SYS_ROOT="$t/sysroot" "${CASE_ENV[@]}" "$BASH_BIN" "$SCRIPT" "$@"
}

# post_run T: reads OUT and ERR, then enforces the allowlist and marker invariants; sets CHANGED.
post_run() {
  local t=$1 n p a ok sb=$TMPROOT/snap.before sa=$TMPROOT/snap.after
  OUT=$(< "$TMPROOT/out")
  ERR=$(< "$TMPROOT/err")
  snap "$t" > "$sa"
  mapfile -t CHANGED < <(LC_ALL=C comm -3 "$sb" "$sa" | sed 's/^\t//' | cut -f1 | sed '/^$/d' | LC_ALL=C sort -u)
  for p in "${CHANGED[@]}"; do
    ok=0
    case $p in
      home/.local/share/faugus-launcher/games.json | home/.local/state | home/.cache) ok=1 ;;
      home/.local/state/w3c-linux | home/.local/state/w3c-linux/*) ok=1 ;;
      home/.local/share/Steam/compatibilitytools.d | home/.local/share/Steam/compatibilitytools.d/*) ok=1 ;;
      home/.cache/w3c-linux | home/.cache/w3c-linux/*) ok=1 ;;
      home/.local/share | home/.local/share/applications | home/.local/share/applications/* | home/.local/share/icons | home/.local/share/icons/*) ok=1 ;;
    esac
    for a in "${ALLOW_EXTRA[@]}"; do [ "$p" = "$a" ] && ok=1; done
    [ "$ok" = 1 ] || ERRS+=("write outside the allowed paths: $p")
  done
  for n in "${FORBIDDEN[@]}"; do
    [ -e "$t/marks/$n" ] && ERRS+=("forbidden command ran: $n")
  done
  return 0
}

# run T ARGS...: sets OUT ERR RC CHANGED; stdin is FEED when set, else /dev/null.
run() {
  local t=$1
  shift
  snap "$t" > "$TMPROOT/snap.before"
  if [ "${FEED+set}" = set ]; then
    printf '%s' "$FEED" | run_cmd "$t" "$@" > "$TMPROOT/out" 2> "$TMPROOT/err"
  else
    run_cmd "$t" "$@" < /dev/null > "$TMPROOT/out" 2> "$TMPROOT/err"
  fi
  RC=$?
  post_run "$t"
}

# run_fifo T ARGS...: like run, but the script reads a FIFO the test drives with wait_err, send and finish (Pitfall 9).
# The FIFO lives under TMPROOT so it is not part of the snapshot.
FIFO_FD='' FIFO_PID=''
run_fifo() {
  local t=$1 fifo=$TMPROOT/in
  shift
  snap "$t" > "$TMPROOT/snap.before"
  rm -f "$fifo"
  mkfifo "$fifo"
  : > "$TMPROOT/out"
  : > "$TMPROOT/err"
  run_cmd "$t" "$@" < "$fifo" > "$TMPROOT/out" 2> "$TMPROOT/err" &
  FIFO_PID=$!
  exec {FIFO_FD}> "$fifo"
}

# wait_err TEXT [N]: wait up to 10 s until stderr holds TEXT on at least N lines (default 1).
wait_err() {
  local i
  for ((i = 0; i < 100; i++)); do
    [ "$(grep -cF -- "$1" "$TMPROOT/err")" -ge "${2:-1}" ] && return 0
    sleep 0.1
  done
  ERRS+=("timed out waiting for stderr: $1")
}

# a script that already exited closed the read end; that must not kill the test run
trap '' PIPE
send() { { printf '%s' "$1" >&"$FIFO_FD"; } 2> /dev/null || true; }

# finish: closes the FIFO (EOF for the script), waits for it, then does the post-run work.
finish() {
  exec {FIFO_FD}>&-
  wait "$FIFO_PID"
  RC=$?
  post_run "$T"
}

# ---------- assertions ----------

lacks_text() { case $OUT in *"$1"*) ERRS+=("output unexpectedly has: $1") ;; esac; }
out_has() { case $OUT in *"$1"*) ;; *) ERRS+=("output lacks: $1") ;; esac; }
err_has() { case $ERR in *"$1"*) ;; *) ERRS+=("stderr lacks: $1") ;; esac; }
rc_is() { [ "$RC" = "$1" ] || ERRS+=("exit code: want $1 got $RC"); }

# changed_is P...: CHANGED equals exactly these paths (relative to T); no argument means nothing changed.
# shellcheck disable=SC2119,SC2120 # the argument-less call is the nothing-changed form
# The desktop entry and icon a complete install writes (and the directories above them) are left out of the comparison; tests/phase6.sh checks them.
changed_is() {
  local want got p kept=()
  for p in "${CHANGED[@]}"; do
    case $p in
      home/.local/share | home/.local/share/applications | home/.local/share/applications/* | home/.local/share/icons | home/.local/share/icons/*) ;;
      *) kept+=("$p") ;;
    esac
  done
  want=$(printf '%s\n' "$@" | LC_ALL=C sort)
  got=$(printf '%s\n' "${kept[@]}" | LC_ALL=C sort)
  [ "$#" -gt 0 ] || want=''
  [ "${#kept[@]}" -gt 0 ] || got=''
  [ "$want" = "$got" ] || ERRS+=("changed paths: want [$(tr '\n' ' ' <<< "$want")] got [$(tr '\n' ' ' <<< "$got")]")
}

# curl_only_latest_json: curl ran once, for latest.json, with a 5 s bound.
curl_only_latest_json() {
  local n=0
  [ ! -f "$T/marks/curl" ] || n=$(grep -c . "$T/marks/curl")
  [ "$n" = 1 ] || ERRS+=("curl calls: want 1 got $n")
  grep -q 'latest\.json' "$T/marks/curl" 2> /dev/null && grep -qe '--max-time 5 ' "$T/marks/curl" || ERRS+=('curl was not the latest.json GET with --max-time 5')
}

# curl_calls N: curl ran exactly N times, not counting the latest.json read.
curl_calls() {
  local n=0
  # install also reads latest.json; the Proton call counts keep their meaning
  [ ! -f "$T/marks/curl" ] || n=$(grep -vc 'launcher-e-release' "$T/marks/curl")
  [ "$n" = "$1" ] || ERRS+=("curl calls: want $1 got $n")
}

# build_ok DIR: DIR holds proton, compatibilitytool.vdf, version and files/.
build_ok() {
  [ -f "$1/proton" ] && [ -f "$1/compatibilitytool.vdf" ] && [ -f "$1/version" ] && [ -d "$1/files" ] || ERRS+=("incomplete build: $1")
}

# unchanged_games: games.json is byte-equal to the pre-run copy and no backup exists.
unchanged_games() {
  cmp -s "$T/orig-games.json" "$T/home/.local/share/faugus-launcher/games.json" || ERRS+=('games.json changed')
  compgen -G "$T/home/.local/state/w3c-linux/games.json.*.bak" > /dev/null && ERRS+=('a backup exists')
  return 0
}

# ---------- cases ----------

t_install_fresh() {
  local c=$T/home/.local/share/Steam/compatibilitytools.d gj=$T/home/.local/share/faugus-launcher/games.json
  local ws=$T/home/.local/state/w3c-linux sp8='        ' d baks
  mk_release "$T"
  FEED=$'y\ny\ny\n'
  run "$T" install
  rc_is 0
  err_has "Download $TAG (about 1.1 GB) into"
  err_has "Switch Faugus's Battle.net runner to $TAG?"
  out_has "Install complete: Battle.net runs on $TAG"
  out_has "Verified: $TAG.tar.gz: OK"
  build_ok "$c/$TAG"
  [ "$(cat "$ws/proton-tag" 2> /dev/null)" = "$TAG" ] || ERRS+=('proton-tag does not hold exactly the tag')
  baks=("$ws"/games.json.*.bak)
  if [ "${#baks[@]}" -eq 1 ] && [ -f "${baks[0]}" ]; then
    cmp -s "${baks[0]}" "$T/orig-games.json" || ERRS+=('backup differs from the pre-run games.json')
  else
    ERRS+=("want exactly one backup, got ${#baks[@]}")
  fi
  d=$(diff "$T/orig-games.json" "$gj" | grep -E '^[<>]')
  [ "$d" = "$(printf '< %s"runner": "Proton-GE Latest",\n> %s"runner": "%s",' "$sp8" "$sp8" "$TAG")" ] || ERRS+=("games.json diff is not the runner line only: $d")
  [ "$(stat -c %a "$gj")" = 600 ] || ERRS+=("games.json mode is $(stat -c %a "$gj")")
  [ -z "$(find "$T/home/.cache/w3c-linux" \( -name '*.tar.gz' -o -name SHA256SUMS \) 2> /dev/null)" ] || ERRS+=('the cache dir still holds a download')
  ! compgen -G "$c/.w3c-staging.*" > /dev/null || ERRS+=('a staging dir is left')
  curl_calls 3
}

t_busy_battlenet() {
  mk_release "$T"
  mk_installed "$T"
  printf '%s\n' '4242|Battle.net.exe|C:\Program Files (x86)\Battle.net\Battle.net.exe' > "$T/fix/procs"
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 1
  err_has $'Still running:\n\n    Battle.net'
  unchanged_games
}

# idle_switches: the idle state let the switch through; yes at prompts 1 and 4.
idle_switches() {
  mk_release "$T"
  mk_installed "$T"
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 0
  out_has 'Battle.net runner switched'
  out_has "$TAG"
  cmp -s "$T/orig-games.json" "$T/home/.local/share/faugus-launcher/games.json" && ERRS+=('games.json was not switched')
  return 0
}

# busy_blocks LABEL: install exits 1 naming LABEL; games.json is byte-unchanged and no backup exists.
busy_blocks() {
  mk_release "$T"
  mk_installed "$T"
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 1
  err_has "$1"
  unchanged_games
}

t_idle_clear() { idle_switches; }
t_idle_running_empty() { set_running_games "$T" '{}'; idle_switches; }
t_idle_backup_daemon() { add_proc "$T" 300 python3 'python3 -m faugus.backup_daemon --daemon'; idle_switches; }
t_idle_other_wineserver() { add_wineserver "$T" 301 server-801-deadbeef; idle_switches; }

t_busy_tray() { add_proc "$T" 300 python3 'python3 -m faugus.tray_only'; busy_blocks '    Faugus (main window or tray icon)'; }
t_busy_launcher() { add_proc "$T" 300 python3 'python3 -m faugus.launcher'; busy_blocks '    Faugus (main window or tray icon)'; }
t_busy_runner() { add_proc "$T" 300 python3 'python3 -m faugus.runner'; busy_blocks '    a game started through Faugus (faugus.runner)'; }
t_busy_running_games() { set_running_games "$T" '{"battlenet": {"pid": 4242}}'; busy_blocks '    a game Faugus lists as running (running-games.json)'; }
t_busy_running_garbage() { set_running_games "$T" 'not json'; busy_blocks '    a game Faugus lists as running (running-games.json)'; }
t_busy_wineserver() {
  add_wineserver "$T" 301 server-801-deadbeef
  add_wineserver "$T" 302 "$(prefix_server_name "$T")"
  busy_blocks '    a Wine process in the Battle.net prefix is still running (wineserver)'
}
t_busy_pgrep_rc() { printf '2\n' > "$T/fix/pgrep-rc"; busy_blocks 'cannot check processes (pgrep exit 2)'; }
# pgrep is a required tool (WR-04): install fails at check_host, before any prompt or download
t_busy_pgrep_missing() {
  mk_release "$T"
  mk_installed "$T"
  rm "$T/bin/pgrep"
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 1
  out_has 'missing: pgrep'
  curl_calls 0
  unchanged_games
}
t_busy_two_causes() {
  add_proc "$T" 300 python3 'python3 -m faugus.tray_only'
  add_proc "$T" 4242 Battle.net.exe 'C:\Program Files (x86)\Battle.net\Battle.net.exe'
  busy_blocks $'    Faugus (main window or tray icon)\n    Battle.net'
}

# t_list_layout: the busy list is lead, blank, 4-space items, blank, next line; prompt 1 is the same shape; no dash bullets.
t_list_layout() {
  add_proc "$T" 300 python3 'python3 -m faugus.tray_only'
  add_proc "$T" 4242 Battle.net.exe 'C:\Program Files (x86)\Battle.net\Battle.net.exe'
  busy_blocks $'Still running:\n\n    Faugus (main window or tray icon)\n    Battle.net\n\nClose them (nothing is closed for you)'
  err_has "$(prompt_text)"
  grep -q '^  -' <<< "$ERR" && ERRS+=('old dash bullet still printed')
}

# ---------- wait loop (prompt 2) ----------

t_wait_recheck() {
  local n
  mk_release "$T"
  mk_installed "$T"
  ALLOW_EXTRA=(fix/procs)
  add_proc "$T" 4242 Battle.net.exe 'C:\Program Files (x86)\Battle.net\Battle.net.exe'
  run_fifo "$T" install
  send $'y\n'
  wait_err "Switch Faugus's Battle.net runner"
  send $'y\n'
  wait_err 'press Enter to check again'
  : > "$T/fix/procs"
  send $'\n'
  finish
  rc_is 0
  out_has 'Battle.net runner switched'
  n=$(grep -c 'Still running:' <<< "$ERR")
  [ "$n" = 1 ] || ERRS+=("want the list once, got $n")
}

t_wait_still_busy() {
  local n
  mk_release "$T"
  mk_installed "$T"
  add_proc "$T" 4242 Battle.net.exe 'C:\Program Files (x86)\Battle.net\Battle.net.exe'
  run_fifo "$T" install
  send $'y\n'
  wait_err "Switch Faugus's Battle.net runner"
  send $'y\n'
  wait_err 'press Enter to check again'
  send $'\n'
  wait_err 'press Enter to check again' 2
  send $'q\n'
  finish
  rc_is 1
  n=$(grep -c 'Still running:' <<< "$ERR")
  [ "$n" = 2 ] || ERRS+=("want the list twice, got $n")
  unchanged_games
}

t_wait_quit() {
  mk_release "$T"
  mk_installed "$T"
  add_proc "$T" 4242 Battle.net.exe 'C:\Program Files (x86)\Battle.net\Battle.net.exe'
  FEED=$'y\ny\nq\n'
  run "$T" install
  rc_is 1
  out_has 'Stopped while waiting; games.json and the prefix were not changed.'
  unchanged_games
}

t_wait_eof() {
  mk_release "$T"
  mk_installed "$T"
  add_proc "$T" 4242 Battle.net.exe 'C:\Program Files (x86)\Battle.net\Battle.net.exe'
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 1
  err_has 'no answer (stdin closed); run in a terminal'
  unchanged_games
}

t_wait_zenity() {
  mk_release "$T"
  mk_installed "$T"
  add_proc "$T" 4242 Battle.net.exe 'C:\Program Files (x86)\Battle.net\Battle.net.exe'
  cat > "$T/bin/zenity" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$MARK/zenity"
case "$*" in *'Still running'*) exit 1 ;; esac
exit 0
SH
  chmod +x "$T/bin/zenity"
  CASE_ENV=(DISPLAY=:0)
  run "$T" install
  rc_is 1
  grep -qxF '    Battle.net' "$T/marks/zenity" 2> /dev/null || ERRS+=('the zenity question does not name Battle.net')
  case $ERR in *'[Y/n]'* | *'press Enter'*) ERRS+=('terminal prompt shown next to zenity') ;; esac
  unchanged_games
}

t_wait_recheck_before_write() {
  mk_release "$T"
  mk_installed "$T"
  add_proc "$T" 4242 Battle.net.exe 'C:\Program Files (x86)\Battle.net\Battle.net.exe'
  mv "$T/fix/procs" "$T/fix/procs.late"
  printf '1\n' > "$T/fix/late-after"
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 1
  err_has $'Still running:\n\n    Battle.net'
  out_has 'install: something started again (listed above); games.json was not changed'
  unchanged_games
}

# ---------- order (D-01) ----------

t_order_download_while_busy() {
  mk_release "$T"
  add_proc "$T" 4242 Battle.net.exe 'C:\Program Files (x86)\Battle.net\Battle.net.exe'
  FEED=$'y\ny\ny\n'
  run "$T" install
  rc_is 1
  build_ok "$T/home/.local/share/Steam/compatibilitytools.d/$TAG"
  [ "$(cat "$T/home/.local/state/w3c-linux/proton-tag" 2> /dev/null)" = "$TAG" ] || ERRS+=('proton-tag does not hold the tag')
  err_has 'no answer (stdin closed); run in a terminal'
  unchanged_games
  curl_calls 3
}

# ---------- prompt 1 acceptance ----------

# prompt_text: the prompt 1 block the healthy fixture must produce on stderr.
prompt_text() {
  printf 'Found Faugus Battle.net:\n\n    prefix %s\n    runner Proton-GE Latest\n    Warcraft III 3.0.0.24268\n    Battle.net present\n\nContinue? [Y/n]' \
    "$(realpath "$T/home/Faugus/battlenet")"
}

# stops_at_prompt3: prompt 1 was accepted and the run stopped after the API call because prompt 3 was answered no; nothing changed.
stops_at_prompt3() {
  rc_is 0
  err_has "$(prompt_text)"
  err_has "Download $TAG"
  out_has 'Nothing was changed; rerun install when ready.'
  ! grep -qE '^(pass|skip)  ' <<< "$OUT" || ERRS+=('install printed a pass or skip line')
  changed_is
  curl_calls 1
}

t_prompt1_yes() {
  mk_release "$T"
  FEED=$'y\nn\n'
  run "$T" install
  stops_at_prompt3
}

t_prompt1_default() {
  mk_release "$T"
  FEED=$'\nn\n'
  run "$T" install
  stops_at_prompt3
}

t_prompt1_answers() {
  local a
  for a in Y yes YES; do
    rm -f "$T/marks/curl"
    mk_release "$T"
    FEED=$a$'\nn\n'
    run "$T" install
    stops_at_prompt3
  done
}

t_prompt1_reask() {
  local n
  mk_release "$T"
  FEED=$'maybe\ny\nn\n'
  run "$T" install
  rc_is 0
  n=$(grep -o 'Continue? \[Y/n\]' <<< "$ERR" | wc -l)
  [ "$n" = 2 ] || ERRS+=("want the question twice, got $n")
  err_has "Download $TAG"
}

t_prompt1_no_newline() {
  mk_release "$T"
  FEED=y
  run "$T" install
  rc_is 1
  err_has "Download $TAG"
  err_has 'no answer (stdin closed); run in a terminal'
  changed_is
}

t_prompt1_zenity_wayland() {
  local n
  # shellcheck disable=SC2016 # the shim text is written literally and expanded when the shim runs
  # a shim that logs its arguments and answers No to the launch question (prompt 10), Yes to the rest
  printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$0 $*" >> "$MARK/zenity"' 'case "$*" in *"Launch now?"*) exit 1 ;; esac' 'exit 0' > "$T/bin/zenity"
  chmod +x "$T/bin/zenity"
  CASE_ENV=(WAYLAND_DISPLAY=wayland-1)
  mk_release "$T"
  run "$T" install
  rc_is 0
  out_has "Install complete: Battle.net runs on $TAG"
  n=$(grep -c -- '--question' "$T/marks/zenity" 2> /dev/null)
  [ "${n:-0}" = 4 ] || ERRS+=("want 4 zenity questions (prompts 1, 3, 4 and 10), got ${n:-0}")
  grep -qF 'Launch now?' "$T/marks/zenity" 2> /dev/null || ERRS+=('prompt 10 was not asked through zenity')
  case $ERR in *'[Y/n]'*) ERRS+=('terminal prompt shown next to zenity') ;; esac
}

# A terminal on stdin wins over zenity even with a display: script(1) gives the run a pty.
t_prompt_terminal_over_zenity() {
  local cmd
  type -P script > /dev/null || { ERRS+=('script (util-linux) is missing; the case needs a pty'); return; }
  add_shim "$T" zenity 0
  snap "$T" > "$TMPROOT/snap.before"
  cmd=$(printf '%q ' env -i HOME="$T/home" PATH="$T/bin" MARK="$T/marks" FIX="$T/fix" W3C_PTRACE_SCOPE_FILE="$T/ptrace_scope" \
    W3C_PROC_DIR="$T/proc" W3C_FAUGUS_PY_DIR="$T/faugus-py" DISPLAY=:0 "$BASH_BIN" "$SCRIPT" install)
  printf 'n\n' | script -qec "$cmd" /dev/null > "$TMPROOT/out" 2> "$TMPROOT/err"
  RC=$?
  post_run "$T"
  rc_is 0
  out_has '[Y/n]'
  [ ! -e "$T/marks/zenity" ] || ERRS+=('zenity ran although stdin is a terminal')
}

# ---------- release resolution (PRT-02, D-09) ----------

# resolve_rejects PYTHON: the mutated release makes install stop after the one API call with the named message and no change.
resolve_rejects() {
  mk_release "$T"
  set_latest "$T" "$1"
  FEED=$'y\n'
  run "$T" install
  rc_is 1
  out_has 'install: cannot resolve the latest patched Proton release ('
  out_has '); nothing was changed'
  curl_calls 1
  changed_is
}

t_resolve_tag_dotdot_path() { resolve_rejects "r['tag_name'] = '../x'"; }
t_resolve_tag_slash() { resolve_rejects "r['tag_name'] = 'a/b'"; }
t_resolve_tag_dot() { resolve_rejects "r['tag_name'] = '.'"; }
t_resolve_tag_dotdot() { resolve_rejects "r['tag_name'] = '..'"; }
t_resolve_tag_empty() { resolve_rejects "r['tag_name'] = ''"; }
t_resolve_tag_dash() { resolve_rejects "r['tag_name'] = '-x'"; }
t_resolve_tag_nonascii() { resolve_rejects "r['tag_name'] = 'GE-Próton11-7-W3C'"; }
t_resolve_tag_missing() { resolve_rejects "del r['tag_name']"; }
t_resolve_tag_number() { resolve_rejects "r['tag_name'] = 7"; }
t_resolve_no_sums() { resolve_rejects "del a[2]"; }
t_resolve_no_tarball() { resolve_rejects "del a[0]"; }
t_resolve_two_tarballs() { resolve_rejects "a.append({'name': 'other.tar.gz', 'size': 1, 'browser_download_url': base + tag + '/other.tar.gz'})"; }
t_resolve_asset_slash() { resolve_rejects "a[0]['name'] = 'x/' + a[0]['name']; a[0]['browser_download_url'] = base + tag + '/' + a[0]['name']"; }
t_resolve_url_host() { resolve_rejects "a[0]['browser_download_url'] = 'https://evil.example/davex32/proton-ge-w3c/releases/download/' + tag + '/' + a[0]['name']"; }
t_resolve_url_http() { resolve_rejects "a[0]['browser_download_url'] = 'http' + a[0]['browser_download_url'][5:]"; }
t_resolve_url_other_tag() { resolve_rejects "a[0]['browser_download_url'] = base + 'GE-Proton11-6-W3C/' + a[0]['name']"; }

# resolve_rejects_raw BODY: T/fix/latest holds BODY literally.
resolve_rejects_raw() {
  mk_release "$T"
  printf '%s' "$1" > "$T/fix/latest"
  FEED=$'y\n'
  run "$T" install
  rc_is 1
  out_has 'install: cannot resolve the latest patched Proton release ('
  curl_calls 1
  changed_is
}

t_resolve_not_json() { resolve_rejects_raw 'not json'; }
t_resolve_array() { resolve_rejects_raw '[]'; }
t_resolve_empty_body() { resolve_rejects_raw ''; }

t_resolve_api_down() {
  mk_release "$T"
  rm "$T/fix/latest"
  FEED=$'y\n'
  run "$T" install
  rc_is 1
  out_has 'cannot resolve the latest patched Proton release (GitHub API unreachable or rate-limited); nothing was changed'
  curl_calls 1
  changed_is
}

t_resolve_other_tag() {
  local t8=GE-Proton11-8-W3C
  mk_release "$T" "$t8"
  FEED=$'y\ny\ny\n'
  run "$T" install
  rc_is 0
  build_ok "$T/home/.local/share/Steam/compatibilitytools.d/$t8"
  [ ! -e "$T/home/.local/share/Steam/compatibilitytools.d/$TAG" ] || ERRS+=("the default tag was installed")
  [ "$(cat "$T/home/.local/state/w3c-linux/proton-tag" 2> /dev/null)" = "$t8" ] || ERRS+=('proton-tag does not hold the other tag')
  grep -qF "\"runner\": \"$t8\"" "$T/home/.local/share/faugus-launcher/games.json" || ERRS+=('the runner was not switched to the other tag')
}

t_resolve_size_unknown() {
  mk_release "$T"
  set_latest "$T" "del a[0]['size']"
  FEED=$'y\nn\n'
  run "$T" install
  rc_is 0
  err_has '(about size unknown)'
}

t_resolve_prompt3_no() {
  mk_release "$T"
  FEED=$'y\nn\n'
  run "$T" install
  rc_is 0
  out_has 'Nothing was changed; rerun install when ready.'
  changed_is
  curl_calls 1
}

# ---------- checksum gate (PRT-03) ----------

# checksum_fails WHAT: install stopped with WHAT in the message, the download is gone and nothing was placed.
checksum_fails() {
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 1
  out_has "$1"
  cache_empty
  nothing_placed
}

# checksum_case: a release plus both sibling runners.
checksum_case() {
  mk_release "$T"
  mk_siblings "$T"
}

t_checksum_mismatch() {
  checksum_case
  printf '%s  %s.tar.gz\n' "$(printf '0%.0s' {1..64})" "$TAG" > "$T/fix/SHA256SUMS"
  mkdir -p "$T/home/.local/share/Steam/compatibilitytools.d/.w3c-staging.OLD123"
  checksum_fails 'SHA256 mismatch'
}

t_checksum_missing_line() {
  checksum_case
  head -n 1 "$T/fix/SHA256SUMS" > "$T/fix/SHA256SUMS.new"
  mv "$T/fix/SHA256SUMS.new" "$T/fix/SHA256SUMS"
  checksum_fails 'SHA256 mismatch'
}

t_checksum_empty() {
  checksum_case
  : > "$T/fix/SHA256SUMS"
  checksum_fails 'SHA256 mismatch'
}

# sha256sum -c exits 0 and prints "./<tgz>: OK" for this line; only the exact "<tgz>: OK" line passes.
t_checksum_name_mismatch() {
  local h
  checksum_case
  h=$(sha256sum "$T/fix/$TAG.tar.gz")
  printf '%s  ./%s.tar.gz\n' "${h%% *}" "$TAG" > "$T/fix/SHA256SUMS"
  checksum_fails 'SHA256 mismatch'
}

t_checksum_download_fail() {
  checksum_case
  rm "$T/fix/$TAG.tar.gz"
  checksum_fails 'download failed'
}

# ---------- extraction and placement (PRT-03, D-05 to D-08) ----------

# place_fails VARIANT [LINK_TARGET]: a tarball with a matching checksum that fails structure validation.
place_fails() {
  mk_release "$T"
  mk_siblings "$T"
  mk_bad_release "$T" "$@"
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 1
  out_has 'did not unpack to a single'
  [ -z "$(find "$T" -name 'evil' -o -name 'abs_evil*' 2> /dev/null)" ] || ERRS+=('a file named evil was written under the case tree')
  compgen -G "$TMPROOT/abs_evil_*" > /dev/null && ERRS+=('an absolute member was written outside the case tree')
  [ -f "$T/home/.cache/w3c-linux/$TAG/$TAG.tar.gz" ] && [ -f "$T/home/.cache/w3c-linux/$TAG/SHA256SUMS" ] || ERRS+=('the verified download was not kept')
  nothing_placed
}

t_place_dotdot() { place_fails dotdot; }
t_place_abs_member() { place_fails abs-member; }
t_place_wrong_toplevel() { place_fails wrong-toplevel; }
t_place_two_toplevels() { place_fails two-toplevels; }
t_place_missing_files() { place_fails missing-files; }
# the link points at a complete build, so only the symlink check can reject it
t_place_symlink_top() { place_fails symlink-top "$T/home/.local/share/Steam/compatibilitytools.d/GE-Proton11-WC3-CertFix"; }

t_place_stale_staging() {
  local c=$T/home/.local/share/Steam/compatibilitytools.d
  mk_release "$T"
  mkdir -p "$c/.w3c-staging.OLD123"
  : > "$c/.w3c-staging.OLD123/half"
  FEED=$'y\ny\ny\n'
  run "$T" install
  rc_is 0
  [ ! -e "$c/.w3c-staging.OLD123" ] || ERRS+=('the stale staging dir is still there')
  build_ok "$c/$TAG"
}

t_place_partial_cache() {
  local d=$T/home/.cache/w3c-linux/$TAG
  mk_release "$T"
  mkdir -p "$d"
  printf 'junk' > "$d/$TAG.tar.gz"
  printf 'junk' > "$d/SHA256SUMS"
  FEED=$'y\ny\ny\n'
  run "$T" install
  rc_is 0
  curl_calls 3
  cache_empty
  build_ok "$T/home/.local/share/Steam/compatibilitytools.d/$TAG"
}

t_place_incomplete_replaced() {
  local c=$T/home/.local/share/Steam/compatibilitytools.d
  mk_release "$T"
  mkdir -p "$c/$TAG"
  : > "$c/$TAG/marker"
  FEED=$'y\ny\ny\n'
  run "$T" install
  rc_is 0
  err_has "Download $TAG"
  build_ok "$c/$TAG"
  [ ! -e "$c/$TAG/marker" ] || ERRS+=('the marker of the incomplete dir survived')
}

t_place_present_skip() {
  mk_release "$T"
  mk_installed "$T"
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 0
  case $ERR in *"Download $TAG"*) ERRS+=('prompt 3 was shown for a complete build') ;; esac
  curl_calls 1
  out_has 'Battle.net runner switched'
}

t_place_next_run_cleans() {
  mk_release "$T"
  mk_bad_release "$T" wrong-toplevel
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 1
  [ -f "$T/home/.cache/w3c-linux/$TAG/$TAG.tar.gz" ] || ERRS+=('the verified download was not kept for diagnosis')
  mk_release "$T"
  rm -f "$T/marks/curl"
  FEED=$'y\ny\ny\n'
  run "$T" install
  rc_is 0
  curl_calls 3
  cache_empty
  build_ok "$T/home/.local/share/Steam/compatibilitytools.d/$TAG"
}

# ---------- reruns and offline (D-10 to D-12, D-14) ----------

# has_row STATUS LABEL TEXT: OUT holds a report line with that status and label whose value contains TEXT.
has_row() {
  local ln pre
  pre=$(printf '%s  %-16s  ' "$1" "$2")
  while IFS= read -r ln; do
    case $ln in "$pre"*"$3"*) return 0 ;; esac
  done <<< "$OUT"
  ERRS+=("no $1 $2 row containing: $3")
}

# seed_tag T TAG: the state file install writes (the first line is the tag).
seed_tag() {
  mkdir -p "$1/home/.local/state/w3c-linux"
  printf '%s\n' "$2" > "$1/home/.local/state/w3c-linux/proton-tag"
}

# tag_is TAG: the recorded build.
tag_is() {
  [ "$(cat "$T/home/.local/state/w3c-linux/proton-tag" 2> /dev/null)" = "$1" ] || ERRS+=("proton-tag does not hold $1")
}

# switched: games.json now names the recorded build as the runner.
switched() {
  grep -qF "\"runner\": \"$TAG\"" "$T/home/.local/share/faugus-launcher/games.json" || ERRS+=('the runner was not switched')
}

t_rerun_noop() {
  local gj=$T/home/.local/share/faugus-launcher/games.json baks
  mk_release "$T"
  FEED=$'y\ny\ny\n'
  run "$T" install
  rc_is 0
  cp "$gj" "$TMPROOT/after-first.json"
  rm -f "$T/marks/curl" "$T/marks/pgrep"
  FEED=$'y\n'
  run "$T" install
  rc_is 0
  has_row pass runner "already $TAG"
  case $ERR in *'Download '* | *'Switch Faugus'*) ERRS+=('a prompt after prompt 1 was shown') ;; esac
  curl_calls 1
  [ ! -e "$T/marks/pgrep" ] || ERRS+=('pgrep ran on the rerun')
  cmp -s "$TMPROOT/after-first.json" "$gj" || ERRS+=('games.json changed on the rerun')
  baks=("$T"/home/.local/state/w3c-linux/games.json.*.bak)
  [ "${#baks[@]}" = 1 ] || ERRS+=("want one backup, got ${#baks[@]}")
  changed_is
}

t_rerun_newer() {
  local t8=GE-Proton11-8-W3C
  mk_release "$T"
  FEED=$'y\ny\ny\n'
  run "$T" install
  rc_is 0
  mk_release "$T" "$t8"
  rm -f "$T/marks/curl"
  FEED=$'y\n'
  run "$T" install
  rc_is 0
  out_has "newer tag $t8 available: run w3c-linux.sh update"
  [ ! -e "$T/home/.local/share/Steam/compatibilitytools.d/$t8" ] || ERRS+=("$t8 was downloaded")
  tag_is "$TAG"
  curl_calls 1
  changed_is
}

t_offline_recorded() {
  mk_installed "$T"
  seed_tag "$T" "$TAG"
  rm "$T/fix/latest" 2> /dev/null
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 0
  has_row warn 'w3c build' 'could not check for a newer build'
  out_has "using the recorded $TAG"
  out_has 'Battle.net runner switched'
  switched
  curl_calls 1
}

t_offline_nothing() {
  mk_release "$T"
  rm "$T/fix/latest"
  FEED=$'y\n'
  run "$T" install
  rc_is 1
  out_has 'cannot resolve the latest patched Proton release'
  changed_is
}

t_rerun_present_unrecorded() {
  mk_release "$T"
  mk_installed "$T"
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 0
  case $ERR in *'Download '*) ERRS+=('prompt 3 was shown for a complete build') ;; esac
  tag_is "$TAG"
  switched
  curl_calls 1
}

t_rerun_record_invalid() {
  mk_release "$T"
  seed_tag "$T" '../evil'
  FEED=$'y\ny\ny\n'
  run "$T" install
  rc_is 0
  err_has "Download $TAG"
  tag_is "$TAG"
  build_ok "$T/home/.local/share/Steam/compatibilitytools.d/$TAG"
  switched
}

t_rerun_record_incomplete() {
  local c=$T/home/.local/share/Steam/compatibilitytools.d
  mk_release "$T"
  mk_installed "$T"
  rm -r "${c:?}/$TAG/files"
  seed_tag "$T" "$TAG"
  FEED=$'y\ny\ny\n'
  run "$T" install
  rc_is 0
  err_has "Download $TAG"
  build_ok "$c/$TAG"
  switched
}

t_rerun_declined_switch() {
  mk_release "$T"
  FEED=$'y\ny\nn\n'
  run "$T" install
  rc_is 0
  out_has 'Battle.net runner not switched; rerun install when ready.'
  build_ok "$T/home/.local/share/Steam/compatibilitytools.d/$TAG"
  tag_is "$TAG"
  unchanged_games
  rm -f "$T/marks/curl"
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 0
  out_has 'Battle.net runner switched'
  switched
  curl_calls 1
}

# ---------- doctor rows for the W3C build (PRT-06, D-13) ----------

# bn_set4 T KEY VALUE: rewrites one battlenet field the way Faugus writes games.json (indent 4, ensure_ascii False, no trailing newline, mode kept).
bn_set4() {
  python3 - "$1/home/.local/share/faugus-launcher/games.json" "$2" "$3" <<'PY'
import json, os, sys
f, k, v = sys.argv[1:4]
mode = os.stat(f).st_mode & 0o7777
with open(f, encoding="utf-8") as fh:
    data = json.load(fh)
for e in data:
    if e.get("gameid") == "battlenet":
        e[k] = v
with open(f, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=4, ensure_ascii=False)
os.chmod(f, mode)
PY
  cp "$1/home/.local/share/faugus-launcher/games.json" "$1/orig-games.json"
}

# bn_dup4 T: duplicates the battlenet entry the way Faugus writes games.json, so the file holds two of them.
bn_dup4() {
  python3 - "$1/home/.local/share/faugus-launcher/games.json" <<'PY'
import copy, json, os, sys
f = sys.argv[1]
mode = os.stat(f).st_mode & 0o7777
with open(f, encoding="utf-8") as fh:
    data = json.load(fh)
data.append(copy.deepcopy(next(e for e in data if e.get("gameid") == "battlenet")))
with open(f, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=4, ensure_ascii=False)
os.chmod(f, mode)
PY
  cp "$1/home/.local/share/faugus-launcher/games.json" "$1/orig-games.json"
}

# lib_line T RUNNER: the host path Proton writes as config_info line 3 for RUNNER.
lib_line() { printf '%s/home/.local/share/Steam/compatibilitytools.d/%s/files/lib/' "$1" "$2"; }

# mk_prefix_state T VERSION LINE3: what Proton leaves in the prefix after a start.
mk_prefix_state() {
  local p=$1/home/Faugus/battlenet
  printf '%s\n' "$2" > "$p/version"
  printf '%s\n' '7.0-1' '/usr/share/default_pfx/' "$3" > "$p/config_info"
}

# doctor_run: doctor exits 0, makes exactly one network call (the latest.json GET), never lists processes and changes no path.
doctor_run() {
  run "$T" doctor
  rc_is 0
  curl_only_latest_json
  [ ! -e "$T/marks/pgrep" ] || ERRS+=('doctor ran pgrep')
  changed_is
}

t_doctor_fresh() {
  doctor_run
  has_row warn 'w3c build' 'none recorded: run w3c-linux.sh install'
  has_row warn 'runner build' 'Proton-GE Latest is not a recorded W3C build: run w3c-linux.sh install'
  has_row pass 'runner dir' 'Proton-GE Latest: managed by Faugus (downloaded on first use)'
  has_row warn 'prefix version' 'absent: start Battle.net once via Faugus'
  has_row skip 'prefix runner' 'needs: config_info (start Battle.net once via Faugus)'
}

t_doctor_switched() {
  local c=$T/home/.local/share/Steam/compatibilitytools.d
  mk_installed "$T"
  seed_tag "$T" "$TAG"
  bn_set4 "$T" runner "$TAG"
  mk_prefix_state "$T" GE-Proton11-7 "$(lib_line "$T" "$TAG")"
  doctor_run
  has_row pass 'w3c build' "$TAG (recorded)"
  has_row pass 'runner build' "$TAG"
  has_row pass 'runner dir' "$c/$TAG"
  has_row pass 'prefix version' 'GE-Proton11-7 (Proton prefix format, same for stock and W3C builds)'
  has_row pass 'prefix runner' "$TAG (config_info line 3)"
  ! grep -v '^warn  desktop entry ' <<< "$OUT" | grep -q '^warn' || ERRS+=("a warn row is printed: $(grep -v '^warn  desktop entry ' <<< "$OUT" | grep '^warn')")
}

t_doctor_not_started() {
  mk_installed "$T"
  seed_tag "$T" "$TAG"
  bn_set4 "$T" runner "$TAG"
  mk_prefix_state "$T" GE-Proton11-7 "$(lib_line "$T" 'Proton-GE Latest')"
  doctor_run
  has_row warn 'prefix runner' "last touched by Proton-GE Latest, not $TAG: start Battle.net once via Faugus"
}

t_doctor_reverted_kept() {
  mk_installed "$T"
  seed_tag "$T" "$TAG"
  doctor_run
  has_row warn 'runner build' "Proton-GE Latest, expected $TAG: W3C build $TAG installed: w3c-linux.sh install to switch back"
}

t_doctor_differs_missing() {
  seed_tag "$T" "$TAG"
  bn_set4 "$T" runner GE-Proton-Other
  doctor_run
  has_row warn 'runner build' "GE-Proton-Other, expected $TAG: run w3c-linux.sh install"
}

t_doctor_runner_dir_missing() {
  local c=$T/home/.local/share/Steam/compatibilitytools.d
  bn_set4 "$T" runner "$TAG"
  doctor_run
  has_row warn 'runner dir' "missing: $c/$TAG (Faugus would show \"$TAG was not found\"): run w3c-linux.sh install"
}

t_doctor_runner_dir_incomplete() {
  local c=$T/home/.local/share/Steam/compatibilitytools.d
  mk_installed "$T"
  rm -r "${c:?}/$TAG/files"
  bn_set4 "$T" runner "$TAG"
  doctor_run
  has_row warn 'runner dir' "incomplete: $c/$TAG (needs proton, compatibilitytool.vdf, version, files/): rerun w3c-linux.sh install"
}

t_doctor_record_invalid() {
  seed_tag "$T" '../x'
  doctor_run
  has_row warn 'w3c build' "unreadable record $T/home/.local/state/w3c-linux/proton-tag: rerun w3c-linux.sh install"
}

t_doctor_empty_runner() {
  bn_set4 "$T" runner ''
  mk_prefix_state "$T" GE-Proton11-7 "$(lib_line "$T" UMU-Proton-9.0)"
  doctor_run
  has_row warn 'runner build' 'UMU-Proton Latest is not a recorded W3C build: run w3c-linux.sh install'
  has_row pass 'runner dir' 'UMU-Proton Latest: managed by Faugus (downloaded on first use)'
  has_row pass 'prefix runner' 'UMU-Proton-9.0 (config_info line 3)'
}

t_doctor_leftover_not_w3c() {
  fill_build "$T/home/.local/share/Steam/compatibilitytools.d/GE-Proton11-WC3-CertFix" GE-Proton11-WC3-CertFix
  doctor_run
  has_row warn 'w3c build' 'none recorded: run w3c-linux.sh install'
}

t_doctor_line3_unrecognised() {
  mk_prefix_state "$T" GE-Proton11-7 /some/other/place
  doctor_run
  has_row warn 'prefix runner' 'config_info line 3 unrecognised: /some/other/place'
}

# ---------- switch: one value changes, nothing else (PRT-04, D-14, D-20) ----------

# only_runner_differs WANT: the pre-run games.json and the current one are equal after parse except the battlenet runner (now WANT),
# every entry keeps its key order, and the file keeps Faugus's serialisation (no trailing newline).
only_runner_differs() {
  local gj=$T/home/.local/share/faugus-launcher/games.json
  python3 - "$T/orig-games.json" "$gj" "$1" <<'PY' || ERRS+=('games.json differs from the original in more than the battlenet runner')
import json, sys
a, b, want = sys.argv[1:4]
da, db = json.load(open(a, encoding="utf-8")), json.load(open(b, encoding="utf-8"))
assert len(da) == len(db)
for x, y in zip(da, db):
    assert list(x.keys()) == list(y.keys())
    if x.get("gameid") == "battlenet":
        assert y["runner"] == want
        x, y = dict(x, runner=None), dict(y, runner=None)
    assert x == y
assert not open(b, "rb").read().endswith(b"\n")
PY
}

# one_backup: exactly one games.json backup exists and it is byte-equal to the pre-run file.
one_backup() {
  local baks=("$T"/home/.local/state/w3c-linux/games.json.*.bak)
  if [ "${#baks[@]}" -eq 1 ] && [ -f "${baks[0]}" ] && [ ! -L "${baks[0]}" ]; then
    cmp -s "${baks[0]}" "$T/orig-games.json" || ERRS+=('backup differs from the pre-run games.json')
  else
    ERRS+=("want exactly one regular backup, got ${#baks[@]}")
  fi
}

t_switch_fields() {
  local gj=$T/home/.local/share/faugus-launcher/games.json
  mk_release "$T"
  FEED=$'y\ny\ny\n'
  run "$T" install
  rc_is 0
  only_runner_differs "$TAG"
  grep -qF 'Ünïcødé' "$gj" || ERRS+=('the non-ASCII title bytes changed')
  one_backup
}

t_switch_mode_644() {
  local gj=$T/home/.local/share/faugus-launcher/games.json
  chmod 644 "$gj"
  mk_release "$T"
  FEED=$'y\ny\ny\n'
  run "$T" install
  rc_is 0
  [ "$(stat -c %a "$gj")" = 644 ] || ERRS+=("games.json mode is $(stat -c %a "$gj"), want 644")
}

t_switch_no_tmp() {
  mk_release "$T"
  FEED=$'y\ny\ny\n'
  run "$T" install
  rc_is 0
  compgen -G "$T/home/.local/share/faugus-launcher/.tmp-*" > /dev/null && ERRS+=('a .tmp- file is left in the faugus-launcher directory')
  return 0
}

t_switch_empty_runner() {
  local baks
  bn_set4 "$T" runner ''
  mk_release "$T"
  FEED=$'y\ny\ny\n'
  run "$T" install
  rc_is 0
  only_runner_differs "$TAG"
  one_backup
  baks=("$T"/home/.local/state/w3c-linux/games.json.*.bak)
  python3 -c 'import json, sys; assert [e["runner"] for e in json.load(open(sys.argv[1])) if e["gameid"] == "battlenet"] == [""]' "${baks[0]}" \
    || ERRS+=('the backup does not hold the empty runner')
}

t_switch_symlink() {
  local fl=$T/home/.local/share/faugus-launcher dot=$T/home/dotfiles
  mkdir -p "$dot"
  mv "$fl/games.json" "$dot/games.json"
  ln -s "$dot/games.json" "$fl/games.json"
  ALLOW_EXTRA=(home/dotfiles/games.json)
  mk_release "$T"
  FEED=$'y\ny\ny\n'
  run "$T" install
  rc_is 0
  [ -L "$fl/games.json" ] && [ "$(readlink "$fl/games.json")" = "$dot/games.json" ] || ERRS+=('games.json is no longer the same symlink')
  grep -qF "\"runner\": \"$TAG\"" "$dot/games.json" || ERRS+=('the symlink target does not hold the new runner')
  one_backup
}

t_switch_backup_names() {
  local baks
  mk_release "$T"
  FEED=$'y\ny\ny\n'
  run "$T" install
  rc_is 0
  bn_set4 "$T" title Second
  bn_set4 "$T" runner 'Proton-GE Latest'
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 0
  baks=("$T"/home/.local/state/w3c-linux/games.json.*.bak)
  [ "${#baks[@]}" = 2 ] || ERRS+=("want 2 backups, got ${#baks[@]}")
  [ "${baks[0]}" != "${baks[1]:-}" ] || ERRS+=('backup names collide')
  grep -q '"title": "Second"' "${baks[1]:-/dev/null}" || ERRS+=('the newer backup does not sort last')
}

# prompt4_mutation CMD...: install runs up to prompt 4, CMD changes the world, then yes is answered.
prompt4_mutation() {
  ALLOW_EXTRA=(orig-games.json)   # bn_set4 and bn_dup4 refresh the pre-run copy
  mk_release "$T"
  mk_installed "$T"
  run_fifo "$T" install
  send $'y\n'
  wait_err "Switch Faugus's Battle.net runner"
  "$@"
  send $'y\n'
  finish
}

t_switch_guard_cas() {
  prompt4_mutation bn_set4 "$T" runner 'Proton-EM Latest'
  rc_is 1
  out_has 'games.json changed while install was waiting'
  grep -qF '"runner": "Proton-EM Latest"' "$T/home/.local/share/faugus-launcher/games.json" || ERRS+=('the other writer content was lost')
  unchanged_games
}

t_switch_guard_dup() {
  local n
  prompt4_mutation bn_dup4 "$T"
  rc_is 1
  n=$(grep -c '"gameid": "battlenet"' "$T/home/.local/share/faugus-launcher/games.json")
  [ "$n" = 2 ] || ERRS+=("want 2 battlenet entries, got $n")
  unchanged_games
}

t_switch_guard_incomplete() {
  local c=$T/home/.local/share/Steam/compatibilitytools.d
  prompt4_mutation rm -r "${c:?}/$TAG/files"
  rc_is 1
  out_has "$TAG is incomplete; rerun install"
  unchanged_games
}

# ---------- revert (PRT-05, D-15 to D-18) ----------

# mk_bak T STAMP RUNNER: a backup named like the script's, holding the pre-run games.json with the battlenet runner RUNNER.
# RUNNER @garbage writes a file that is not JSON.
mk_bak() {
  local d=$1/home/.local/state/w3c-linux f
  mkdir -p "$d"
  f=$d/games.json.$2.bak
  if [ "$3" = @garbage ]; then
    printf 'not json' > "$f"
    return 0
  fi
  python3 - "$1/orig-games.json" "$f" "$3" <<'PY'
import json, sys
src, dst, runner = sys.argv[1:4]
data = json.load(open(src, encoding="utf-8"))
for e in data:
    if e.get("gameid") == "battlenet":
        e["runner"] = runner
with open(dst, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=4, ensure_ascii=False)
PY
}

# other_runner T VALUE: the non-battlenet entry's runner; refreshes the pre-run copy like bn_set4.
other_runner() {
  python3 - "$1/home/.local/share/faugus-launcher/games.json" "$2" <<'PY'
import json, sys
f, v = sys.argv[1:3]
data = json.load(open(f, encoding="utf-8"))
for e in data:
    if e.get("gameid") == "other":
        e["runner"] = v
with open(f, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=4, ensure_ascii=False)
PY
  cp "$1/home/.local/share/faugus-launcher/games.json" "$1/orig-games.json"
}

# bak_count N: N games.json backups exist.
bak_count() {
  local b=("$T"/home/.local/state/w3c-linux/games.json.*.bak)
  [ -e "${b[0]}" ] || b=()
  [ "${#b[@]}" = "$1" ] || ERRS+=("want $1 backups, got ${#b[@]}")
}

# runner_is WANT: the battlenet runner in games.json.
runner_is() {
  python3 -c 'import json, sys; assert [e["runner"] for e in json.load(open(sys.argv[1], encoding="utf-8")) if e["gameid"] == "battlenet"] == [sys.argv[2]]' \
    "$T/home/.local/share/faugus-launcher/games.json" "$1" 2> /dev/null || ERRS+=("the battlenet runner is not '$1'")
}

# w3c_on: the state the user is in after install: the build present and recorded, Battle.net on it, one older backup.
w3c_on() {
  mk_installed "$T"
  seed_tag "$T" "$TAG"
  bn_set4 "$T" runner "$TAG"
  mk_bak "$T" 20260101-000000-100000 'Proton-GE Latest'
}

t_revert_roundtrip() {
  local c=$T/home/.local/share/Steam/compatibilitytools.d
  mk_release "$T"
  FEED=$'y\ny\ny\n'
  run "$T" install
  rc_is 0
  FEED=$'y\n\n'
  run "$T" revert
  rc_is 0
  cmp -s "$T/orig-games.json" "$T/home/.local/share/faugus-launcher/games.json" || ERRS+=('games.json is not byte-equal to the pre-install file')
  build_ok "$c/$TAG"
  tag_is "$TAG"
  bak_count 2
}

t_revert_newest_non_w3c() {
  w3c_on
  mk_bak "$T" 20260101-000000-200000 "$TAG"
  mk_bak "$T" 20260101-000000-300000 'Foo-W3C'
  mk_bak "$T" 20260101-000000-400000 @garbage
  FEED=$'y\n\n'
  run "$T" revert
  rc_is 0
  runner_is 'Proton-GE Latest'
}

t_revert_newer_non_w3c_wins() {
  w3c_on
  mk_bak "$T" 20260101-000000-050000 'Proton-EM Latest'
  mk_bak "$T" 20260101-000000-150000 'Proton-CachyOS Latest'
  FEED=$'y\n\n'
  run "$T" revert
  rc_is 0
  runner_is 'Proton-CachyOS Latest'
}

t_revert_empty_runner() {
  bn_set4 "$T" runner ''
  mk_release "$T"
  FEED=$'y\ny\ny\n'
  run "$T" install
  rc_is 0
  FEED=$'y\n\n'
  run "$T" revert
  rc_is 0
  cmp -s "$T/orig-games.json" "$T/home/.local/share/faugus-launcher/games.json" || ERRS+=('games.json is not byte-equal to the empty-runner original')
}

t_revert_no_backup() {
  run "$T" revert
  rc_is 1
  out_has 'revert: Battle.net runs on Proton-GE Latest, not a W3C build; nothing to revert'
  changed_is
  bn_set4 "$T" runner "$TAG"
  mk_bak "$T" 20260101-000000-100000 "$TAG"
  mk_bak "$T" 20260101-000000-200000 'Foo-W3C'
  run "$T" revert
  rc_is 1
  out_has 'revert: no backup with a non-W3C Battle.net runner in'
  changed_is
}

t_revert_prompt_wording() {
  w3c_on
  FEED=$'n\n'
  run "$T" revert
  rc_is 0
  err_has "Switch Battle.net's runner from $TAG back to Proton-GE Latest? The W3Champions launcher fails VerifyJob on it. [Y/n]"
  out_has 'Nothing was changed.'
  cmp -s "$T/orig-games.json" "$T/home/.local/share/faugus-launcher/games.json" || ERRS+=('games.json changed')
  bak_count 1
}

t_revert_prompt_delete_default_no() {
  local c=$T/home/.local/share/Steam/compatibilitytools.d
  w3c_on
  FEED=$'y\n\n'
  run "$T" revert
  rc_is 0
  err_has "Remove $TAG from $c (about 1.5 GB)? w3c-linux.sh install downloads it again. [y/N]"
  out_has "Kept $TAG"
  build_ok "$c/$TAG"
  tag_is "$TAG"
}

t_revert_prompt_delete_yes() {
  local c=$T/home/.local/share/Steam/compatibilitytools.d
  w3c_on
  mk_siblings "$T"
  FEED=$'y\ny\n'
  run "$T" revert
  rc_is 0
  [ ! -e "$c/$TAG" ] || ERRS+=("$c/$TAG is still there")
  [ ! -e "$T/home/.local/state/w3c-linux/proton-tag" ] || ERRS+=('proton-tag is still there')
  out_has "Removed $c/$TAG and the recorded build."
  siblings_untouched
  bak_count 2
  [ -f "$T/home/.local/state/w3c-linux/games.json.20260101-000000-100000.bak" ] || ERRS+=('the seeded backup was deleted')
}

t_revert_prompt_delete_not_offered() {
  w3c_on
  other_runner "$T" "$TAG"
  mk_bak "$T" 20260101-000000-100000 'Proton-GE Latest'
  FEED=$'y\n'
  run "$T" revert
  rc_is 0
  case $ERR in *"Remove $TAG"*) ERRS+=('the delete offer was shown while another entry uses the build') ;; esac
  build_ok "$T/home/.local/share/Steam/compatibilitytools.d/$TAG"
  runner_is 'Proton-GE Latest'
}

t_revert_busy() {
  w3c_on
  add_proc "$T" 4242 Battle.net.exe 'C:\Program Files (x86)\Battle.net\Battle.net.exe'
  FEED=$'y\n'
  run "$T" revert
  rc_is 1
  err_has $'Still running:\n\n    Battle.net'
  cmp -s "$T/orig-games.json" "$T/home/.local/share/faugus-launcher/games.json" || ERRS+=('games.json changed')
  bak_count 1
}

t_revert_backs_up_current() {
  local b
  w3c_on
  FEED=$'y\n\n'
  run "$T" revert
  rc_is 0
  b=("$T"/home/.local/state/w3c-linux/games.json.*.bak)
  grep -qF "\"runner\": \"$TAG\"" "${b[${#b[@]} - 1]}" || ERRS+=('the newest backup does not hold the W3C runner')
  FEED=$'\n'
  run "$T" revert
  rc_is 1
  out_has 'revert: Battle.net runs on Proton-GE Latest, not a W3C build; nothing to revert'
  case $ERR in *"Remove $TAG from"*) ERRS+=('the remove offer was shown') ;; esac
}

t_revert_missing_original_dir() {
  w3c_on
  mk_bak "$T" 20260101-000000-500000 GE-Proton10-1
  FEED=$'y\n\n'
  run "$T" revert
  rc_is 0
  out_has 'GE-Proton10-1 is not in'
  out_has 'GE-Proton10-1 was not found'
  runner_is GE-Proton10-1
}

# ---------- dispatch and static ----------

t_dispatch_empty() {
  local s
  run "$T" ''
  rc_is 0
  for s in install launch update doctor revert monitor report; do out_has "$s"; done
}

t_static_no_eval() {
  local o
  o=$(grep -nw eval "${SOURCES[@]}")
  [ -z "$o" ] || ERRS+=("script contains the word eval: $o")
}

t_static_no_fixed_asset_url() {
  local n
  n=$(grep -h 'releases/latest/download' "${SOURCES[@]}" | grep -vc 'latest\.json')   # the mandated manifest URL is the one allowed fixed-name download
  [ "$n" = 0 ] || ERRS+=("script builds a fixed-name latest-download URL ($n lines)")
}

t_static_no_home_literal() {
  local o
  o=$(grep -nE '/home/[a-z]' "${SOURCES[@]}")
  [ -z "$o" ] || ERRS+=("script has an absolute home path: $o")
}

# The only recursive delete lives inside remove_compat_entry.
t_static_single_rm() {
  local n inside
  n=$(cat "${SOURCES[@]}" | grep -cE 'rm +-[a-zA-Z]*r')
  [ "$n" = 1 ] || ERRS+=("want one recursive rm line, got $n")
  inside=$(awk '/^remove_compat_entry\(\) \{$/ {f = 1; next} f && /^\}$/ {f = 0} f' "${SOURCES[@]}" | grep -cE 'rm +-[a-zA-Z]*r')
  [ "$inside" = 1 ] || ERRS+=('the recursive rm is not inside remove_compat_entry')
}

# ---------- gap cases: revert guards, compat dir, XDG cache ----------

# revert_to_switch_prompt: w3c_on, then revert is driven up to its switch prompt.
revert_to_switch_prompt() {
  w3c_on
  run_fifo "$T" revert
  wait_err "Switch Battle.net's runner from"
}

t_revert_recheck_before_write() {
  ALLOW_EXTRA=(fix/procs)
  revert_to_switch_prompt
  add_proc "$T" 4242 Battle.net.exe 'C:\Program Files (x86)\Battle.net\Battle.net.exe'
  send $'y\n'
  finish
  rc_is 1
  err_has $'Still running:\n\n    Battle.net'
  out_has 'revert: something started again (listed above); games.json was not changed'
  cmp -s "$T/orig-games.json" "$T/home/.local/share/faugus-launcher/games.json" || ERRS+=('games.json changed')
  bak_count 1
}

t_revert_recheck_before_delete() {
  local c=$T/home/.local/share/Steam/compatibilitytools.d
  ALLOW_EXTRA=(fix/procs)
  revert_to_switch_prompt
  send $'y\n'
  wait_err "Remove $TAG from"
  add_proc "$T" 4242 Battle.net.exe 'C:\Program Files (x86)\Battle.net\Battle.net.exe'
  send $'y\n'
  finish
  rc_is 1
  out_has "revert: something started again (listed above); $TAG was not removed"
  build_ok "$c/$TAG"
  [ -f "$T/home/.local/state/w3c-linux/proton-tag" ] || ERRS+=('proton-tag was removed')
  runner_is 'Proton-GE Latest'
}

t_revert_guard_cas() {
  ALLOW_EXTRA=(orig-games.json)
  revert_to_switch_prompt
  bn_set4 "$T" runner 'Proton-EM Latest'
  send $'y\n'
  finish
  rc_is 1
  out_has 'games.json changed while revert was waiting'
  runner_is 'Proton-EM Latest'
  bak_count 1
}

t_place_compat_absent() {
  local c=$T/home/.local/share/Steam/compatibilitytools.d
  rmdir "$c"
  mk_release "$T"
  FEED=$'y\ny\ny\n'
  run "$T" install
  rc_is 0
  build_ok "$c/$TAG"
  runner_is "$TAG"
}

t_install_xdg_cache() {
  local x=$T/xdg/cache
  CASE_ENV=("XDG_CACHE_HOME=$x")
  mk_release "$T"
  ALLOW_EXTRA=(xdg xdg/cache xdg/cache/w3c-linux "xdg/cache/w3c-linux/$TAG")
  FEED=$'y\ny\ny\n'
  run "$T" install
  rc_is 0
  out_has "Downloading $TAG.tar.gz to $x/w3c-linux/$TAG"
  [ ! -e "$T/home/.cache/w3c-linux" ] || ERRS+=('default cache dir was created')
  [ -z "$(find "$x" \( -name '*.tar.gz' -o -name SHA256SUMS \) 2> /dev/null)" ] || ERRS+=('the XDG cache still holds a download')
  build_ok "$T/home/.local/share/Steam/compatibilitytools.d/$TAG"
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
    CASE_ENV=() ERRS=() CHANGED=() ALLOW_EXTRA=()
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

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
