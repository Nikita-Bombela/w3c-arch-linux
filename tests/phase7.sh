#!/usr/bin/env bash
# Phase 7 fixture check: builds the real packaging/PKGBUILD with makepkg from a git archive of the repo, extracts the package under a temp
# root and runs usr/bin/w3c-linux from there, on the harness of tests/phase2.sh to tests/phase6.sh. One package is built per suite run (plus
# the version-mismatch build). Needs makepkg, fakeroot, bsdtar and git and a non-root user; never touches the real /usr.
# Usage: bash tests/phase7.sh [GLOB]   (GLOB filters on display names such as pkg-layout)
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=phase6.sh
source "$(dirname "${BASH_SOURCE[0]}")/phase6.sh"

# this suite has its own cases only
mapfile -t P6_CASES < <(compgen -A function t_)
unset -f "${P6_CASES[@]}"

VER=$(sed -n 's/^W3C_LINUX_VERSION=//p' "$ROOT/w3c-linux.sh")
PKG_FILE=''   # the package pkg_file built; empty until then

# ---------- helpers ----------

# pkg_make DIR VERSION: builds the PKGBUILD in DIR (out/ holds the package) from a tarball w3c-arch-linux-VERSION.tar.gz of the repo's
# tracked files, uncommitted edits included. Returns makepkg's status; its output is DIR/makepkg.log.
pkg_make() {
  local dir=$1 ver=$2 tree
  mkdir -p "$dir/out" "$dir/build"
  cp "$ROOT/packaging/PKGBUILD" "$dir/PKGBUILD"
  [ "$ver" = "$VER" ] || sed -i "s/^pkgver=.*/pkgver=$ver/" "$dir/PKGBUILD"
  # stash create packs tracked edits into an unreferenced commit without touching the working tree or the stash list
  tree=$(git -C "$ROOT" stash create)
  git -C "$ROOT" archive --format=tar.gz --prefix="w3c-arch-linux-$ver/" -o "$dir/w3c-arch-linux-$ver.tar.gz" "${tree:-HEAD}" || return 1
  # -d: faugus-launcher is an AUR package that may be absent; --check: a user makepkg.conf may disable check()
  (cd "$dir" && PKGDEST=$dir/out BUILDDIR=$dir/build SRCDEST=$dir PKGEXT=.pkg.tar makepkg -d -f --check --skipinteg) > "$dir/makepkg.log" 2>&1
}

# pkg_file: builds the package once per suite run (main runs every case in one shell) and sets PKG_FILE; returns 1 with an ERRS line on failure.
pkg_file() {
  local t missing=()
  [ -n "$PKG_FILE" ] && return 0
  for t in makepkg fakeroot bsdtar git; do type -P "$t" > /dev/null || missing+=("$t"); done
  if [ "${#missing[@]}" -gt 0 ]; then
    ERRS+=("cannot build the package, missing: ${missing[*]}")
    return 1
  fi
  if ! pkg_make "$TMPROOT/pkg" "$VER"; then
    ERRS+=("makepkg failed: $(tail -n 5 "$TMPROOT/pkg/makepkg.log" 2> /dev/null | tr '\n' '|')")
    return 1
  fi
  PKG_FILE=$(compgen -G "$TMPROOT/pkg/out/*")
}

# pkg_stage: extracts the package into $T/stage and points the run harness at its /usr/bin/w3c-linux with that root as W3C_SYS_ROOT.
# Every package-mode case starts with `local SCRIPT` (bash's dynamic scope makes the assignment below the case's own, never the global the
# next case uses) and then `pkg_stage || return 0`.
pkg_stage() {
  pkg_file || return 1
  mkdir "$T/stage"
  bsdtar -xf "$PKG_FILE" -C "$T/stage"
  SCRIPT=$T/stage/usr/bin/w3c-linux
  CASE_ENV+=("W3C_SYS_ROOT=$(realpath -- "$T/stage")")
}

# ---------- package ----------

t_pkg_help() {
  local SCRIPT
  pkg_stage || return 0
  run "$T" help
  rc_is 0
  case $OUT in "w3c-linux $VER"$'\n'*) ;; *) ERRS+=("first line is not: w3c-linux $VER") ;; esac
  out_has 'usage: w3c-linux <subcommand>'
  out_has 'New here? Run w3c-linux install once, then w3c-linux launch'
  lacks_text 'w3c-linux.sh'
  run "$T" --version
  [ "$OUT" = "w3c-linux $VER" ] || ERRS+=("--version printed: $OUT")
}

t_pkg_layout() {
  local f mode want got line m own grp path arrow tgt
  pkg_file || return 0
  want=$(
    printf '%s\n' 'lrwxrwxrwx root:root usr/bin/w3c-linux -> ../lib/w3c-linux/w3c-linux.sh' \
      '-rwxr-xr-x root:root usr/lib/w3c-linux/w3c-linux.sh' \
      '-rw-r--r-- root:root usr/share/applications/w3c-linux.desktop' \
      '-rw-r--r-- root:root usr/share/icons/hicolor/256x256/apps/w3c-linux.png'
    for f in "$ROOT"/lib/*; do
      mode=-rw-r--r--
      [ "${f##*/}" = w3c-askpass.sh ] && mode=-rwxr-xr-x
      printf '%s root:root usr/lib/w3c-linux/lib/%s\n' "$mode" "${f##*/}"
    done
  )
  got=$(
    bsdtar -tvf "$PKG_FILE" | while read -r m _ own grp _ _ _ _ path arrow tgt; do
      case $m in d*) continue ;; esac
      case $path in .PKGINFO | .BUILDINFO | .MTREE) continue ;; esac
      if [ -n "$arrow" ]; then line="$m $own:$grp $path $arrow $tgt"; else line="$m $own:$grp $path"; fi
      printf '%s\n' "$line"
    done
  )
  [ "$(LC_ALL=C sort <<< "$got")" = "$(LC_ALL=C sort <<< "$want")" ] || ERRS+=("package entries differ: got [$(tr '\n' '|' <<< "$got")] want [$(tr '\n' '|' <<< "$want")]")
  case $got in *.INSTALL*) ERRS+=('package has an install scriptlet') ;; esac
}

t_pkg_info() {
  local info d o
  pkg_file || return 0
  info=$(bsdtar -xOf "$PKG_FILE" .PKGINFO)
  for d in 'pkgname = w3c-linux' "pkgver = $VER-1" 'arch = any' 'license = GPL-3.0-or-later' 'url = https://github.com/Nikita-Bombela/w3c-arch-linux'; do
    grep -qxF "$d" <<< "$info" || ERRS+=("PKGINFO lacks: $d")
  done
  d=$(sed -n 's/^depend = //p' <<< "$info" | LC_ALL=C sort | tr '\n' ' ')
  [ "$d" = 'bash coreutils curl faugus-launcher procps-ng python tar util-linux ' ] || ERRS+=("depends are: $d")
  o=$(sed -n 's/^optdepend = \([^:]*\):.*/\1/p' <<< "$info" | LC_ALL=C sort | tr '\n' ' ')
  [ "$o" = 'desktop-file-utils icoextract imagemagick iptables libnotify nftables sudo zenity ' ] || ERRS+=("optdepends are: $o")
}

t_pkg_desktop() {
  local SCRIPT s=$ROOT/share
  pkg_stage || return 0
  cmp -s "$s/w3c-linux.desktop" "$T/stage/usr/share/applications/w3c-linux.desktop" || ERRS+=('packaged desktop entry differs from share/w3c-linux.desktop')
  grep -qxF 'Exec=w3c-linux launch' "$T/stage/usr/share/applications/w3c-linux.desktop" || ERRS+=('packaged entry lacks Exec=w3c-linux launch')
  validate_desk "$T/stage/usr/share/applications/w3c-linux.desktop"
  cmp -s "$s/w3c-linux.png" "$T/stage/usr/share/icons/hicolor/256x256/apps/w3c-linux.png" || ERRS+=('packaged icon differs from share/w3c-linux.png')
}

# a PKGBUILD pkgver that differs from the script's version must fail the build in check(), not produce a package
t_pkg_check_mismatch() {
  pkg_file || return 0
  if pkg_make "$T/mm" 9.9.9; then ERRS+=('build with a mismatched pkgver succeeded'); fi
  grep -q 'check()' "$T/mm/makepkg.log" || ERRS+=('makepkg log does not mention check()')
  [ -z "$(compgen -G "$T/mm/out/*")" ] || ERRS+=('a package was produced despite the mismatch')
}

t_pkg_static() {
  local info
  bash -n "$ROOT/packaging/PKGBUILD" || ERRS+=('PKGBUILD has a syntax error')
  info=$(cd "$ROOT/packaging" && makepkg --printsrcinfo) || ERRS+=('makepkg --printsrcinfo failed')
  case $info in *"source = w3c-arch-linux-$VER.tar.gz::https://github.com/Nikita-Bombela/w3c-arch-linux/archive/v$VER.tar.gz"*) ;; *) ERRS+=('srcinfo has not the expected source line') ;; esac
  [ ! -e "$ROOT/packaging/.SRCINFO" ] || ERRS+=('packaging/.SRCINFO exists')
  for f in packaging/src/x packaging/pkg/x "packaging/w3c-linux-$VER-1-any.pkg.tar.zst" "packaging/w3c-arch-linux-$VER.tar.gz"; do
    git -C "$ROOT" check-ignore -q "$f" || ERRS+=("not git-ignored: $f")
  done
  case $(head -n 1 "$ROOT/LICENSE") in *'GNU GENERAL PUBLIC LICENSE'*) ;; *) ERRS+=('LICENSE is not the GPL text') ;; esac
}

# ---------- version ----------

t_version_pkgver() {
  [ "$VER" = 0.1.0 ] || ERRS+=("W3C_LINUX_VERSION is $VER, not 0.1.0")
  grep -qx "pkgver=$VER" "$ROOT/packaging/PKGBUILD" || ERRS+=('PKGBUILD pkgver differs from W3C_LINUX_VERSION')
}

t_version_flags() {
  local a
  for a in --version -V version; do
    run "$T" "$a"
    rc_is 0
    [ "$OUT" = "w3c-linux $VER" ] || ERRS+=("$a printed: $OUT")
    [ -z "$ERR" ] || ERRS+=("$a wrote to stderr: $ERR")
  done
}

t_version_usage() {
  local first
  run "$T" help
  first=${OUT%%$'\n'*}
  [ "$first" = "w3c-linux $VER" ] || ERRS+=("usage starts with: $first")
  case $OUT in *$'\n  version'*) ;; *) ERRS+=('usage lists no version row') ;; esac
  run "$T" bogus
  rc_is 2
  case $ERR in *$'w3c-linux '"$VER"$'\n'*'usage: w3c-linux.sh <subcommand>'*) ;; *) ERRS+=('unknown subcommand does not print usage on stderr') ;; esac
}

t_version_no_banner() {
  local cmd o
  if ! type -P script > /dev/null; then
    ERRS+=('script (util-linux) missing')
    return 0
  fi
  cmd=$(printf '%q ' env -i HOME="$T/home" PATH="$T/bin" "$BASH_BIN" "$SCRIPT" --version)
  o=$(script -qec "$cmd" /dev/null < /dev/null)
  o=${o//$'\r'/}
  [ "$o" = "w3c-linux $VER" ] || ERRS+=("pty --version printed: $o")
  case $o in *'██'*) ERRS+=('pty --version printed the banner') ;; esac
}

# ---------- layout ----------

# the command name comes from where the script lives, not from $0: a symlink to the package's symlink prints the same
t_layout_symlink_chain() {
  local SCRIPT
  pkg_stage || return 0
  mkdir "$T/elsewhere"
  ln -s "$T/stage/usr/bin/w3c-linux" "$T/elsewhere/w3c"
  SCRIPT=$T/elsewhere/w3c
  run "$T" help
  rc_is 0
  out_has 'usage: w3c-linux <subcommand>'
}

t_layout_static() {
  local n o
  # shellcheck disable=SC2016 # literal text of the script lines
  n=$(grep -c '^SELF=$(realpath' "$ROOT/w3c-linux.sh")
  [ "$n" = 1 ] || ERRS+=("SELF is assigned from realpath on $n lines")
  # shellcheck disable=SC2016 # literal text of the script line
  grep -qxF 'LIB_DIR=${SELF%/*}/lib' "$ROOT/w3c-linux.sh" || ERRS+=('LIB_DIR is not derived from SELF')
  # python3 must not write __pycache__ under /usr/lib/w3c-linux
  o=$(grep -nvE '^[[:space:]]*#' "$ROOT/w3c-linux.sh" "$ROOT"/lib/*.sh | grep -E 'python3 +-' | grep -vF 'python3 -I -B ')
  [ -z "$o" ] || ERRS+=("python3 call without -B: $o")
}

# ---------- command name in hints ----------

# first_row_is: the first OUT line is the doctor version row
first_row_is() {
  local want
  want=$(printf '%s  %-16s  %s' pass version "w3c-linux $VER")
  [ "${OUT%%$'\n'*}" = "$want" ] || ERRS+=("first doctor row is: ${OUT%%$'\n'*}")
}

t_cmdname_doctor() {
  local SCRIPT
  pkg_stage || return 0
  run "$T" doctor
  rc_is 0
  first_row_is
  has_row warn 'w3c build' 'none recorded: run w3c-linux install'
  has_row warn 'runner build' 'is not a recorded W3C build: run w3c-linux install'
  lacks_text 'w3c-linux.sh'
  lacks_text "$ROOT"
}

# no_clone_name: neither stream names the clone script
no_clone_name() {
  case $OUT$ERR in *w3c-linux.sh*) ERRS+=("output names w3c-linux.sh: $OUT$ERR") ;; esac
}

t_cmdname_install_checks() {
  local SCRIPT
  pkg_stage || return 0
  rm "$T/home/.local/share/faugus-launcher/games.json"
  run "$T" install
  rc_is 1
  out_has 'install: fix the failed checks above, then rerun (w3c-linux doctor shows every check)'
  no_clone_name
}

t_cmdname_update() {
  local SCRIPT
  pkg_stage || return 0
  run "$T" update
  out_has 'patched Proton: no complete W3C build recorded; run w3c-linux install'
  no_clone_name
  rm "$T/home/.local/share/faugus-launcher/games.json"
  run "$T" update
  out_has 'update: fix the failed checks above, then rerun (w3c-linux doctor shows every check)'
  no_clone_name
}

t_cmdname_launch_checks() {
  local SCRIPT
  pkg_stage || return 0
  rm "$T/home/.local/share/faugus-launcher/games.json"
  run "$T" launch
  rc_is 1
  out_has 'launch: fix the failed checks above, then rerun (w3c-linux doctor shows every check)'
  no_clone_name
}

t_cmdname_revert() {
  local SCRIPT
  pkg_stage || return 0
  run "$T" revert
  rc_is 1
  out_has 'nothing to revert (w3c-linux install switches it to the W3C build)'
  no_clone_name
}

t_cmdname_winver() {
  local SCRIPT
  pkg_stage || return 0
  CASE_ENV+=(W3C_WEBVIEW_WINVER=bogus)
  run "$T" install
  rc_is 2
  err_has 'W3C_WEBVIEW_WINVER=win8 w3c-linux install'
  no_clone_name
}

t_version_doctor() {
  run "$T" doctor
  rc_is 0
  first_row_is
  has_row warn 'w3c build' 'none recorded: run w3c-linux.sh install'
}

t_version_report() {
  local want
  run "$T" report
  rc_is 0
  want=$(printf '### Versions\n```text\n%-10s %s\n%-10s' w3c-linux "$VER" faugus)
  case $OUT in *"$want"*) ;; *) ERRS+=("Versions block does not open with the w3c-linux row: $OUT") ;; esac
}

t_cmdname_report() {
  local SCRIPT
  pkg_stage || return 0
  rm "$T/home/.local/share/faugus-launcher/games.json"
  run "$T" report
  rc_is 0
  out_has 'unknown (Battle.net prefix not found: run w3c-linux doctor)'
  case ${OUT#*'### Launcher log'} in *'(Battle.net prefix not found: run w3c-linux doctor)'*) ;; *) ERRS+=('launcher section lacks the packaged prefix note') ;; esac
  lacks_text 'w3c-linux.sh'
}

t_cmdname_monitor() {
  local SCRIPT
  pkg_stage || return 0
  rm "$T/home/.local/share/faugus-launcher/games.json"
  run "$T" monitor
  rc_is 1
  err_has "monitor: cannot find Faugus's Battle.net prefix; run w3c-linux doctor"
  no_clone_name
}

# the literal script name stays out of every non-comment line of the code except four shapes: the BIN_NAME default, the package path test,
# the missing-lib message and the desktop-entry basename test
t_cmdname_static() {
  local all left
  all=$(grep -nH 'w3c-linux\.sh' "$ROOT/w3c-linux.sh" "$ROOT"/lib/*.sh | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*#')
  case $all in *'BIN_NAME=w3c-linux.sh'*) ;; *) ERRS+=('static scan is vacuous: BIN_NAME default line not found') ;; esac
  left=$(printf '%s\n' "$all" | grep -Ev 'BIN_NAME=w3c-linux\.sh|/usr/lib/w3c-linux/w3c-linux\.sh|next to w3c-linux\.sh|= w3c-linux\.sh \]')
  [ -z "$left" ] || ERRS+=("literal w3c-linux.sh in code: ${left//$ROOT\//}")
}

# ---------- the package's menu entry ----------

# one_entry_line WANT: OUT has exactly one `Desktop entry: ` line and it is WANT
one_entry_line() {
  [ "$(grep -c '^Desktop entry: ' <<< "$OUT")" = 1 ] || ERRS+=("want exactly one Desktop entry line: $OUT")
  out_has "$1"
}

# no_user_entry: neither the per-user entry nor icon exists and install created neither directory
no_user_entry() {
  [ ! -e "$T/$DESK_REL" ] || ERRS+=('a per-user entry exists')
  [ ! -e "$T/$ICON_REL" ] || ERRS+=('a per-user icon exists')
  [ ! -e "$T/home/.local/share/applications" ] || ERRS+=('the per-user applications directory was created')
  [ ! -e "$T/home/.local/share/icons" ] || ERRS+=('the per-user icons directory was created')
}

# sys_root: a fake root "$T/sys" holding only the package's entry, set as W3C_SYS_ROOT
sys_root() {
  mkdir -p "$T/sys/usr/share/applications"
  cp "$ROOT/share/w3c-linux.desktop" "$T/sys/usr/share/applications/w3c-linux.desktop"
  CASE_ENV+=("W3C_SYS_ROOT=$(realpath -- "$T/sys")")
}

t_entry_system_install() {
  local SCRIPT
  pkg_stage || return 0
  install_setup
  entry_install
  err_has 'Launch now?'
  one_entry_line "Desktop entry: the system entry is used ($(realpath -- "$T/stage")/usr/share/applications/w3c-linux.desktop)"
  no_user_entry
}

t_entry_clone_sys() {
  sys_root
  install_setup
  entry_install
  one_entry_line "Desktop entry: the system entry is used ($(realpath -- "$T/sys")/usr/share/applications/w3c-linux.desktop)"
  no_user_entry
}

# clone_desk TEXT: a per-user entry (the shipped file) whose Exec line is TEXT, plus a sibling entry that is not ours
clone_desk() {
  local l
  mkdir -p "$T/${DESK_REL%/*}"
  while IFS= read -r l; do case $l in Exec=*) printf '%s\n' "$1" ;; *) printf '%s\n' "$l" ;; esac; done < "$ROOT/share/w3c-linux.desktop" > "$T/$DESK_REL"
  printf 'sibling entry\n' > "$T/${DESK_REL%/*}/battlenet.desktop"
}

t_entry_system_removes_clone() {
  local SCRIPT
  pkg_stage || return 0
  install_setup
  clone_desk 'Exec="/old clone/w3c-linux.sh" launch'
  entry_install
  [ ! -e "$T/$DESK_REL" ] || ERRS+=('the clone entry remains')
  [ "$(< "$T/${DESK_REL%/*}/battlenet.desktop")" = 'sibling entry' ] || ERRS+=('the sibling entry changed')
  out_has 'Desktop entry: removed the per-user entry; the system entry is used'
}

t_entry_system_keeps_other() {
  local SCRIPT want
  pkg_stage || return 0
  install_setup
  clone_desk 'Exec="/home/x/my-launcher" launch'
  want=$(< "$T/$DESK_REL")
  entry_install
  [ "$(< "$T/$DESK_REL")" = "$want" ] || ERRS+=('a user entry that is not ours changed')
  lacks_text 'removed the per-user entry'
  # no Exec line at all
  printf '[Desktop Entry]\nName=mine\n' > "$T/$DESK_REL"
  want=$(< "$T/$DESK_REL")
  entry_install
  [ "$(< "$T/$DESK_REL")" = "$want" ] || ERRS+=('an entry without Exec changed')
  lacks_text 'removed the per-user entry'
}

t_entry_system_icon() {
  local SCRIPT
  pkg_stage || return 0
  install_setup
  icon_shims
  entry_install
  icon_is extracted
  [ ! -e "$T/$DESK_REL" ] || ERRS+=('a per-user entry exists')
  out_has "Desktop entry: the system entry is used; installed the launcher icon $T/$ICON_REL"
}

t_entry_system_icon_idempotent() {
  local SCRIPT before after
  pkg_stage || return 0
  install_setup
  icon_shims
  entry_install
  before=$(stat -c '%i %Y' "$T/$ICON_REL")
  sleep 1
  entry_install
  after=$(stat -c '%i %Y' "$T/$ICON_REL")
  out_has "Desktop entry: the system entry is used; icon already installed ($T/$ICON_REL)"
  [ "$before" = "$after" ] || ERRS+=("icon changed on the second install: $before then $after")
}

t_entry_system_icon_fail() {
  local SCRIPT
  pkg_stage || return 0
  install_setup
  icon_shims
  : > "$T/fix/ico-fail"
  entry_install
  [ "$(grep -c '^warn  desktop entry' <<< "$ERR$OUT")" = 1 ] || ERRS+=("want one warn desktop entry line: $ERR$OUT")
  case $ERR$OUT in *'could not extract the icon from W3Champions.exe; the menu uses the packaged icon'*) ;; *) ERRS+=('no extraction warn') ;; esac
  [ ! -e "$T/$ICON_REL" ] || ERRS+=('an icon was written')
  out_has "Desktop entry: the system entry is used ($(realpath -- "$T/stage")/usr/share/applications/w3c-linux.desktop)"
}

t_entry_doctor_system() {
  local SCRIPT
  pkg_stage || return 0
  run "$T" doctor
  has_row pass 'desktop entry' "$(realpath -- "$T/stage")/usr/share/applications/w3c-linux.desktop (system)"
  desk_row_last
}

t_entry_doctor_hidden() {
  local SCRIPT
  pkg_stage || return 0
  clone_desk 'Exec="/home/x/my-launcher" launch'
  run "$T" doctor
  rc_is 0
  has_row warn 'desktop entry' "$T/$DESK_REL hides the system entry: run w3c-linux install, or delete it"
  desk_row_last
}

t_entry_doctor_clone_sys() {
  sys_root
  run "$T" doctor
  has_row pass 'desktop entry' "$(realpath -- "$T/sys")/usr/share/applications/w3c-linux.desktop (system)"
  desk_row_last
}

# stage_kept: the package's entry and icon are still in the stage
stage_kept() {
  [ -f "$T/stage/usr/share/applications/w3c-linux.desktop" ] || ERRS+=('the stage lost its menu entry')
  [ -f "$T/stage/usr/share/icons/hicolor/256x256/apps/w3c-linux.png" ] || ERRS+=('the stage lost its icon')
}

t_entry_revert_system() {
  local SCRIPT
  pkg_stage || return 0
  w3c_on
  mkdir -p "$T/${ICON_REL%/*}"
  printf 'icon\n' > "$T/$ICON_REL"
  FEED=$'y\n\n'
  run "$T" revert
  rc_is 0
  out_has "Removed the menu icon $T/$ICON_REL."
  lacks_text 'Removed the desktop entry'
  [ ! -e "$T/$ICON_REL" ] || ERRS+=('the icon remains')
  stage_kept
}

t_entry_revert_system_both() {
  local SCRIPT
  pkg_stage || return 0
  w3c_on
  desk_seed
  FEED=$'y\n\n'
  run "$T" revert
  rc_is 0
  [ ! -e "$T/$DESK_REL" ] || ERRS+=('the entry remains')
  [ ! -e "$T/$ICON_REL" ] || ERRS+=('the icon remains')
  [ "$(< "$T/${DESK_REL%/*}/battlenet.desktop")" = 'sibling entry' ] || ERRS+=('the sibling entry changed')
  [ "$(< "$T/${ICON_REL%/*}/other.png")" = 'sibling icon' ] || ERRS+=('the sibling icon changed')
  out_has "Removed the desktop entry $T/$DESK_REL and its icon."
  stage_kept
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
