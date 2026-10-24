#!/usr/bin/env bash
# Phase 12 fixture check: the distro family from a fake os-release (or the PATH probe), and the install command doctor prints for it, on the
# harness of tests/phase2.sh to tests/phase6.sh. Nothing here may run a package manager or reach the real /etc/os-release: W3C_SYS_ROOT and
# PATH are the only seams.
# Usage: bash tests/phase12.sh [GLOB]   (GLOB filters on display names such as distro-ubuntu)
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=phase6.sh
source "$(dirname "${BASH_SOURCE[0]}")/phase6.sh"

# this suite has its own cases only
mapfile -t P6_CASES < <(compgen -A function t_)
unset -f "${P6_CASES[@]}"

# nothing here may reach wine, sudo, the firewall or a package manager; a package manager may run only in a case that narrows FORBIDDEN itself
FORBIDDEN=(wine wineserver sudo nft iptables pacman rpm dpkg-query dnf apt apt-get)

# ---------- helpers ----------

# line STATUS LABEL VALUE and has_line: one doctor row, matched as a whole line of OUT (the same pair as tests/phase10.sh).
line() { printf '%s  %-16s  %s' "$1" "$2" "$3"; }
has_line() {
  local want
  want=$(line "$1" "$2" "$3")
  grep -qxF -- "$want" <<< "$OUT" || ERRS+=("missing line: [$want]")
}

# values_are LABEL VALUE...: the values of OUT's rows with that label are exactly these, in order (as in tests/phase10.sh).
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

# osr_set CONTENT: writes CONTENT (printf %b, so \n is a newline) as the case's os-release and points W3C_SYS_ROOT at it. Call it after any
# CASE_ENV=(...) assignment, because it appends.
osr_set() {
  mkdir -p "$T/sys/etc"
  printf '%b' "$1" > "$T/sys/etc/os-release"
  CASE_ENV+=("W3C_SYS_ROOT=$T/sys")
}

# ---------- HINT-02: the required-tools row ends with the family's command ----------

t_hint_required_fedora() {
  osr_set 'ID=fedora\n'
  rm "$T/bin/curl" "$T/bin/pgrep"
  run "$T" doctor
  rc_is 1
  has_line fail 'required tools' 'missing: curl pgrep: sudo dnf install curl procps-ng'
}

t_hint_required_arch() {
  osr_set 'ID=arch\n'
  rm "$T/bin/python3" "$T/bin/pgrep"
  run "$T" doctor
  rc_is 1
  has_line fail 'required tools' 'missing: python3 pgrep: sudo pacman -S python procps-ng'
}

t_hint_required_debian() {
  osr_set 'ID=debian\n'
  rm "$T/bin/pgrep"
  run "$T" doctor
  rc_is 1
  has_line fail 'required tools' 'missing: pgrep: sudo apt install procps'
}

t_hint_required_unknown() {
  rm "$T/bin/tar" "$T/bin/md5sum"
  run "$T" doctor
  rc_is 1
  has_line fail 'required tools' 'missing: tar md5sum: install tar coreutils with your package manager'
}

t_hint_required_dedup() {
  osr_set 'ID=debian\n'
  rm "$T/bin/sha256sum" "$T/bin/md5sum"
  run "$T" doctor
  rc_is 1
  has_line fail 'required tools' 'missing: sha256sum md5sum: sudo apt install coreutils'
}

# ---------- static: one reader, no override ----------

t_static_detect_once() {
  local o f
  [ "$(grep -c '^distro_detect() {$' "$ROOT/lib/common.sh")" = 1 ] || ERRS+=('distro_detect is not defined exactly once in lib/common.sh')
  [ "$(grep -c '^distro_detect$' "$ROOT/lib/common.sh")" = 1 ] || ERRS+=('distro_detect is not called exactly once at top level in lib/common.sh')
  for f in "$ROOT/w3c-linux.sh" "$ROOT"/lib/*.sh; do
    [ "$f" = "$ROOT/lib/common.sh" ] && continue
    o=$(grep -vE '^[[:space:]]*#' "$f" | grep -n 'distro_detect')
    [ -z "$o" ] || ERRS+=("$f calls distro_detect: $o")
  done
  o=$(grep -vE '^[[:space:]]*#' "$ROOT/w3c-linux.sh" "$ROOT"/lib/*.sh | grep -F 'W3C_DIS')
  [ -z "$o" ] || ERRS+=("an environment override for the distro: $o")
}

# ---------- HINT-02: the NAT and zenity hints ----------

# nat_hint_is CONTENT HINT: an install with neither nft nor iptables ends the NAT block with HINT, naming only nftables (D-07, D-09).
nat_hint_is() {
  nat_setup
  nat_none
  [ -z "$1" ] || osr_set "$1"
  FEED=$'y\nn\n'
  rm -f "$T/home/.local/state/w3c-linux/nat-applied"
  run "$T" install
  rc_is 0
  out_has "(for example: $2), then rerun."
  lacks_text iptables-nft
}
t_hint_nat_arch() { nat_hint_is 'ID=arch\n' 'sudo pacman -S nftables'; }
t_hint_nat_fedora() { nat_hint_is 'ID=fedora\n' 'sudo dnf install nftables'; }
t_hint_nat_debian() { nat_hint_is 'ID=debian\n' 'sudo apt install nftables'; }
t_hint_nat_unknown() { nat_hint_is '' 'install nftables with your package manager'; }

# zenity_hint_is CONTENT COMMAND: a menu start with no zenity refuses with COMMAND in the notification and in launch.log (D-07).
zenity_hint_is() {
  local D07_TEXT="zenity is required to launch from the menu: $2, or run w3c-linux.sh launch from a terminal"
  l_setup
  notify_shim
  CASE_ENV=(W3C_ASSUME_TTY= DISPLAY=:0)
  osr_set "$1"
  run "$T" launch
  refusal_is
}
t_hint_zenity_arch() { zenity_hint_is 'ID=arch\n' 'sudo pacman -S zenity'; }
t_hint_zenity_fedora() { zenity_hint_is 'ID=fedora\n' 'sudo dnf install zenity'; }
t_hint_zenity_debian() { zenity_hint_is 'ID=debian\n' 'sudo apt install zenity'; }

# missing_hint_is TOOL OSR COMMAND: a menu launch with TOOL off PATH stops with COMMAND in its text (D-07, D-08); OSR '' means no os-release.
missing_hint_is() {
  nt_setup
  rm -f "$T/bin/$1"
  [ -z "$2" ] || osr_set "$2"
  run "$T" launch
  stop_is 1 "$1 is missing: $3, then rerun"
  no_umu
}
t_hint_setsid_arch() { missing_hint_is setsid 'ID=arch\n' 'sudo pacman -S util-linux'; }
t_hint_setsid_fedora() { missing_hint_is setsid 'ID=fedora\n' 'sudo dnf install util-linux-core'; }
t_hint_setsid_debian() { missing_hint_is setsid 'ID=debian\n' 'sudo apt install util-linux'; }
t_hint_flock_arch() { missing_hint_is flock 'ID=arch\n' 'sudo pacman -S util-linux'; }
t_hint_flock_fedora() { missing_hint_is flock 'ID=fedora\n' 'sudo dnf install util-linux-core'; }
t_hint_flock_debian() { missing_hint_is flock 'ID=debian\n' 'sudo apt install util-linux'; }
t_hint_flock_unknown() { missing_hint_is flock '' 'install util-linux with your package manager'; }

# ---------- HINT-02 / UMU-01: the missing-umu-run row (Phase 15 D-01, D-03) ----------

# umu_hint_is OSR BACKEND WANT: with no umu-run anywhere the umu-run row is WANT; OSR '' means no os-release; BACKEND is faugus or umu.
umu_hint_is() {
  rm -f "$T/home/.local/share/faugus-launcher/umu-run"
  if [ "$2" = umu ]; then
    mkdir -p "$T/pfx/drive_c"
    CASE_ENV+=("W3C_PREFIX=$T/pfx" "W3C_PROTON=GE-Proton-test")
  fi
  [ -z "$1" ] || osr_set "$1"
  run "$T" doctor
  has_line fail umu-run "$3"
  if [ "$2" = umu ]; then lacks_text 'Faugus so it downloads'; fi
}
t_hint_umu_arch_faugus() { umu_hint_is 'ID=arch\n' faugus 'Launch any game once in Faugus so it downloads umu-run, or sudo pacman -S umu-launcher, or set UMU_RUN to its path'; }
t_hint_umu_arch_umu() { umu_hint_is 'ID=arch\n' umu 'sudo pacman -S umu-launcher, or set UMU_RUN to its path'; }
t_hint_umu_fedora_faugus() { umu_hint_is 'ID=fedora\n' faugus 'Launch any game once in Faugus so it downloads umu-run, or install umu-launcher from https://github.com/Open-Wine-Components/umu-launcher/releases/latest, or set UMU_RUN to its path'; }
t_hint_umu_fedora_umu() { umu_hint_is 'ID=fedora\n' umu 'install umu-launcher from https://github.com/Open-Wine-Components/umu-launcher/releases/latest, or set UMU_RUN to its path'; }
t_hint_umu_debian_faugus() { umu_hint_is 'ID=debian\n' faugus 'Launch any game once in Faugus so it downloads umu-run, or install umu-launcher from https://github.com/Open-Wine-Components/umu-launcher/releases/latest, or set UMU_RUN to its path'; }
t_hint_umu_debian_umu() { umu_hint_is 'ID=debian\n' umu 'install umu-launcher from https://github.com/Open-Wine-Components/umu-launcher/releases/latest, or set UMU_RUN to its path'; }
t_hint_umu_unknown_faugus() { umu_hint_is '' faugus 'Launch any game once in Faugus so it downloads umu-run, or install umu-launcher with your package manager, or set UMU_RUN to its path'; }
t_hint_umu_unknown_umu() { umu_hint_is '' umu 'install umu-launcher with your package manager, or set UMU_RUN to its path'; }

# no package-manager command text, and no generic unknown-family phrase, outside install_hint; the pattern matches inside it (D-07)
t_static_no_hardcoded_hints() {
  local re='pacman -S|dnf install|apt install|apt-get install|with your package manager' awkp o
  # shellcheck disable=SC2016 # awk program text
  awkp='/^[a-z_0-9]+\(\) \{$/ {fn = $1; sub(/\(\).*/, "", fn); next} /^\}$/ {fn = ""; next} /^[[:space:]]*#/ {next}'
  o=$(awk "$awkp"' fn != "install_hint" && /'"$re"'/ {print FILENAME ":" FNR ": " $0}' "$ROOT/w3c-linux.sh" "$ROOT"/lib/*.sh)
  [ -z "$o" ] || ERRS+=("package-manager command outside install_hint: $o")
  o=$(awk "$awkp"' fn == "install_hint" && /'"$re"'/' "$ROOT/lib/common.sh")
  [ -n "$o" ] || ERRS+=('the hint pattern matches nothing inside install_hint')
}

# ---------- HINT-03: Faugus's version from the family's package manager ----------

# argv_shim PROG ARGV BODY: a #!/bin/sh shim that logs "$*" to $MARK/PROG and runs BODY only when the argv is exactly ARGV (as in tests/phase1.sh t_fv_pacman).
argv_shim() {
  # shellcheck disable=SC2016 # the shim body is written literally and expanded when the shim runs
  {
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$MARK/%s"\n' "$1"
    printf '[ "$*" = '\''%s'\'' ] || exit 1\n%s\n' "$2" "$3"
  } > "$T/bin/$1"
  chmod +x "$T/bin/$1"
}

# fv_is OSR PROG ARGV BODY WANT: with no readable Faugus package, the family from OSR ('' for none) queries PROG once and doctor shows WANT
# (a version is a pass row, unknown a warn row). Only PROG may run.
fv_is() {
  local FORBIDDEN=() n
  for n in wine wineserver sudo nft iptables pacman rpm dpkg-query dnf apt apt-get; do [ "$n" = "$2" ] || FORBIDDEN+=("$n"); done
  CASE_ENV=("W3C_FAUGUS_PY_DIR=$T/nofaugus")
  [ -z "$1" ] || osr_set "$1"
  argv_shim "$2" "$3" "$4"
  run "$T" doctor
  if [ "$5" = unknown ]; then has_line warn 'faugus version' unknown; else has_line pass 'faugus version' "$5"; fi
  [ "$(grep -c . "$T/marks/$2" 2> /dev/null)" = 1 ] || ERRS+=("$2 did not run exactly once")
}

PAC_ARGV='-Q faugus-launcher'
RPM_ARGV='-q --qf %{VERSION}\n faugus-launcher'
# shellcheck disable=SC2016 # dpkg-query's own format text
DPKG_ARGV='-W -f=${db:Status-Status} ${Version}\n faugus-launcher'
DPKG_ABSENT="printf 'dpkg-query: no packages found matching faugus-launcher\\n' >&2; exit 1"

t_fv_arch_epoch() { fv_is 'ID=arch\n' pacman "$PAC_ARGV" "printf 'faugus-launcher 1:2.4.4-1\\n'" 2.4.4; }
t_fv_fedora() { fv_is 'ID=fedora\n' rpm "$RPM_ARGV" "printf '2.4.4\\n'" 2.4.4; }
t_fv_fedora_absent() { fv_is 'ID=fedora\n' rpm "$RPM_ARGV" "printf 'package faugus-launcher is not installed\\n'; exit 1" unknown; }
t_fv_debian_deb() { fv_is 'ID=debian\n' dpkg-query "$DPKG_ARGV" "printf 'installed 2.4.4-1\\n'" 2.4.4; }
t_fv_debian_ppa() { fv_is 'ID=debian\n' dpkg-query "$DPKG_ARGV" "printf 'installed 2.4.4-1~noble1\\n'" 2.4.4; }
t_fv_debian_epoch() { fv_is 'ID=debian\n' dpkg-query "$DPKG_ARGV" "printf 'installed 1:2.4.4-1\\n'" 2.4.4; }
# a removed package keeps its config-files status and its old version: it must not show
t_fv_debian_removed() { fv_is 'ID=debian\n' dpkg-query "$DPKG_ARGV" "printf 'config-files 2.4.3-1\\n'" unknown; }
t_fv_debian_absent() { fv_is 'ID=debian\n' dpkg-query "$DPKG_ARGV" "$DPKG_ABSENT" unknown; }

# no os-release: dnf on PATH makes the family fedora, so the rpm query runs and dnf never does
t_fv_probed_fedora() {
  add_shim "$T" dnf
  fv_is '' rpm "$RPM_ARGV" "printf '2.4.4\\n'" 2.4.4
}

# the unknown family runs no query at all (D-12)
t_fv_unknown() {
  add_shim "$T" rpm
  add_shim "$T" dpkg-query
  CASE_ENV=("W3C_FAUGUS_PY_DIR=$T/nofaugus")
  osr_set 'PRETTY_NAME="openSUSE Tumbleweed"\nID="opensuse-tumbleweed"\nID_LIKE="opensuse suse"\n'
  run "$T" doctor
  has_line warn 'faugus version' unknown
}

# Faugus's own files give the version: no package manager runs, whatever the family, and doctor changes nothing
t_pm_doctor_readable() {
  local n osr
  for n in pacman rpm dpkg-query dnf apt apt-get; do add_shim "$T" "$n"; done
  for osr in 'ID=arch\n' 'ID=fedora\n' 'ID=debian\n'; do
    CASE_ENV=()
    osr_set "$osr"
    run "$T" doctor
    has_line pass 'faugus version' 2.4.2
    changed_is
  done
}

t_pm_report_readable() {
  local n osr
  for n in pacman rpm dpkg-query dnf apt apt-get; do add_shim "$T" "$n"; done
  for osr in 'ID=arch\n' 'ID=fedora\n' 'ID=debian\n'; do
    CASE_ENV=()
    osr_set "$osr"
    run "$T" report
    rc_is 0
    grep -qxF "$(printf '%-10s %s' faugus 2.4.2)" <<< "$OUT" || ERRS+=("report lacks the faugus 2.4.2 line for $osr")
  done
}

# ---------- HINT-01: optional rows, the distro row, the PATH probe ----------

# distro_is CONTENT DISPLAY: os-release CONTENT (printf %b), doctor passes, and its distro row is DISPLAY.
distro_is() {
  osr_set "$1"
  run "$T" doctor
  rc_is 0
  has_line pass distro "$2"
}

t_hint_optional_fedora() {
  osr_set 'ID=fedora\n'
  rm "$T/bin/nft" "$T/bin/iptables" "$T/bin/notify-send" "$T/bin/sudo"
  run "$T" doctor
  values_are 'optional tool' 'zenity absent: sudo dnf install zenity' 'nft absent: sudo dnf install nftables' \
    'iptables absent: sudo dnf install iptables-nft' 'sudo absent' 'notify-send absent: sudo dnf install libnotify'
}

t_hint_optional_debian() {
  osr_set 'ID=debian\n'
  rm "$T/bin/nft" "$T/bin/iptables" "$T/bin/notify-send" "$T/bin/sudo"
  run "$T" doctor
  values_are 'optional tool' 'zenity absent: sudo apt install zenity' 'nft absent: sudo apt install nftables' \
    'iptables absent: sudo apt install iptables' 'sudo absent' 'notify-send absent: sudo apt install libnotify-bin'
}

t_hint_optional_arch() {
  osr_set 'ID=arch\n'
  rm "$T/bin/nft" "$T/bin/iptables" "$T/bin/notify-send" "$T/bin/sudo"
  run "$T" doctor
  values_are 'optional tool' 'zenity absent: sudo pacman -S zenity' 'nft absent: sudo pacman -S nftables' \
    'iptables absent: sudo pacman -S iptables' 'sudo absent' 'notify-send absent: sudo pacman -S libnotify'
}

t_hint_present() {
  osr_set 'ID=arch\n'
  add_shim "$T" zenity
  run "$T" doctor
  rc_is 0
  values_are 'optional tool' 'zenity present' 'nft present' 'iptables present' 'sudo present' 'notify-send present'
  values_are 'required tools' 'curl python3 sha256sum tar md5sum pgrep'
  lacks_text 'pacman -S'
}

t_distro_arch() { distro_is 'NAME="Arch Linux"\nPRETTY_NAME="Arch Linux"\nID=arch\nBUILD_ID=rolling\n' 'Arch Linux (arch)'; }
t_distro_fedora() { distro_is 'PRETTY_NAME="Fedora Linux 43 (Workstation Edition)"\nVERSION_ID=43\nID=fedora\n' 'Fedora Linux 43 (Workstation Edition) (fedora)'; }
t_distro_debian() { distro_is 'PRETTY_NAME="Debian GNU/Linux 13 (trixie)"\nID=debian\n' 'Debian GNU/Linux 13 (trixie) (debian)'; }
t_distro_ubuntu() { distro_is 'PRETTY_NAME="Ubuntu 24.04.3 LTS"\nID=ubuntu\nID_LIKE=debian\n' 'Ubuntu 24.04.3 LTS (debian)'; }
t_distro_manjaro() { distro_is 'PRETTY_NAME="Manjaro Linux"\nID=manjaro\nID_LIKE=arch\n' 'Manjaro Linux (arch)'; }
t_distro_nobara() { distro_is 'PRETTY_NAME="Nobara Linux 42 (KDE Plasma)"\nID=nobara\nID_LIKE="rhel centos fedora"\n' 'Nobara Linux 42 (KDE Plasma) (fedora)'; }
t_distro_pop() { distro_is 'PRETTY_NAME="Pop!_OS 22.04 LTS"\nID=pop\nID_LIKE="ubuntu debian"\n' 'Pop!_OS 22.04 LTS (debian)'; }
t_distro_rocky_quoted() { distro_is 'PRETTY_NAME="Rocky Linux 9.5 (Blue Onyx)"\nID="rocky"\nID_LIKE="rhel centos fedora"\n' 'Rocky Linux 9.5 (Blue Onyx) (fedora)'; }
# priority arch > fedora > debian whatever the word order (D-01); single quotes are stripped like double ones
t_distro_priority() { distro_is "PRETTY_NAME='Weird OS'\nID='weird'\nID_LIKE='debian fedora arch'\n" 'Weird OS (arch)'; }
# whole words only, exact keys only
t_distro_whole_word() {
  distro_is 'PRETTY_NAME="Remix OS"\nID=remix\nID_LIKE="fedora-remix archlinux-ish"\nVERSION_ID=arch\nVARIANT_ID=fedora\n' 'Remix OS (unknown)'
}
t_distro_no_pretty() { distro_is 'ID=fedora\n' fedora; }

# a PRETTY_NAME holding a command substitution and backticks is printed as text and nothing runs (T-12-01)
t_distro_literal_text() {
  local pn
  pn="x \$(touch $T/pwned) \`touch $T/pwned2\` y"
  osr_set 'PRETTY_NAME="'"$pn"'"\nID=arch\n'
  run "$T" doctor
  rc_is 0
  has_line pass distro "$pn (arch)"
  [ -e "$T/pwned" ] || [ -e "$T/pwned2" ] && ERRS+=('os-release text ran as a command')
  changed_is
}

# the real CachyOS file has no ID_LIKE: the PATH probe finds pacman (RESEARCH Pitfall 1)
t_probe_cachyos() {
  add_shim "$T" pacman
  distro_is 'NAME="CachyOS Linux"\nPRETTY_NAME="CachyOS"\nID=cachyos\nBUILD_ID=rolling\n' 'CachyOS (arch, from pacman on PATH)'
}

t_probe_zorin() {
  add_shim "$T" apt-get
  distro_is 'PRETTY_NAME="Zorin OS 17.3"\nID=zorin\nID_LIKE=ubuntu\n' 'Zorin OS 17.3 (debian, from apt-get on PATH)'
}

# no os-release: pacman, then dnf, then apt-get; no shim may run (FORBIDDEN)
t_probe_order() {
  add_shim "$T" pacman
  add_shim "$T" dnf
  add_shim "$T" apt-get
  run "$T" doctor
  has_line pass distro 'arch (from pacman on PATH)'
  rm "$T/bin/pacman"
  run "$T" doctor
  has_line pass distro 'fedora (from dnf on PATH)'
  rm "$T/bin/dnf"
  run "$T" doctor
  has_line pass distro 'debian (from apt-get on PATH)'
  changed_is
}

t_probe_none() {
  run "$T" doctor
  rc_is 0
  has_line pass distro unknown
}

t_probe_opensuse() { distro_is 'PRETTY_NAME="openSUSE Tumbleweed"\nID="opensuse-tumbleweed"\nID_LIKE="opensuse suse"\n' 'openSUSE Tumbleweed (unknown)'; }

t_probe_empty_osr() {
  add_shim "$T" dnf
  distro_is '' 'fedora (from dnf on PATH)'
}

# ---------- HINT-01: report prints the family from the one os-release read ----------

# no os-release and dnf on PATH: report says so, and dnf never runs
t_distro_report_probed() {
  add_shim "$T" dnf
  run "$T" report
  rc_is 0
  grep -qxF -- "$(printf '%-10s %s' distro 'fedora (from dnf on PATH)')" <<< "$OUT" || ERRS+=('report lacks the probed distro line')
}

# os-release is read by distro_detect only, and nothing sources it (D-02)
t_static_one_os_release_reader() {
  local o
  # shellcheck disable=SC2016 # awk program text
  o=$(awk '/^[a-z_0-9]+\(\) \{$/ {fn = $1; sub(/\(\).*/, "", fn); next} /^\}$/ {fn = ""; next} /^[[:space:]]*#/ {next} fn != "distro_detect" && /os-release/ {print FILENAME ":" FNR ": " $0}' "$ROOT/w3c-linux.sh" "$ROOT"/lib/*.sh)
  [ -z "$o" ] || ERRS+=("os-release read outside distro_detect: $o")
  # shellcheck disable=SC2016 # awk program text
  o=$(awk '/^[a-z_0-9]+\(\) \{$/ {fn = $1; sub(/\(\).*/, "", fn); next} /^\}$/ {fn = ""; next} /^[[:space:]]*#/ {next} fn == "distro_detect" && /os-release/' "$ROOT/lib/common.sh")
  [ -n "$o" ] || ERRS+=('distro_detect does not read os-release')
  o=$(grep -vE '^[[:space:]]*#' "$ROOT/w3c-linux.sh" "$ROOT"/lib/*.sh | grep -E '(^|[[:space:];&|(])(\.|source)[[:space:]].*os-release')
  [ -z "$o" ] || ERRS+=("os-release is sourced: $o")
}

# ---------- HINT-04: the README names the three families and says what each installs (static) ----------

# readme_section HEADING: the README text from the line HEADING to the next `## ` heading.
readme_section() { awk -v h="$1" '$0 == h { on = 1; next } on && /^## / { exit } on' "$ROOT/README.md"; }
# readme_sub HEADING: the README text from the `### ` line HEADING to the next `### ` or `## ` heading.
readme_sub() { awk -v h="$1" '$0 == h { on = 1; next } on && /^##/ { exit } on' "$ROOT/README.md"; }

# the opening names the families, and the Requirements table's first row does too (D-13)
t_readme_intro() {
  local top
  top=$(sed -n '/^## Contents$/q;p' "$ROOT/README.md")
  grep -qF -- 'on Linux (Arch, Fedora, Debian/Ubuntu and their derivatives)' <<< "$top" || ERRS+=('intro lacks the three families')
  ! grep -qF -- 'on Arch Linux' <<< "$top" || ERRS+=('intro still says on Arch Linux')
  readme_section '## Requirements' | grep '^| ' | sed -n 2p | grep -qF -- '| Arch, Fedora or Debian/Ubuntu (or derivatives), x86_64' || ERRS+=('first Requirements row does not name the families')
}

# Arch, Fedora, Debian/Ubuntu, each once, before With make
t_readme_family_order() {
  local got
  got=$(readme_section '## Installation' | grep '^### ' | head -n 4 | tr '\n' '|')
  [ "$got" = '### Arch|### Fedora|### Debian/Ubuntu|### With make|' ] || ERRS+=("Installation subsections start: $got")
  [ "$(grep -c -e '^### Arch$' -e '^### Fedora$' -e '^### Debian/Ubuntu$' "$ROOT/README.md")" = 3 ] || ERRS+=('want each family heading once')
}

# one dependency line per family, inside its subsection, and no second copy of the command anywhere (D-15)
t_readme_family_lines() {
  local fam head
  for fam in Arch Fedora Debian/Ubuntu; do
    [ "$(grep -c -- "^On $fam: " "$ROOT/README.md")" = 1 ] || ERRS+=("want one 'On $fam:' line")
    [ "$(readme_sub "### $fam" | grep -c -- "^On $fam: ")" = 1 ] || ERRS+=("'On $fam:' is not in its subsection")
    [ "$(readme_sub "### $fam" | grep -c 'Faugus')" -ge 1 ] || ERRS+=("### $fam says nothing about Faugus")
  done
  for head in 'pacman -S --needed curl' 'dnf install curl' 'apt install curl'; do
    [ "$(grep -cF -- "$head" "$ROOT/README.md")" = 1 ] || ERRS+=("want '$head' once in README.md")
  done
}

# each README line is what install_hint prints for the doctor's tools in that family, so the README and the hints share one table
t_readme_lines_match_table() {
  local fam name want got tools='curl python3 sha256sum tar pgrep setsid nft zenity notify-send'
  for fam in arch:Arch fedora:Fedora debian:Debian/Ubuntu; do
    name=${fam#*:}
    fam=${fam%%:*}
    want=$(sed -n "s/^On ${name//\//\\/}: \`\\(.*\\)\`\$/\\1/p" "$ROOT/README.md")
    [ "$fam" = arch ] && want=${want/ -S --needed / -S }
    got=$(
      # shellcheck disable=SC1090 # sourced from a process substitution
      source <(sed -n -e '/^pkg_name() {$/,/^}$/p' -e '/^install_hint() {$/,/^}$/p' "$ROOT/lib/common.sh")
      export DISTRO_FAMILY=$fam
      # shellcheck disable=SC2086 # the tool list is split on purpose
      install_hint $tools
    )
    [ -n "$want" ] && [ "$got" = "$want" ] || ERRS+=("$fam: README [$want] vs install_hint [$got]")
  done
}

# how to get Faugus Launcher, per family (D-14)
t_readme_faugus() {
  local s
  readme_sub '### Arch' | grep -qF -- 'yay -S faugus-launcher' || ERRS+=('### Arch lacks: yay -S faugus-launcher')
  for s in 'sudo dnf copr enable faugus/faugus-launcher' 'sudo dnf install faugus-launcher'; do
    readme_sub '### Fedora' | grep -qF -- "$s" || ERRS+=("### Fedora lacks: $s")
  done
  for s in 'sudo dpkg --add-architecture i386' 'sudo add-apt-repository ppa:faugus/faugus-launcher' 'sudo apt install faugus-launcher' \
    'https://github.com/Faugus/faugus-launcher/releases/latest' '_all.deb'; do
    readme_sub '### Debian/Ubuntu' | grep -qF -- "$s" || ERRS+=("### Debian/Ubuntu lacks: $s")
  done
  ! grep -qF -- '/releases/download/' "$ROOT/README.md" || ERRS+=('README holds a versioned asset URL')
}

# CONTRIBUTING.md holds the dev sections, the README holds none of them, and neither names the dev-only design document (D-16)
t_readme_contributing() {
  local c=$ROOT/CONTRIBUTING.md h design
  design=DESIGN.md
  [ -f "$c" ] || { ERRS+=('CONTRIBUTING.md is missing'); return 0; }
  for h in '## Layout' '## Tests' '## CI tests' '## Nightly check'; do
    [ "$(grep -cxF -- "$h" "$c")" = 1 ] || ERRS+=("CONTRIBUTING.md wants one '$h'")
    ! grep -qxF -- "$h" "$ROOT/README.md" || ERRS+=("README.md still has '$h'")
  done
  [ "$(grep -c '(CONTRIBUTING.md)' "$ROOT/README.md")" = 1 ] || ERRS+=('README.md wants one link to CONTRIBUTING.md')
  grep -qF -- 'dev repo only' "$c" || ERRS+=('CONTRIBUTING.md lost "dev repo only"')
  grep -qF -- 'only in the private dev repo' "$c" || ERRS+=('CONTRIBUTING.md lost "only in the private dev repo"')
  grep -qF -- 'Phase 12' "$c" || ERRS+=('CONTRIBUTING.md Tests does not cover Phase 12')
  ! grep -qF -- "$design" "$c" "$ROOT/README.md" || ERRS+=('README.md or CONTRIBUTING.md names the design document')
  ! grep -qiE 'workflows? runs? in the public' "$c" "$ROOT/README.md" || ERRS+=('a doc says the workflows run in the public repo')
}

# the Doctor section has no sample, and its tables describe the distro row and the per-family commands (D-17)
t_readme_doctor() {
  local d
  d=$(readme_section '## Doctor')
  [ "$(grep -c '^pass  ' <<< "$d")" -lt 5 ] || ERRS+=('Doctor still has a sample run')
  grep -q '^| .distro. |' <<< "$d" || ERRS+=('Doctor lacks the distro row')
  grep '^| .faugus version. |' <<< "$d" | grep -F 'rpm -q' | grep -qF 'dpkg-query -W' || ERRS+=('faugus version row lacks rpm -q and dpkg-query -W')
}

# anchors_of FILE: the GitHub heading anchors of FILE (fenced blocks skipped)
anchors_of() {
  awk '/^```/ {f = !f; next} !f && /^#+ / {sub(/^#+ +/, ""); print}' "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9 _-]//g' -e 's/ /-/g'
}

# every link to a heading resolves, and the dropped untagged-checkout recipe is not pointed at (D-18)
t_readme_anchors() {
  local f a link
  for f in README.md CONTRIBUTING.md; do
    [ -f "$ROOT/$f" ] || { ERRS+=("$f is missing"); continue; }
    while IFS= read -r a; do
      anchors_of "$ROOT/$f" | grep -qxF -- "$a" || ERRS+=("$f: no heading for #$a")
    done < <(grep -o '](#[^)]*)' "$ROOT/$f" | sed -e 's/^](#//' -e 's/)$//')
  done
  while IFS= read -r link; do
    anchors_of "$ROOT/README.md" | grep -qxF -- "$link" || ERRS+=("CONTRIBUTING.md: README.md has no heading for #$link")
  done < <(grep -o '](README.md#[^)]*)' "$ROOT/CONTRIBUTING.md" | sed -e 's/^](README.md#//' -e 's/)$//')
  ! grep -qi 'untagged checkout' "$ROOT/README.md" "$ROOT/CONTRIBUTING.md" "$ROOT/packaging/PKGBUILD" "$ROOT/docs/ARCHITECTURE.md" || ERRS+=('something still names the untagged checkout recipe')
  grep -qF -- 'git archive' "$ROOT/packaging/PKGBUILD" && grep -qF -- '--skipinteg' "$ROOT/packaging/PKGBUILD" || ERRS+=('the PKGBUILD comment lacks the git archive recipe')
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
