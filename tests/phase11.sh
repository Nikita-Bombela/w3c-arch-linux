#!/usr/bin/env bash
# Phase 11 fixture check: the Makefile targets on a temp DESTDIR and a fake HOME, the install-location rows and the menu entry of an installed
# copy, on the harness of tests/phase2.sh to tests/phase6.sh. No root, never the real /usr or $HOME: every make call runs under env -i with
# DESTDIR or HOME inside the case's temp dir.
# Usage: bash tests/phase11.sh [GLOB]   (GLOB filters on display names such as stage-tree)
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=phase6.sh
source "$(dirname "${BASH_SOURCE[0]}")/phase6.sh"

# this suite has its own cases only
mapfile -t P6_CASES < <(compgen -A function t_)
unset -f "${P6_CASES[@]}"

# nothing here may reach wine, sudo or the firewall (phase6's list minus the tools this suite never starts)
FORBIDDEN=(wine wineserver sudo nft iptables)
MAKE_BIN=$(type -P make)   # resolved before any PATH narrowing
VER=$(sed -n 's/^W3C_LINUX_VERSION=//p' "$ROOT/w3c-linux.sh")
MOUT='' MRC=0 MK_ENV=()

# ---------- helpers ----------

# mk ARGS...: runs make in the repo under env -i (so no MAKEFLAGS or HOME of the caller leaks in), umask MK_UMASK (default 022), PATH MK_PATH,
# HOME MK_HOME (default $T/home; MK_NOHOME=1 leaves it unset), extra environment words in MK_ENV. Output (both streams) in MOUT, status in MRC.
mk() {
  local homev=(HOME="${MK_HOME-$T/home}")
  [ "${MK_NOHOME:-}" = 1 ] && homev=()
  if [ -z "$MAKE_BIN" ]; then
    ERRS+=('make is missing')
    MOUT='' MRC=127
    return 0
  fi
  MOUT=$(umask "${MK_UMASK:-022}" && env -i PATH="${MK_PATH:-$PATH}" "${homev[@]}" "${MK_ENV[@]}" "$MAKE_BIN" --no-print-directory -C "$ROOT" "$@" 2>&1)
  MRC=$?
}

# tree_of DIR: every entry under DIR as `type mode path link-target`, sorted.
tree_of() { (cd "$1" && find . -mindepth 1 -printf '%y %m %p %l\n' | LC_ALL=C sort); }

# files_of DIR: tree_of without directories (shared directories may stay after an uninstall).
files_of() { (cd "$1" && find . -mindepth 1 ! -type d -printf '%y %m %p %l\n' | LC_ALL=C sort); }

# the v0.1.1 package() body, frozen byte for byte from `git show v0.1.1:packaging/PKGBUILD` because CI's checkout is shallow and has no tags.
# shellcheck disable=SC2154,SC2164 # pkgname, pkgver and pkgdir are set by oracle_package; the body stays verbatim, cd without a guard included
v011_package() {
  cd "w3c-arch-linux-$pkgver"
  install -Dm755 -t "$pkgdir/usr/lib/$pkgname" w3c-linux.sh
  install -Dm644 -t "$pkgdir/usr/lib/$pkgname/lib" lib/*.sh lib/*.py
  install -Dm755 -t "$pkgdir/usr/lib/$pkgname/lib" lib/w3c-askpass.sh   # sudo -A executes it
  install -d "$pkgdir/usr/bin"
  ln -s "../lib/$pkgname/w3c-linux.sh" "$pkgdir/usr/bin/$pkgname"   # relative, so a staged root resolves inside itself
  install -Dm644 -t "$pkgdir/usr/share/applications" share/w3c-linux.desktop
  install -Dm644 -t "$pkgdir/usr/share/icons/hicolor/256x256/apps" share/w3c-linux.png
}

# oracle_package SRC PKGDIR: runs the frozen v0.1.1 package() over this checkout into PKGDIR. SRC is a temp dir that gets the symlink
# w3c-arch-linux-0.1.1 to the repo, which is where package() expects the unpacked tarball.
oracle_package() {
  mkdir -p "$1"
  ln -s "$ROOT" "$1/w3c-arch-linux-0.1.1"
  (umask 022 && pkgname=w3c-linux pkgver=0.1.1 pkgdir=$2 && cd "$1" && v011_package)
}

# same_tree WANTDIR GOTDIR LABEL: the two trees list identically; a mismatch is an ERRS line with the head of the diff.
same_tree() {
  local d
  d=$(diff <(tree_of "$1") <(tree_of "$2") | head -n 8 | tr '\n' '|')
  [ -z "$d" ] || ERRS+=("$3: tree differs from the v0.1.1 package: $d")
}

# mk_ok WHAT: the last make call exited 0.
mk_ok() { [ "$MRC" = 0 ] || ERRS+=("$1 exited $MRC: $MOUT"); }

# digest_of DIR: checksum of every regular file under DIR, so "stays byte-equal" is checked on content too.
digest_of() { (cd "$1" && find . -type f -exec cksum {} + | LC_ALL=C sort); }

# the encoder the script itself uses for the Exec line, so the expected text never comes from the Makefile's own sed chain
# shellcheck disable=SC1090 # sourced from a process substitution
source <(sed -n -e '/^desk_quote() {$/,/^}$/p' -e '/^desk_unquote() {$/,/^}$/p' "$ROOT/lib/common.sh")

# seed_foreign ROOT: files the uninstall targets must leave alone, in the shared directories and in state, cache and config.
seed_foreign() {
  local r=$1 f
  for f in .local/state/w3c-linux/proton-tag .cache/w3c-linux/wine.log .config/w3c-linux/backend .local/bin/other .local/lib/other/x \
    .local/share/applications/battlenet.desktop .local/share/icons/hicolor/256x256/apps/other.png; do
    mkdir -p "$r/$(dirname "$f")"
    printf 'foreign %s\n' "$f" > "$r/$f"
  done
}

# line STATUS LABEL VALUE and has_line: one doctor row, matched as a whole line of OUT (the same pair as tests/phase10.sh).
line() { printf '%s  %-16s  %s' "$1" "$2" "$3"; }
has_line() {
  local want
  want=$(line "$1" "$2" "$3")
  grep -qxF -- "$want" <<< "$OUT" || ERRS+=("missing line: [$want]")
}

# ---------- MAKE-01: make install stages the v0.1.1 tree ----------

t_stage_tree() {
  local l
  oracle_package "$T/src" "$T/want"
  mk install DESTDIR="$T/got"
  mk_ok 'make install'
  same_tree "$T/want" "$T/got" 'umask 022'
  l=$(tree_of "$T/got")
  case $l in *$'\nl 777 ./usr/bin/w3c-linux ../lib/w3c-linux/w3c-linux.sh'* | 'l 777 ./usr/bin/w3c-linux ../lib/w3c-linux/w3c-linux.sh'*) ;; *) ERRS+=('no relative usr/bin/w3c-linux link in the listing') ;; esac
  case $l in *'f 755 ./usr/lib/w3c-linux/lib/w3c-askpass.sh '*) ;; *) ERRS+=('w3c-askpass.sh is not 755') ;; esac
}

t_stage_umask() {
  local MK_UMASK=077
  oracle_package "$T/src" "$T/want"
  mk install DESTDIR="$T/got"
  mk_ok 'make install under umask 077'
  same_tree "$T/want" "$T/got" 'umask 077'
}

t_stage_twice() {
  mk install DESTDIR="$T/got"
  mk_ok 'first make install'
  tree_of "$T/got" > "$T/first"
  mk install DESTDIR="$T/got"
  mk_ok 'second make install'
  tree_of "$T/got" | cmp -s - "$T/first" || ERRS+=('the second install changed the listing')
}

t_stage_prefix_opt() {
  local o
  mk install DESTDIR="$T/s" PREFIX=/opt/x
  mk_ok 'make install PREFIX=/opt/x'
  [ "$(readlink "$T/s/opt/x/bin/w3c-linux")" = ../lib/w3c-linux/w3c-linux.sh ] || ERRS+=('opt/x/bin/w3c-linux is not the relative link')
  o=$(env -i PATH="$PATH" HOME="$T/home" "$T/s/opt/x/bin/w3c-linux" --version 2>&1)
  [ "$o" = "w3c-linux $VER" ] || ERRS+=("--version printed: $o")
}

t_stage_bare_make() {
  local before after
  before=$(git -C "$ROOT" status --porcelain)
  mk
  after=$(git -C "$ROOT" status --porcelain)
  mk_ok 'bare make'
  [ "${MOUT%%$'\n'*}" = 'usage: make install [DESTDIR=dir] [PREFIX=/usr] | install-user | uninstall | uninstall-user | check [SUITES=glob]' ] || ERRS+=("first line is not the usage: $MOUT")
  [ "$before" = "$after" ] || ERRS+=('a bare make changed the work tree')
}

t_pkgbuild_make() {
  local body
  body=$(sed -n '/^package() {$/,/^}$/p' "$ROOT/packaging/PKGBUILD")
  [ "$body" = "package() {
  make -C \"w3c-linux-\$pkgver\" install DESTDIR=\"\$pkgdir\" PREFIX=/usr
}" ] || ERRS+=("package() is not the single make call: $body")
  [ "$(grep -c '^pkgver=0.3.0$' "$ROOT/packaging/PKGBUILD")" = 1 ] || ERRS+=('pkgver is not 0.3.0')
}

# ---------- MAKE-02 make half: install-user ----------

t_user_tree() {
  local want
  files_of "$T/home" > "$T/before"
  oracle_package "$T/src" "$T/want"
  mk install-user
  mk_ok 'make install-user'
  want=$(files_of "$T/want" | sed 's# \./usr/# ./.local/#' | LC_ALL=C sort)
  [ "$(files_of "$T/home" | LC_ALL=C comm -13 "$T/before" -)" = "$want" ] || ERRS+=("install-user did not add exactly the system files under .local: $(files_of "$T/home" | LC_ALL=C comm -13 "$T/before" - | tr '\n' '|')")
}

t_user_umask() {
  local MK_UMASK=077 l
  mk install-user
  mk_ok 'make install-user under umask 077'
  for l in "f 644 ./.local/share/applications/w3c-linux.desktop" "f 644 ./.local/share/icons/hicolor/256x256/apps/w3c-linux.png" "f 755 ./.local/lib/w3c-linux/w3c-linux.sh"; do
    tree_of "$T/home" | grep -qxF -- "$l " || ERRS+=("missing from the listing: $l")
  done
}

t_user_exec_plain() {
  mk install-user
  mk_ok 'make install-user'
  entry_exec_is "Exec=$T/home/.local/bin/w3c-linux launch"
}

t_user_exec_quoted() {
  local H got q
  for H in "$T/sp ace" "$T/pct%x" "$T/q\"uote" "$T/back\\slash" "$T/tick\`x"; do
    mkdir -p "$H"
    MK_HOME=$H mk install-user
    [ "$MRC" = 0 ] || { ERRS+=("make install-user in [$H] exited $MRC: $MOUT"); continue; }
    got=$(grep '^Exec=' "$H/.local/share/applications/w3c-linux.desktop")
    [ "$got" = "Exec=$(desk_quote "$H/.local/bin/w3c-linux") launch" ] || ERRS+=("Exec for [$H] is: $got")
    q=${got#Exec=\"}
    q=${q%\" launch}
    [ "$(desk_unquote "$q")" = "$H/.local/bin/w3c-linux" ] || ERRS+=("Exec for [$H] does not decode back to the path")
    case $H in *' '*) validate_desk "$H/.local/share/applications/w3c-linux.desktop" ;; esac
  done
}

t_user_system_exec() {
  mk install DESTDIR="$T/s"
  mk_ok 'make install'
  grep -qx 'Exec=w3c-linux launch' "$T/s/usr/share/applications/w3c-linux.desktop" || ERRS+=('the system entry lost Exec=w3c-linux launch')
}

t_user_path_run() {
  local o
  mk install-user
  mk_ok 'make install-user'
  [ -x "$T/home/.local/bin/w3c-linux" ] || ERRS+=('.local/bin/w3c-linux is not executable')
  o=$(env -i PATH="$T/home/.local/bin:$PATH" HOME="$T/home" w3c-linux --version 2>&1)
  [ "$o" = "w3c-linux $VER" ] || ERRS+=("w3c-linux --version by name printed: $o")
}

t_user_dry_run() {
  mk -n install-user
  mk_ok 'make -n install-user'
  case $MOUT in *"'$T/home/.local/lib/w3c-linux'"*) ;; *) ERRS+=("the plan does not name $T/home/.local/lib/w3c-linux") ;; esac
  ! grep -q "'/usr" <<< "$MOUT" || ERRS+=('the plan names a path under /usr')
}

t_user_no_home() {
  local MK_NOHOME=1 j
  for j in install-user '-j4 install-user'; do
    # shellcheck disable=SC2086 # J is one or two words on purpose
    mk $j
    [ "$MRC" != 0 ] || ERRS+=("make $j with HOME unset exited 0")
    case $MOUT in *'HOME is not set'*) ;; *) ERRS+=("make $j: no 'HOME is not set' in: $MOUT") ;; esac
    ! grep -q 'install -D' <<< "$MOUT" || ERRS+=("make $j ran an install step without HOME")
  done
}

# ---------- MAKE-03: uninstall removes exactly what was installed ----------

t_uninstall_system() {
  local f
  for f in usr/bin/other usr/lib/other/x usr/share/applications/battlenet.desktop; do
    mkdir -p "$T/s/$(dirname "$f")"
    printf 'foreign\n' > "$T/s/$f"
  done
  files_of "$T/s" > "$T/before"
  [ "$(wc -l < "$T/before")" = 3 ] || ERRS+=('the seed is not three files')
  mk install DESTDIR="$T/s"
  mk_ok 'make install'
  mk uninstall DESTDIR="$T/s"
  mk_ok 'make uninstall'
  files_of "$T/s" | cmp -s - "$T/before" || ERRS+=("uninstall left: $(files_of "$T/s" | tr '\n' '|')")
}

t_uninstall_user() {
  seed_foreign "$T/home"
  files_of "$T/home" > "$T/before"
  digest_of "$T/home" > "$T/before.sum"
  mk install-user
  mk_ok 'make install-user'
  mk uninstall-user
  mk_ok 'make uninstall-user'
  files_of "$T/home" | cmp -s - "$T/before" || ERRS+=("files after uninstall-user differ: $(files_of "$T/home" | diff "$T/before" - | tr '\n' '|')")
  digest_of "$T/home" | cmp -s - "$T/before.sum" || ERRS+=('a foreign file changed content')
}

t_uninstall_nothing() {
  seed_foreign "$T/home"
  files_of "$T/home" > "$T/before"
  mk uninstall-user
  mk_ok 'make uninstall-user on nothing'
  mk uninstall-user
  mk_ok 'second make uninstall-user'
  files_of "$T/home" | cmp -s - "$T/before" || ERRS+=('uninstall-user on nothing changed the files')
}

t_uninstall_partial() {
  files_of "$T/home" > "$T/before"
  mk install-user
  mk_ok 'make install-user'
  rm -rf "$T/home/.local/lib/w3c-linux"
  mk uninstall-user
  mk_ok 'make uninstall-user after an interrupted uninstall'
  files_of "$T/home" | cmp -s - "$T/before" || ERRS+=("left over: $(files_of "$T/home" | diff "$T/before" - | tr '\n' '|')")
}

t_uninstall_symlink_lib() {
  mkdir -p "$T/s/usr/lib" "$T/elsewhere"
  printf 'keep\n' > "$T/elsewhere/file"
  ln -s "$T/elsewhere" "$T/s/usr/lib/w3c-linux"
  mk uninstall DESTDIR="$T/s"
  mk_ok 'make uninstall'
  [ ! -e "$T/s/usr/lib/w3c-linux" ] && [ ! -L "$T/s/usr/lib/w3c-linux" ] || ERRS+=('the lib symlink is still there')
  [ "$(cat "$T/elsewhere/file" 2> /dev/null)" = keep ] || ERRS+=('the directory the link pointed at lost its file')
}

t_uninstall_no_home() {
  local MK_NOHOME=1
  mk uninstall-user
  [ "$MRC" != 0 ] || ERRS+=('make uninstall-user with HOME unset exited 0')
  case $MOUT in *'HOME is not set'*) ;; *) ERRS+=("no 'HOME is not set' in: $MOUT") ;; esac
  ! grep -q '^rm ' <<< "$MOUT" || ERRS+=('an rm step ran without HOME')
}

# ---------- MAKE-04: make check ----------

# sc_shim RC: a recording shellcheck first on PATH (argv one per line in $T/marks/shellcheck, prints shellcheck-ran, exits RC) and the two
# stub suites. Never the real `make check`: it would run this suite inside itself.
sc_shim() {
  mkdir -p "$T/scbin" "$T/marks"
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" > %q\necho shellcheck-ran\nexit %s\n' "$T/marks/shellcheck" "$1" > "$T/scbin/shellcheck"
  chmod +x "$T/scbin/shellcheck"
  printf '#!/bin/sh\necho stub-ran\n' > "$T/stub-ok.sh"
  printf '#!/bin/sh\necho stub-bad-ran\nexit 3\n' > "$T/stub-bad.sh"
}

t_check_runs() {
  local MK_PATH="$T/scbin:$PATH" a
  sc_shim 0
  mk check SUITES="$T/stub-ok.sh"
  mk_ok 'make check'
  case $MOUT in *shellcheck-ran*'== '"$T/stub-ok.sh"*stub-ran*) ;; *) ERRS+=("output order is not shellcheck, == suite, suite output: $MOUT") ;; esac
  for a in -x w3c-linux.sh tests/live.sh tests/phase11.sh; do
    grep -qxF -- "$a" "$T/marks/shellcheck" || ERRS+=("shellcheck was not given $a")
  done
}

t_check_suite_fails() {
  local MK_PATH="$T/scbin:$PATH" a
  sc_shim 0
  mk check SUITES="$T/stub-bad.sh $T/stub-ok.sh"
  [ "$MRC" != 0 ] || ERRS+=('a failing suite did not fail make check')
  for a in "== $T/stub-bad.sh" "== $T/stub-ok.sh" stub-ran; do
    case $MOUT in *"$a"*) ;; *) ERRS+=("missing from the output: $a") ;; esac
  done
}

t_check_missing_suite() {
  local MK_PATH="$T/scbin:$PATH"
  sc_shim 0
  mk check SUITES="$T/nope.sh"
  [ "$MRC" != 0 ] || ERRS+=('a SUITES value that matches no file did not fail')
  case $MOUT in *"$T/nope.sh"*) ;; *) ERRS+=("the output does not name $T/nope.sh: $MOUT") ;; esac
}

t_check_no_shellcheck() {
  local MK_PATH="$T/emptybin"
  mkdir "$T/emptybin"
  sc_shim 0
  mk check SUITES="$T/stub-ok.sh"
  [ "$MRC" != 0 ] || ERRS+=('make check without shellcheck exited 0')
  case $MOUT in *'make check: shellcheck not found'*) ;; *) ERRS+=("no 'make check: shellcheck not found' in: $MOUT") ;; esac
  case $MOUT in *'== '*) ERRS+=("a suite ran without shellcheck: $MOUT") ;; esac
}

t_check_shellcheck_fails() {
  local MK_PATH="$T/scbin:$PATH"
  sc_shim 1
  mk check SUITES="$T/stub-ok.sh"
  [ "$MRC" != 0 ] || ERRS+=('make check with a failing shellcheck exited 0')
  case $MOUT in *shellcheck-ran*'== '"$T/stub-ok.sh"*stub-ran*) ;; *) ERRS+=("the suite did not run after shellcheck failed: $MOUT") ;; esac
}

t_check_suites_env() {
  local MK_PATH="$T/scbin:$PATH"
  local MK_ENV=("SUITES=$T/stub-ok.sh")
  sc_shim 0
  mk check
  mk_ok 'make check with SUITES in the environment'
  case $MOUT in *'== '"$T/stub-ok.sh"*stub-ran*) ;; *) ERRS+=("the environment SUITES was not used: $MOUT") ;; esac
}

t_check_default() {
  local f
  mk -n check
  mk_ok 'make -n check'
  case $MOUT in *'tests/phase[0-9]*.sh'*) ;; *) ERRS+=("the default glob is not in the plan: $MOUT") ;; esac
  for f in tests/phase1.sh tests/phase10.sh tests/phase11.sh; do
    (cd "$ROOT" && for g in tests/phase[0-9]*.sh; do [ "$g" = "$f" ] && exit 0; done; exit 1) || ERRS+=("the default glob misses $f")
  done
  (cd "$ROOT" && for g in tests/phase[0-9]*.sh; do [ "$g" = tests/live.sh ] && exit 1; done; exit 0) || ERRS+=('the default glob matches tests/live.sh')
}

# ---------- MAKE-02 doctor half: the install location rows ----------

# user_install: make install-user into the case's fake home and run that copy, with PATH $1 (default: the harness bin and the user's bin).
user_install() {
  mk install-user
  mk_ok 'make install-user'
  SCRIPT=$T/home/.local/bin/w3c-linux
  CASE_ENV+=("PATH=${1-$T/bin:$T/home/.local/bin}")
}

# sys_install [PREFIX] PATHDIRS: make install into $T/stage and run that copy with the real path of $T/stage as W3C_SYS_ROOT and PATH $T/bin
# plus PATHDIRS. The prefix defaults to /usr.
sys_install() {
  local px=${1:-/usr}
  mk install DESTDIR="$T/stage" PREFIX="$px"
  mk_ok "make install PREFIX=$px"
  SCRIPT=$T/stage$px/bin/w3c-linux
  CASE_ENV+=("W3C_SYS_ROOT=$(realpath -- "$T/stage")" "PATH=$T/bin${2:+:$2}")
}

t_doctor_clone() {
  run "$T" doctor
  has_line pass 'install location' "$(realpath -- "$ROOT") (clone)"
}

t_doctor_user_on_path() {
  local SCRIPT
  user_install
  run "$T" doctor
  has_line pass 'install location' "$T/home/.local (user)"
}

t_doctor_user_off_path() {
  local SCRIPT
  user_install "$T/bin"
  run "$T" doctor
  has_line warn 'install location' "$T/home/.local (user): $T/home/.local/bin is not on PATH"
}

t_doctor_system() {
  local SCRIPT
  sys_install /usr "$T/stage/usr/bin"
  run "$T" doctor
  has_line pass 'install location' '/usr (system)'
  CASE_ENV=()
  sys_install /usr ''
  run "$T" doctor
  has_line warn 'install location' '/usr (system): /usr/bin is not on PATH'
}

t_doctor_opt() {
  local SCRIPT
  sys_install /opt/x ''
  run "$T" doctor
  has_line warn 'install location' '/opt/x (system): /opt/x/bin is not on PATH'
}

t_doctor_symlinked_home() {
  local SCRIPT
  mv "$T/home" "$T/real-home"
  ln -s real-home "$T/home"
  user_install
  run "$T" doctor
  has_line pass 'install location' "$T/home/.local (user)"
}

t_doctor_bin_name() {
  local SCRIPT
  user_install
  run "$T" help
  out_has 'usage: w3c-linux <subcommand>'
  lacks_text 'w3c-linux.sh'
  CASE_ENV=()
  sys_install /opt/x ''
  run "$T" help
  out_has 'usage: w3c-linux <subcommand>'
  lacks_text 'w3c-linux.sh'
  CASE_ENV=()
  SCRIPT=$ROOT/w3c-linux.sh
  run "$T" help
  out_has 'usage: w3c-linux.sh <subcommand>'
}

t_doctor_rc() {
  local SCRIPT
  l_setup
  user_install "$T/bin"
  run "$T" doctor
  rc_is 0
  has_line warn 'install location' "$T/home/.local (user): $T/home/.local/bin is not on PATH"
}

# two_installs PATHDIRS: a system copy under $T/sysroot and a per-user copy under the fake home, W3C_SYS_ROOT its real path, PATH $T/bin plus
# PATHDIRS. The case sets SCRIPT to the copy it wants to run.
two_installs() {
  mk install DESTDIR="$T/sysroot"
  mk_ok 'make install'
  mk install-user
  mk_ok 'make install-user'
  CASE_ENV+=("W3C_SYS_ROOT=$(realpath -- "$T/sysroot")" "PATH=$T/bin${1:+:$1}")
}

# other_row PATHRUNS MENU: the `other install` row's exact text.
other_row() { has_line warn 'other install' "/usr and $T/home/.local both hold w3c-linux: PATH runs $1, the menu shows $2"; }

t_doctor_two_user() {
  local SCRIPT=$T/home/.local/bin/w3c-linux
  two_installs "$T/home/.local/bin:$T/sysroot/usr/bin"
  run "$T" doctor
  other_row "$T/home/.local/bin/w3c-linux" "$T/home/.local/share/applications/w3c-linux.desktop"
  [ "$(sed -n 3p <<< "$OUT" | cut -c1-19)" = 'warn  other install' ] || ERRS+=('the other install row is not right after the location row')
}

t_doctor_two_system() {
  local SCRIPT=$T/sysroot/usr/bin/w3c-linux
  two_installs "$T/sysroot/usr/bin:$T/home/.local/bin"
  run "$T" doctor
  has_line pass 'install location' '/usr (system)'
  other_row "$T/sysroot/usr/bin/w3c-linux" "$T/home/.local/share/applications/w3c-linux.desktop"
}

t_doctor_two_off_path() {
  local SCRIPT=$T/home/.local/bin/w3c-linux
  two_installs ''
  run "$T" doctor
  other_row 'none (w3c-linux is not on PATH)' "$T/home/.local/share/applications/w3c-linux.desktop"
}

t_doctor_two_no_user_entry() {
  local SCRIPT=$T/home/.local/bin/w3c-linux
  two_installs "$T/home/.local/bin"
  rm -- "$T/home/.local/share/applications/w3c-linux.desktop"
  run "$T" doctor
  other_row "$T/home/.local/bin/w3c-linux" /usr/share/applications/w3c-linux.desktop
}

t_doctor_two_clone() {
  two_installs "$T/home/.local/bin"
  run "$T" doctor
  has_line pass 'install location' "$(realpath -- "$ROOT") (clone)"
  other_row "$T/home/.local/bin/w3c-linux" "$T/home/.local/share/applications/w3c-linux.desktop"
}

t_doctor_one_install() {
  local SCRIPT
  user_install
  run "$T" doctor
  lacks_text 'other install'
  mk uninstall-user
  mk_ok 'make uninstall-user'
  CASE_ENV=()
  sys_install /usr "$T/stage/usr/bin"
  run "$T" doctor
  lacks_text 'other install'
}

# ---------- MAKE-02 menu entry: the entry make installed belongs to the install ----------

# keep_own: copies of the entry and icon make installed, taken under $T before the run.
keep_own() {
  cp -- "$T/$DESK_REL" "$T/own.desktop"
  cp -- "$T/$ICON_REL" "$T/own.png"
}

# own_same: the entry and icon are still byte-equal to the copies keep_own took.
own_same() {
  cmp -s "$T/$DESK_REL" "$T/own.desktop" || ERRS+=('the entry make wrote changed')
  cmp -s "$T/$ICON_REL" "$T/own.png" || ERRS+=('the icon make wrote changed')
}

t_entry_user_install() {
  local SCRIPT
  user_install
  install_setup
  keep_own
  entry_install
  [ "$(grep -c '^Desktop entry: ' <<< "$OUT")" = 1 ] || ERRS+=("want exactly one Desktop entry line: $OUT")
  out_has "Desktop entry: the entry make install-user wrote is used ($T/$DESK_REL)"
  desk_untouched
  own_same
}

t_entry_user_missing() {
  local SCRIPT
  user_install
  install_setup
  rm -- "$T/$DESK_REL"
  entry_install
  [ ! -e "$T/$DESK_REL" ] || ERRS+=('install wrote a per-user entry')
  out_has "warn  desktop entry  "
  [ "$(grep -c '^Desktop entry: ' <<< "$OUT")" = 0 ] || ERRS+=("a Desktop entry line was printed: $OUT")
  run "$T" doctor
  grep -q '^warn  desktop entry' <<< "$OUT" || ERRS+=('doctor has no warn desktop entry row')
}

t_entry_staged_system() {
  local SCRIPT st
  sys_install /usr ''
  install_setup
  st=$(realpath -- "$T/stage")
  entry_install
  [ "$(grep -c '^Desktop entry: ' <<< "$OUT")" = 1 ] || ERRS+=("want exactly one Desktop entry line: $OUT")
  out_has "Desktop entry: the system entry is used ($st/usr/share/applications/w3c-linux.desktop)"
  [ ! -e "$T/$DESK_REL" ] || ERRS+=('install wrote a per-user entry')
  [ ! -e "$T/$ICON_REL" ] || ERRS+=('install wrote a per-user icon')
}

t_entry_user_doctor() {
  local SCRIPT
  user_install
  run "$T" doctor
  has_line pass 'desktop entry' "$T/$DESK_REL (user install)"
  desk_row_last
}

t_entry_user_revert() {
  local SCRIPT
  user_install
  w3c_on
  keep_own
  FEED=$'y\n\n'
  run "$T" revert
  rc_is 0
  lacks_text 'Removed the desktop entry'
  lacks_text 'not written by'
  desk_untouched
  own_same
}

t_entry_user_lifecycle() {
  local SCRIPT h=$T/home/.local
  user_install
  install_setup
  entry_install
  unset FEED
  run "$T" doctor
  has_line pass 'desktop entry' "$T/$DESK_REL (user install)"
  mk uninstall-user
  mk_ok 'make uninstall-user'
  local f
  for f in bin/w3c-linux lib/w3c-linux share/applications/w3c-linux.desktop share/icons/hicolor/256x256/apps/w3c-linux.png; do
    [ ! -e "$h/$f" ] && [ ! -L "$h/$f" ] || ERRS+=("left after uninstall-user: $h/$f")
  done
  [ -d "$h/state/w3c-linux" ] || ERRS+=('the state directory is gone')
}

# ---------- README (static) ----------

# readme_section HEADING: the README text from the line HEADING to the next `## ` heading.
readme_section() { awk -v h="$1" '$0 == h { on = 1; next } on && /^## / { exit } on' "$ROOT/README.md"; }

t_readme_make() {
  local inst s
  inst=$(readme_section '## Installation')
  # shellcheck disable=SC2088  # the tilde is README text, not a path
  for s in 'make install-user' 'make uninstall-user' 'sudo make install' 'sudo make uninstall' 'DESTDIR=' 'PREFIX=' 'make check' 'SUITES=' '~/.local/bin' 'pacman -R w3c-linux'; do
    grep -qF -- "$s" <<< "$inst" || ERRS+=("README Installation lacks: $s")
  done
  [ "$(grep -c '^### With make$' "$ROOT/README.md")" = 1 ] || ERRS+=('want one "### With make" heading')
}

t_readme_clone_path() {
  local inst
  inst=$(readme_section '## Installation')
  # shellcheck disable=SC2016  # literal backticks
  ! grep -qi 'symlink .*into your `PATH`' <<< "$inst" || ERRS+=('README still tells the user to symlink the script into PATH')
}

t_icon_gone() {
  local o
  o=$(git -C "$ROOT" grep -n -i -e icoextract -e magick -e icon_from_exe -- w3c-linux.sh lib packaging .github docs README.md tests/phase6.sh tests/phase7.sh)
  [ -z "$o" ] || ERRS+=("an icon extraction name is back: $o")
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
