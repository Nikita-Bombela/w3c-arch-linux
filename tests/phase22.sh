#!/usr/bin/env bash
# Phase 22 fixture check: the printed NAT persistence recipe (DEBT-01), on the harness of tests/phase20.sh. install prints a oneshot
# w3c-nat.service the user pastes; the cases prove its ExecStart runs exactly the printed apply command, that the heredoc pastes, that systemd
# accepts the unit, and the per-family warning text. No case runs sudo, systemd (systemd-analyze only reads a file), a real Steam or a network
# call, and no case reads the planning directory, because tests/ ships in the public snapshot. The nvidia cases (DEBT-05) build the kernel module file
# and the library links under W3C_SYS_ROOT and never run a GPU tool.
# The Phase 23 D-12 walk styling cases (styled bytes on a terminal, plain everywhere else, the still-waiting line) live here because they drive
# update's Warcraft III walk.
# Usage: bash tests/phase22.sh [GLOB]   (GLOB filters on display names such as nat-unit-paste)
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=phase20.sh
source "$(dirname "${BASH_SOURCE[0]}")/phase20.sh"

# this suite has its own cases only
mapfile -t P20_CASES < <(compgen -A function t_)
unset -f "${P20_CASES[@]}"

# pgrep and pkill (the process rules and the Edge updater) and steam (a recording shim) are expected; the rest must never run. The NAT decline
# cases never reach sudo, nft or iptables.
FORBIDDEN=(wine wineserver faugus-launcher steam-runtime-launch-client sudo umu-run nft iptables xdg-open)

# ---------- phase5 and phase12 helpers, pulled in by name so no case body is copied ----------

# shellcheck source=/dev/null
source <(sed -n '/^sudo_shim() {$/,/^}$/p' "$ROOT/tests/phase5.sh")
# shellcheck source=/dev/null
source <(sed -n '/^nat_setup() {$/,/^}$/p' "$ROOT/tests/phase5.sh")
# shellcheck source=/dev/null
source <(sed -n '/^printed_script() {$/,/^}$/p' "$ROOT/tests/phase5.sh")
# shellcheck source=/dev/null
source <(sed -n '/^sudo_call() { /p' "$ROOT/tests/phase5.sh")
# shellcheck source=/dev/null
source <(sed -n '/^sudo_calls() {$/,/^}$/p' "$ROOT/tests/phase5.sh")
# shellcheck source=/dev/null
source <(sed -n '/^out_before() {$/,/^}$/p' "$ROOT/tests/phase5.sh")
# shellcheck source=/dev/null
source <(sed -n '/^fw_shims() {$/,/^}$/p' "$ROOT/tests/phase5.sh")
# shellcheck source=/dev/null
source <(sed -n '/^nat_decline() {$/,/^}$/p' "$ROOT/tests/phase5.sh")
# shellcheck source=/dev/null
source <(sed -n '/^nat_none() { /p' "$ROOT/tests/phase5.sh")
# shellcheck source=/dev/null
source <(sed -n '/^block_text() { /p' "$ROOT/tests/phase5.sh")
# shellcheck source=/dev/null
source <(sed -n -e '/^NFT_SCRIPT=/p' -e '/^IPT_RULE=/p' "$ROOT/tests/phase5.sh")
# shellcheck source=/dev/null
source <(sed -n '/^osr_set() {$/,/^}$/p' "$ROOT/tests/phase12.sh")
# shellcheck source=/dev/null
source <(sed -n '/^nl_case() {$/,/^}$/p' "$ROOT/tests/phase5.sh")
# shellcheck source=/dev/null
source <(sed -n '/^wait_out() {$/,/^}$/p' "$ROOT/tests/phase5.sh")
# shellcheck source=/dev/null
source <(sed -n '/^nat_q_count() { /p' "$ROOT/tests/phase5.sh")

# the menu-style launch of phase6 (a launch with no terminal) and its launch.log readers
# shellcheck source=/dev/null
source <(sed -n '/^zenity_shim() {$/,/^}$/p' "$ROOT/tests/phase6.sh")
# shellcheck source=/dev/null
source <(sed -n '/^nt_env() {$/,/^}$/p' "$ROOT/tests/phase6.sh")
# shellcheck source=/dev/null
source <(sed -n '/^nt_setup() {$/,/^}$/p' "$ROOT/tests/phase6.sh")
# shellcheck source=/dev/null
source <(sed -n -e '/^log_text() { /p' -e '/^log_has() { /p' "$ROOT/tests/phase6.sh")

# ---------- helpers ----------

UNIT_TEE="sudo tee /etc/systemd/system/w3c-nat.service <<'EOF'"

# unit_block: the lines of OUT from the flush-left tee line through the first flush-left EOF; returns 1 when the tee line is absent.
unit_block() {
  local l on=0
  while IFS= read -r l; do
    if [ "$on" = 0 ] && [ "$l" = "$UNIT_TEE" ]; then on=1; fi
    if [ "$on" = 1 ]; then
      printf '%s\n' "$l"
      [ "$l" = EOF ] && return 0
    fi
  done <<< "$OUT"
  return 1
}

# unit_unescape STRING: STRING as systemd hands it to the shell: each %%, $$ and double backslash becomes one character, left to right.
# Returns 1 when a lone %, $ or backslash is met.
unit_unescape() {
  local s=$1 o='' c
  while [ -n "$s" ]; do
    c=${s:0:1}
    case $c in
      '%' | '$' | \\)
        [ "${s:1:1}" = "$c" ] || return 1
        o+=$c
        s=${s:2} ;;
      *)
        o+=$c
        s=${s:1} ;;
    esac
  done
  printf '%s' "$o"
}

# unit_exec_line: the one ExecStart line of the printed unit, its prefix and closing quote stripped; returns 1 unless there is exactly one.
unit_exec_line() {
  local l n=0 val=''
  while IFS= read -r l; do
    case $l in
      "ExecStart=/bin/sh -c '"*"'")
        n=$((n + 1))
        l=${l#"ExecStart=/bin/sh -c '"}
        val=${l%\'} ;;
    esac
  done < <(unit_block)
  [ "$n" = 1 ] || return 1
  printf '%s' "$val"
}

# rt_check VARIANT: the ExecStart word, un-escaped as systemd would, equals the printed `sudo sh -c` text byte for byte.
rt_check() {
  local v=$1 want got line
  nat_setup
  [ "$v" = nft ] || rm -f "$T/bin/nft"
  nat_decline
  rc_is 0
  want=$(printed_script) || ERRS+=('no printed sudo sh -c line')
  line=$(unit_exec_line) || { ERRS+=('want exactly one ExecStart line in the unit block'); return 0; }
  got=$(unit_unescape "$line") || { ERRS+=("a lone % \$ or backslash in the ExecStart word: $line"); return 0; }
  [ "$got" = "$want" ] || ERRS+=("ExecStart is not the printed command: want [$want] got [$got]")
  if [ "$v" = nft ]; then
    [ "$got" = "$NFT_SCRIPT" ] || ERRS+=("nft ExecStart differs from phase5's literal: $got")
  else
    [ "$got" = "iptables -t nat -C OUTPUT $IPT_RULE 2>/dev/null || iptables -t nat -A OUTPUT $IPT_RULE" ] || ERRS+=("iptables ExecStart differs: $got")
  fi
  changed_is
}

# nft_unit_text: the nine unit lines for the nft variant, spelled out by hand (a quoted heredoc is literal): %% for the printf's %, a doubled
# backslash before the n.
nft_unit_text() {
  cat << 'W'
[Unit]
Description=w3c-linux LAN-test NAT rule
After=network-pre.target firewalld.service ufw.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'printf "%%s\\n" "add table ip w3c" "delete table ip w3c" "add table ip w3c" "add chain ip w3c output { type nat hook output priority -100; policy accept; }" "add rule ip w3c output ip daddr 255.255.255.255 udp dport 16000 dnat to 127.0.0.1:16000" | nft -f -'
[Install]
WantedBy=multi-user.target
W
}

# ---------- cases ----------

t_nat_unit_roundtrip_nft() { rt_check nft; }
t_nat_unit_roundtrip_iptables() { rt_check iptables; }

# the block pastes: the enable line follows EOF, and the heredoc, run by bash with its target rewritten, writes the same unit text twice
t_nat_unit_paste() {
  local blk after want i
  nat_setup
  nat_decline
  rc_is 0
  after=$(awk '$0 == "EOF" { f = 1; next } f { print; exit }' <<< "$OUT")
  [ "$after" = '    sudo systemctl enable --now w3c-nat.service' ] || ERRS+=("the line after EOF is [$after]")
  blk=$(unit_block) || { ERRS+=('no tee block'); return 0; }
  printf -v blk 'tee %q <<'"'EOF'"' > /dev/null\n%s' "$TMPROOT/unit" "${blk#*$'\n'}"
  want=$(nft_unit_text)
  for i in 1 2; do
    rm -f "$TMPROOT/unit"
    "$BASH_BIN" -c "$blk" || ERRS+=("run $i of the block failed")
    [ "$(< "$TMPROOT/unit")" = "$want" ] || ERRS+=("run $i wrote a different unit: $(< "$TMPROOT/unit")")
  done
  changed_is
}

# systemd accepts the unit; skipped where systemd-analyze is missing (a CI container may lack it)
t_nat_unit_verify() {
  local blk out rc
  if ! type -P systemd-analyze > /dev/null; then
    printf '# skip: systemd-analyze missing\n' >&2
    return 0
  fi
  nat_setup
  nat_decline
  rc_is 0
  blk=$(unit_block) || { ERRS+=('no tee block'); return 0; }
  blk=${blk#*$'\n'}
  printf '%s\n' "${blk%$'\n'EOF}" > "$TMPROOT/w3c-nat.service"
  out=$(systemd-analyze verify "$TMPROOT/w3c-nat.service" 2>&1)
  rc=$?
  [ "$rc" = 0 ] || ERRS+=("systemd-analyze verify exit $rc")
  [ -z "$out" ] || ERRS+=("systemd-analyze verify said: $(tr '\n' '|' <<< "$out")")
  changed_is
}

# the removal block: the variant line, the marker line, then the unit's two lines (D-04), in that order
t_nat_unit_remove() {
  local want
  nat_setup
  nat_decline
  rc_is 0
  printf -v want '    rm -f %q' "$T/home/.local/state/w3c-linux/nat-applied"
  out_before '    sudo nft delete table ip w3c' "$want"
  out_before "$want" 'If you installed w3c-nat.service, also:'
  out_before 'If you installed w3c-nat.service, also:' '    sudo systemctl disable --now w3c-nat.service'
  out_before '    sudo systemctl disable --now w3c-nat.service' '    sudo rm /etc/systemd/system/w3c-nat.service'
  changed_is
}

# ---------- the family status and the one warning line (D-07, D-01, D-03) ----------

# fam_text FAMILY: sets FAM_ST and FAM_WARN, the header status and the warning line, spelled out here independently of lib/nat.sh.
fam_text() {
  case $1 in
    arch)
      FAM_ST='checked on Arch Linux'
      FAM_WARN='Arch: do not enable nftables.service for this: the stock /etc/nftables.conf is a default-drop input firewall and blocks inbound traffic, mDNS included.' ;;
    fedora)
      FAM_ST='UNVERIFIED on Fedora and Bazzite'
      FAM_WARN="Fedora and Bazzite: never enable nftables.service next to firewalld: stopping or reloading it flushes the whole ruleset (/etc/sysconfig/nftables.conf), firewalld's tables included." ;;
    debian)
      FAM_ST='UNVERIFIED on Debian, Ubuntu and Linux Mint'
      FAM_WARN='Debian, Ubuntu and Mint: do not enable nftables.service for this: the stock /etc/nftables.conf begins with flush ruleset, which wipes this rule and every other firewall'"'"'s rules at boot.' ;;
    *)
      FAM_ST='UNVERIFIED: distro family unknown'
      FAM_WARN='Do not enable a distro nftables.service whose config starts with flush ruleset next to another firewall.' ;;
  esac
}

# fam_check VARIANT: for each family, the header carries that family's status, its one warning prints and the other three do not, the unit is the
# variant's, and no command line or unit line flushes, saves the whole ruleset, grants sudo rights or enables a distro firewall service.
fam_check() {
  local v=$1 fam osr want_exec bad
  nat_setup
  [ "$v" = nft ] || rm -f "$T/bin/nft"
  if [ "$v" = nft ]; then want_exec='nft -f -'; else want_exec='iptables -t nat -C OUTPUT'; fi
  for fam in arch fedora debian unknown; do
    case $fam in
      arch) osr='ID=arch\n' ;;
      fedora) osr='ID=bazzite\nID_LIKE=fedora\n' ;;
      debian) osr='ID=linuxmint\nID_LIKE="ubuntu debian"\n' ;;
      unknown) osr='ID=void\n' ;;
    esac
    CASE_ENV=()
    osr_set "$osr"
    nat_decline
    rc_is 0
    fam_text "$fam"
    out_line "To keep it after a reboot (optional, printed only; $FAM_ST): a oneshot w3c-nat.service runs the same command at boot. Paste this block into a terminal:"
    out_line "$FAM_WARN"
    [ "$(grep -cF -- "$FAM_WARN" <<< "$OUT")" = 1 ] || ERRS+=("$fam: the warning does not print exactly once")
    lacks_text_unless "$fam" arch 'Arch: do not'
    lacks_text_unless "$fam" fedora 'Fedora and Bazzite:'
    lacks_text_unless "$fam" debian 'Debian, Ubuntu and Mint:'
    lacks_text_unless "$fam" unknown 'Do not enable a distro'
    case $(unit_block | grep -F 'ExecStart=') in
      *"$want_exec"*) ;;
      *) ERRS+=("$fam: the ExecStart line lacks $want_exec") ;;
    esac
    bad=$({ grep '^    ' <<< "$OUT"; unit_block; } | grep -e 'flush ruleset' -e '-save' -e 'NOPASSWD' -e 'enable nftables' -e 'enable iptables')
    [ -z "$bad" ] || ERRS+=("$fam: a command or unit line holds a forbidden text: $bad")
  done
  changed_is
}

# lacks_text_unless FAMILY OWN TEXT: OUT lacks TEXT unless FAMILY is OWN, the family whose warning starts with it.
lacks_text_unless() {
  [ "$1" = "$2" ] || lacks_text "$3"
}

t_nat_family_nft() { fam_check nft; }
t_nat_family_iptables() { fam_check iptables; }

# ---------- an active w3c-nat.service counts as applied (D-02) ----------

NAT_MARKER_REL=home/.local/state/w3c-linux/nat-applied
UNIT_ACTIVE_ARGV='is-active --quiet w3c-nat.service'

# unit_active: the systemctl shim answers 0 for w3c-nat.service only; timeout is linked in because nat_marker_ok reaches systemctl through it.
unit_active() {
  mkdir -p "$T/fix"
  fw_shims
  [ -e "$T/bin/timeout" ] || add_link "$T" timeout
  printf 'w3c-nat.service\n' > "$T/fix/active"
}

# the boot marker is read first: with it equal to this boot the unit is never asked, so phase5's pinned systemctl call list holds
t_nat_state_marker_first() {
  install_setup
  unit_active
  FEED=$'y\nn\n'
  run "$T" install
  rc_is 0
  out_has 'LAN-test NAT rule: applied this boot (by w3c-linux)'
  lacks_text 'persisted ('
  ! grep -qxF -- "$UNIT_ACTIVE_ARGV" "$T/marks/systemctl" || ERRS+=("systemctl was asked about the unit although the marker holds: $(tr '\n' ';' < "$T/marks/systemctl")")
  [ ! -e "$T/marks/sudo" ] || ERRS+=('sudo ran')
}

# marker gone, unit active: install says persisted, asks nothing about NAT, runs no sudo
t_nat_state_unit_install() {
  install_setup
  rm -f "$T/$NAT_MARKER_REL"
  unit_active
  FEED=$'y\nn\n'
  run "$T" install
  rc_is 0
  out_has 'LAN-test NAT rule: persisted (w3c-nat.service active); if you removed the rule since, run: sudo systemctl restart w3c-nat.service'
  lacks_text 'LAN-test NAT rule: applied this boot'
  case $ERR in *'Apply the LAN-test NAT rule now with sudo?'*) ERRS+=('the NAT question was asked although the unit is active') ;; esac
  grep -qxF -- "$UNIT_ACTIVE_ARGV" "$T/marks/systemctl" || ERRS+=('systemctl was not asked about the unit')
  [ ! -e "$T/marks/sudo" ] || ERRS+=('sudo ran')
}

# a LAN-test failure in launch, marker gone, unit active: the hint says persisted, no question, no NAT block
t_nat_state_unit_launch() {
  local FORBIDDEN=(wine wineserver nft iptables notify-send)   # launch runs umu-run and the launch client; sudo is checked by its mark file
  nl_case 1
  unit_active
  go
  rc_is 0
  out_has 'LAN test failed'
  out_has ' NAT rule persisted by w3c-nat.service (active); if you removed it since, run: sudo systemctl restart w3c-nat.service.'
  [ "$(nat_q_count)" = 0 ] || ERRS+=("NAT question count: want 0 got $(nat_q_count)")
  case $ERR in *'[y/N]'*) ERRS+=('a question was asked although the unit is active') ;; esac
  lacks_text 'LAN-test NAT rule ('
  [ ! -e "$T/marks/sudo" ] || ERRS+=('sudo ran')
}

# steam-wrap with the unit active: no NAT line, no notification, the command still runs
t_nat_state_unit_wrap() {
  wrap_setup
  rm -f "$T/$NAT_MARKER_REL"
  unit_active
  wrap_run "$T" steam-wrap "$T/bin/stub"
  rc_is 0
  wrap_ran
  [ "$(wlog_count "$NAT_LINE")" = 0 ] || ERRS+=('launch.log holds the NAT line although the unit is active')
  [ "$(notify_calls)" = 0 ] || ERRS+=("notify-send calls: want 0 got $(notify_calls)")
}

# steam-wrap with the unit not active: the Phase 20 line and the one notification
t_nat_state_inactive_wrap() {
  wrap_setup
  rm -f "$T/$NAT_MARKER_REL"
  unit_active
  : > "$T/fix/active"
  wrap_run "$T" steam-wrap "$T/bin/stub"
  rc_is 0
  wrap_ran
  wlog_has "$NAT_LINE"
  [ "$(notify_calls)" = 1 ] || ERRS+=("notify-send calls: want 1 got $(notify_calls)")
}

# ---------- doctor's nat rule row (D-06) ----------

# the row is info only: one pass row in each of the three states, and doctor's exit status is the same in all three
t_doctor_nat_row() {
  local rc0 n pre='pass  nat rule          '
  run "$T" doctor
  rc0=$RC
  out_line "${pre}applied this boot (w3c-linux)"
  rm -f "$T/$NAT_MARKER_REL"
  unit_active
  run "$T" doctor
  [ "$RC" = "$rc0" ] || ERRS+=("persisted: doctor rc $RC differs from $rc0")
  out_line "${pre}persisted (w3c-nat.service active)"
  n=$(grep -c '^[a-z]*  nat rule ' <<< "$OUT")
  [ "$n" = 1 ] || ERRS+=("persisted: $n nat rule rows")
  : > "$T/fix/active"
  run "$T" doctor
  [ "$RC" = "$rc0" ] || ERRS+=("not applied: doctor rc $RC differs from $rc0")
  out_line "${pre}not applied this boot: w3c-linux.sh install prints the rule and a reboot-proof recipe"
  n=$(grep -c '^[a-z]*  nat rule ' <<< "$OUT")
  [ "$n" = 1 ] || ERRS+=("not applied: $n nat rule rows")
  rm -f "$T/bin/systemctl"
  run "$T" doctor
  [ "$RC" = "$rc0" ] || ERRS+=("no systemctl: doctor rc $RC differs from $rc0")
  out_line "${pre}not applied this boot: w3c-linux.sh install prints the rule and a reboot-proof recipe"
}

# ---------- revert points at the block's removal lines and runs none of them (D-04) ----------

REV_NOTE='revert leaves the LAN-test NAT rule alone; if you applied or persisted it, remove it with:'

# rev_lines: the revert note, then the removal lines of the NAT block in its order (the nft variant, the marker, the unit's two lines), and no
# systemctl, sudo, nft or iptables call.
rev_lines() {
  local want
  printf -v want '    rm -f %q' "$T/home/.local/state/w3c-linux/nat-applied"
  out_before "$REV_NOTE" '    sudo nft delete table ip w3c'
  out_before '    sudo nft delete table ip w3c' "$want"
  out_before "$want" 'If you installed w3c-nat.service, also:'
  out_before 'If you installed w3c-nat.service, also:' '    sudo systemctl disable --now w3c-nat.service'
  out_before '    sudo systemctl disable --now w3c-nat.service' '    sudo rm /etc/systemd/system/w3c-nat.service'
  [ ! -e "$T/marks/systemctl" ] || ERRS+=("systemctl ran: $(tr '\n' ';' < "$T/marks/systemctl")")
}

# a Faugus revert back to a non-W3C runner prints the note and the lines after its own output
t_nat_revert_faugus() {
  fw_shims
  w3c_on
  FEED=$'y\n\n'
  run "$T" revert
  rc_is 0
  runner_is 'Proton-GE Latest'
  rev_lines
}

# a Steam full revert prints them after `The shortcut now runs on`
t_nat_revert_steam_full() {
  fw_shims
  srev_full proton_experimental
  run_fifo "$T" revert
  wait_err 'press Enter to check again'
  mk_mapping 3389133332:proton_experimental
  send $'\n'
  wait_err '[y/N]'
  send $'\n'
  finish
  rc_is 0
  out_before 'The shortcut now runs on proton_experimental.' "$REV_NOTE"
  rev_lines
}

# the already-off branch (the shortcut runs on a stock Proton) prints the note after its own line and before the removal question
t_nat_revert_steam_already_off() {
  fw_shims
  srev_full
  mk_mapping 3389133332:proton_9
  FEED=$'\n'
  run "$T" revert
  rc_is 0
  out_before 'revert: the shortcut already runs on proton_9, not a W3C build' "$REV_NOTE"
  rev_lines
  err_has '[y/N]'
}

# a step-back to an earlier W3C build leaves the W3C build family: no note, no unit line
t_nat_revert_step_back() {
  fw_shims
  steam_prev_setup
  ALLOW_EXTRA+=(home/.local/share/Steam/config/config.vdf)
  run_fifo "$T" revert
  wait_err 'press Enter to check again'
  mk_mapping "3389133332:$TAG"
  send $'\n'
  wait_err '[y/N]'
  send $'\n'
  finish
  rc_is 0
  lacks_text 'revert leaves the LAN-test NAT rule alone'
  lacks_text 'w3c-nat.service'
  [ ! -e "$T/marks/systemctl" ] || ERRS+=('systemctl ran')
}

# the README says the recipe is printed for the user's distro, lists the unit as written only by the user and the doctor row, and copies no unit text
# shellcheck disable=SC2016 # the backticks are literal README markdown
t_nat_docs_readme() {
  local f=$ROOT/README.md
  grep -qF 'prints a `w3c-nat.service` recipe for your distro' "$f" || ERRS+=('README lacks the printed-recipe sentence')
  grep -qF '| `/etc/systemd/system/w3c-nat.service` |' "$f" || ERRS+=('README lacks the Files row for the unit')
  grep -q '^| `nat rule` |' "$f" || ERRS+=('README lacks the nat rule doctor row')
  ! grep -q '^ExecStart=' "$f" || ERRS+=('README copies an ExecStart line')
}

# ---------- the nvidia row: the loaded kernel module against the userspace libraries, from files only (DEBT-05, D-08, D-09) ----------

# nv_tree FAMILY KV V64 V32 [LINK]: the family's os-release (W3C_SYS_ROOT=$T/sys), the module's version file holding KV and, in the family's first
# 64-bit and 32-bit directory, a relative LINK (default libGLX_nvidia.so.0, or libnvidia-ml.so.1) to the versioned file V64 and V32 name. A `-` writes
# nothing. Call it after any CASE_ENV=(...) assignment, because osr_set appends.
nv_tree() {
  local fam=$1 kv=$2 link=${5:-libGLX_nvidia.so.0} osr d64 d32 d v i=0
  case $fam in
    arch) osr='ID=arch\n' d64=/usr/lib d32=/usr/lib32 ;;
    fedora) osr='ID=bazzite\nID_LIKE="fedora"\n' d64=/usr/lib64 d32=/usr/lib ;;
    debian) osr='ID=linuxmint\nID_LIKE="ubuntu debian"\n' d64=/usr/lib/x86_64-linux-gnu d32=/usr/lib/i386-linux-gnu ;;
  esac
  osr_set "$osr"
  if [ "$kv" != - ]; then
    mkdir -p "$T/sys/sys/module/nvidia"
    printf '%s\n' "$kv" > "$T/sys/sys/module/nvidia/version"
  fi
  for d in "$d64" "$d32"; do
    i=$((i + 1))
    v=${*:2+i:1}
    [ "$v" = - ] && continue
    mkdir -p "$T/sys$d"
    ln -s "${link%.so.*}.so.$v" "$T/sys$d/$link"
  done
}

NV_FIX='reboot after a driver update; if it persists, reinstall the driver so module and libraries match'

# nv_msg K V64 V32: the warn text for a mismatch, spelled out here independently of lib/checks.sh.
nv_msg() { printf 'NVIDIA kernel module %s differs from its userspace libraries (64-bit %s, 32-bit %s): %s' "$1" "$2" "$3" "$NV_FIX"; }

# nv_doctor: doctor on a healthy tree with a marker shim for the GPU tool. D-09: nothing may run nvidia-smi, which can wake a discrete GPU or hang.
# nv_same_rc: doctor's exit status equals that of the same tree without the nvidia files (the row is a warn at most).
nv_doctor() {
  add_shim "$T" nvidia-smi
  run "$T" doctor
}
nv_same_rc() {
  local rc=$RC
  rm -rf "$T/sys/sys" "$T/sys/usr"
  run "$T" doctor
  [ "$RC" = "$rc" ] || ERRS+=("doctor rc $rc differs from $RC without the nvidia files")
}
nv_case() {
  l_setup
  nv_tree "$@"
  nv_doctor
}

t_nvidia_match() {
  local FORBIDDEN=("${FORBIDDEN[@]}" nvidia-smi)
  nv_case arch 615.78.08 615.78.08 615.78.08
  has_line pass nvidia '615.78.08 (kernel = 64-bit = 32-bit)'
  values_are nvidia '615.78.08 (kernel = 64-bit = 32-bit)'
  nv_same_rc
}

t_nvidia_mismatch64() {
  local FORBIDDEN=("${FORBIDDEN[@]}" nvidia-smi)
  nv_case arch 615.78.08 610.43.02 615.78.08
  has_line warn nvidia "$(nv_msg 615.78.08 610.43.02 615.78.08)"
  values_are nvidia "$(nv_msg 615.78.08 610.43.02 615.78.08)"
  nv_same_rc
}

t_nvidia_mismatch32() {
  local FORBIDDEN=("${FORBIDDEN[@]}" nvidia-smi)
  nv_case arch 615.78.08 615.78.08 610.43.02
  has_line warn nvidia "$(nv_msg 615.78.08 615.78.08 610.43.02)"
  values_are nvidia "$(nv_msg 615.78.08 615.78.08 610.43.02)"
  nv_same_rc
}

t_nvidia_no32() {
  local FORBIDDEN=("${FORBIDDEN[@]}" nvidia-smi)
  nv_case arch 615.78.08 615.78.08 -
  has_line pass nvidia '615.78.08 (kernel = 64-bit; 32-bit not found)'
  values_are nvidia '615.78.08 (kernel = 64-bit; 32-bit not found)'
  nv_same_rc
}

# no module loaded: no row at all, whatever the library directories hold
t_nvidia_nomodule() {
  local FORBIDDEN=("${FORBIDDEN[@]}" nvidia-smi)
  nv_case arch - 610.43.02 610.43.02
  values_are nvidia
  nv_same_rc
}

# a loaded module and no library link in any directory: stated, never a warn
t_nvidia_nolib() {
  local FORBIDDEN=("${FORBIDDEN[@]}" nvidia-smi)
  nv_case arch 615.78.08 - -
  has_line pass nvidia 'kernel 615.78.08 (userspace libraries not found; not compared)'
  values_are nvidia 'kernel 615.78.08 (userspace libraries not found; not compared)'
  nv_same_rc
}

# only the link the loader follows counts: an older versioned file next to the right link is ignored
t_nvidia_leftover() {
  local FORBIDDEN=("${FORBIDDEN[@]}" nvidia-smi)
  l_setup
  nv_tree arch 615.78.08 615.78.08 615.78.08
  : > "$T/sys/usr/lib/libGLX_nvidia.so.550.54.14"
  : > "$T/sys/usr/lib32/libGLX_nvidia.so.550.54.14"
  nv_doctor
  values_are nvidia '615.78.08 (kernel = 64-bit = 32-bit)'
}

# libnvidia-ml.so.1 stands in when there is no libGLX_nvidia.so.0
t_nvidia_ml_fallback() {
  local FORBIDDEN=("${FORBIDDEN[@]}" nvidia-smi)
  nv_case arch 615.78.08 615.78.08 615.78.08 libnvidia-ml.so.1
  values_are nvidia '615.78.08 (kernel = 64-bit = 32-bit)'
}

# Fedora's 64-bit directory is /usr/lib64 and its /usr/lib is 32-bit: a mismatch there names the 32-bit side, and a 32-bit library alone is never the 64-bit one
t_nvidia_fedora() {
  local FORBIDDEN=("${FORBIDDEN[@]}" nvidia-smi)
  nv_case fedora 615.78.08 615.78.08 610.43.02
  values_are nvidia "$(nv_msg 615.78.08 615.78.08 610.43.02)"
  rm -rf "$T/sys/usr"
  nv_tree fedora 615.78.08 - 615.78.08
  nv_doctor
  values_are nvidia '615.78.08 (kernel = 32-bit; 64-bit not found)'
}

# Debian and Mint: x86_64-linux-gnu and i386-linux-gnu, then their nvidia/current
t_nvidia_debian() {
  local FORBIDDEN=("${FORBIDDEN[@]}" nvidia-smi) d
  nv_case debian 615.78.08 615.78.08 615.78.08
  values_are nvidia '615.78.08 (kernel = 64-bit = 32-bit)'
  rm -rf "$T/sys/usr"
  for d in x86_64-linux-gnu i386-linux-gnu; do
    mkdir -p "$T/sys/usr/lib/$d/nvidia/current"
    ln -s libGLX_nvidia.so.615.78.08 "$T/sys/usr/lib/$d/nvidia/current/libGLX_nvidia.so.0"
  done
  nv_doctor
  values_are nvidia '615.78.08 (kernel = 64-bit = 32-bit)'
}

# text that is not a version is never printed: a module file `abc` is silent and a link to libGLX_nvidia.so.x counts as not found
t_nvidia_garbage() {
  local FORBIDDEN=("${FORBIDDEN[@]}" nvidia-smi)
  nv_case arch abc 615.78.08 615.78.08
  values_are nvidia
  rm -rf "$T/sys/sys" "$T/sys/usr"
  nv_tree arch 615.78.08 x 615.78.08
  nv_doctor
  values_are nvidia '615.78.08 (kernel = 32-bit; 64-bit not found)'
}

# D-09: no non-comment line of the script names a GPU tool
t_nvidia_static() {
  local hits
  hits=$(cat "$ROOT"/lib/*.sh "$ROOT/w3c-linux.sh" | grep -v '^[[:space:]]*#' | grep -nE 'nvidia-(smi|settings|modprobe)')
  [ -z "$hits" ] || ERRS+=("a GPU tool is named: $hits")
}

# D-08: launch shows the mismatch once on stderr, never on stdout
t_nvidia_launch() {
  local FORBIDDEN=(wine wineserver sudo nft iptables nvidia-smi)   # launch runs umu-run and the launch client
  l_setup
  nv_tree arch 615.78.08 610.43.02 615.78.08
  add_shim "$T" nvidia-smi
  go
  [ "$(grep -c '^warn  nvidia' <<< "$ERR")" = 1 ] || ERRS+=("stderr nvidia warn lines: want 1 got $(grep -c '^warn  nvidia' <<< "$ERR")")
  [ "$(grep -c 'nvidia' <<< "$OUT")" = 0 ] || ERRS+=("stdout names nvidia: $OUT")
  err_has "$(nv_msg 615.78.08 610.43.02 615.78.08)"
}

# D-08: a menu launch (no terminal) logs the same line in launch.log
t_nvidia_launch_menu() {
  local FORBIDDEN=(wine wineserver sudo nft iptables nvidia-smi)
  nt_setup
  nv_tree arch 615.78.08 610.43.02 615.78.08
  add_shim "$T" nvidia-smi
  go
  log_has "$(line warn nvidia "$(nv_msg 615.78.08 610.43.02 615.78.08)")"
  [ "$(log_text | grep -c '^warn  nvidia')" = 1 ] || ERRS+=("launch.log nvidia warn lines: want 1 got $(log_text | grep -c '^warn  nvidia')")
}

# D-08: steam-wrap logs the mismatch on every Play and notifies once per boot, the command runs unchanged; with the NAT fix due too, one notification carries both
t_nvidia_wrap() {
  local FORBIDDEN=("${FORBIDDEN[@]}" nvidia-smi) wl st=$T/home/.local/state/w3c-linux
  wrap_setup
  nv_tree arch 615.78.08 610.43.02 615.78.08
  add_shim "$T" nvidia-smi
  wl="steam-wrap: $(nv_msg 615.78.08 610.43.02 615.78.08)"
  wrap_run "$T" steam-wrap "$T/bin/stub"
  rc_is 0
  wrap_ran
  wlog_has "$wl"
  [ "$(notify_calls)" = 1 ] || ERRS+=("notify-send calls: want 1 got $(notify_calls)")
  grep -qF 'reboot after a driver update' "$T/marks/notify-send" 2>/dev/null || ERRS+=('the notification does not name the reboot fix')
  rm "$T/marks/stub-argv"
  wrap_run "$T" steam-wrap "$T/bin/stub"
  rc_is 0
  wrap_ran
  [ "$(wlog_count "$wl")" = 2 ] || ERRS+=("NVIDIA lines: want 2 got $(wlog_count "$wl")")
  [ "$(notify_calls)" = 1 ] || ERRS+=("second run: notify-send calls: want 1 got $(notify_calls)")
  [ "$(cat "$st/wrap-nvidia-notified" 2> /dev/null)" = "$BOOT_ID" ] || ERRS+=('wrap-nvidia-notified does not hold the boot id')
  # a fresh boot mark with the NAT rule not applied too: one notification, both fixes
  rm -f "$st/wrap-nvidia-notified" "$st/wrap-nat-notified" "$st/nat-applied" "$T/marks/notify-send" "$T/marks/stub-argv"
  wrap_run "$T" steam-wrap "$T/bin/stub"
  rc_is 0
  wrap_ran
  [ "$(notify_calls)" = 1 ] || ERRS+=("both fixes: notify-send calls: want 1 got $(notify_calls)")
  grep -qF 'w3c-linux.sh install for the NAT rule' "$T/marks/notify-send" 2>/dev/null || ERRS+=('the notification lacks the NAT fix')
  grep -qF 'NVIDIA kernel module 615.78.08' "$T/marks/notify-send" 2>/dev/null || ERRS+=('the notification lacks the NVIDIA fix')
}

# ---------- WC3-01: doctor's `wc3 current` row, the version list, and install/update staying offline ----------

# wc3_table FILE REGION:VERSION...: the version table as Blizzard serves it (header, the seqn line, one row per argument).
wc3_table() {
  local f=$1 r
  shift
  {
    printf '%s\n' 'Region!STRING:0|BuildConfig!HEX:16|CDNConfig!HEX:16|KeyRing!HEX:16|BuildId!DEC:4|VersionsName!String:0|ProductConfig!HEX:16' '## seqn = 1'
    for r in "$@"; do printf '%s|bc|cc||24371|%s|pc\n' "${r%%:*}" "${r#*:}"; done
  } > "$f"
}

# wc3_bi: the fixture's .build.info (the Faugus prefix, which mk_steam copies into the Steam prefix too)
wc3_bi() { printf '%s' "$T/home/Faugus/battlenet/drive_c/Program Files (x86)/Warcraft III/.build.info"; }

WC3_URL=https://us.version.battle.net/v2/products/w3/versions

# wc3_rows: how many `wc3 current` rows OUT holds
wc3_rows() { grep -c '^[a-z]*  wc3 current ' <<< "$OUT"; }

# wc3_norow WHY: doctor printed no `wc3 current` row
wc3_norow() { [ "$(wc3_rows)" = 0 ] || ERRS+=("$1: a wc3 current row is printed: $(grep '  wc3 current ' <<< "$OUT")"); }

WC3_FIX_FAUGUS='let Battle.net update Warcraft III before you play'

t_wc3_doctor_current() {
  wc3_table "$T/fix/wc3-versions" eu:3.0.0.24268
  run "$T" doctor
  has_line pass 'wc3 current' '3.0.0.24268 (installed 3.0.0.24268)'
  values_are 'wc3 current' '3.0.0.24268 (installed 3.0.0.24268)'
}

# outdated: one warn row with the fix, and doctor's exit status is that of the tree without the table
t_wc3_doctor_outdated() {
  local rc
  run "$T" doctor
  rc=$RC
  wc3_table "$T/fix/wc3-versions" eu:3.0.1.24371
  run "$T" doctor
  has_line warn 'wc3 current' "Warcraft III 3.0.0.24268 is outdated (current 3.0.1.24371): $WC3_FIX_FAUGUS"
  [ "$RC" = "$rc" ] || ERRS+=("doctor rc $RC differs from $rc without the table")
}

# the same under the Steam backend names the update command
t_wc3_doctor_steam() {
  mk_steam
  steam_on
  wc3_table "$T/fix/wc3-versions" eu:3.0.1.24371
  run "$T" doctor
  has_line warn 'wc3 current' 'Warcraft III 3.0.0.24268 is outdated (current 3.0.1.24371): run w3c-linux.sh update'
}

# only the Branch's own row is compared
t_wc3_region() {
  wc3_table "$T/fix/wc3-versions" eu:3.0.0.24268 us:3.0.1.24371 kr:3.0.2.24400
  run "$T" doctor
  has_line pass 'wc3 current' '3.0.0.24268 (installed 3.0.0.24268)'
}

# D-14, D-17, T-22-12, T-22-16: nothing that is not a parsed row for the Branch and two 4-part versions prints anything
t_wc3_no_row() {
  local f=$T/fix/wc3-versions
  sed -i 's/^eu|/tw|/' "$(wc3_bi)"
  wc3_table "$f" eu:3.0.1.24371 us:3.0.1.24371
  run "$T" doctor
  wc3_norow 'Branch tw has no row'
  sed -i 's/^tw|/eu|/' "$(wc3_bi)"
  rm -f "$f"
  run "$T" doctor
  wc3_norow 'no file'
  printf '%s\n' 'Region!STRING:0|BuildId!DEC:4' 'eu|24371' > "$f"
  run "$T" doctor
  wc3_norow 'no VersionsName column'
  wc3_table "$f" eu:3.0.1
  run "$T" doctor
  wc3_norow 'three-part VersionsName'
  wc3_table "$f" 'eu:3.0.1.24371;x'
  run "$T" doctor
  wc3_norow 'VersionsName with text after the version'
  : > "$f"
  run "$T" doctor
  wc3_norow 'empty file'
  wc3_table "$f" eu:3.0.1.24371
  sed -i 's/3\.0\.0\.24268/3.0.x/' "$(wc3_bi)"
  run "$T" doctor
  wc3_norow 'installed build is not 4-part'
}

# a newer installed build than the list's never warns
t_wc3_newer() {
  wc3_table "$T/fix/wc3-versions" eu:3.0.1.24371
  sed -i 's/3\.0\.0\.24268/3.0.2.1/' "$(wc3_bi)"
  run "$T" doctor
  has_line pass 'wc3 current' '3.0.1.24371 (installed 3.0.2.1)'
}

# no seam: one capped HTTPS GET of the version list, and the row from the answer
t_wc3_curl() {
  local n
  CASE_ENV+=(W3C_WC3_VERSIONS=)
  wc3_table "$T/fix/versions" eu:3.0.1.24371
  run "$T" doctor
  has_line warn 'wc3 current' "Warcraft III 3.0.0.24268 is outdated (current 3.0.1.24371): $WC3_FIX_FAUGUS"
  n=$(grep -c "$WC3_URL" "$T/marks/curl")
  [ "$n" = 1 ] || ERRS+=("curl calls for the version list: want 1 got $n")
  for n in '--proto =https' '--proto-redir =https' '--connect-timeout 3' '--max-time 5'; do
    grep -F "$WC3_URL" "$T/marks/curl" | grep -qF -- "$n" || ERRS+=("the version GET lacks $n")
  done
}

# offline (the curl shim answers 22 for a file it does not have): no row, doctor goes on
t_wc3_offline() {
  local rc
  run "$T" doctor
  rc=$RC
  CASE_ENV+=(W3C_WC3_VERSIONS=)
  run "$T" doctor
  wc3_norow 'curl failed'
  [ "$RC" = "$rc" ] || ERRS+=("doctor rc $RC differs from $rc")
}

# install, update and launch's quiet pre-check never fetch the list
t_wc3_quiet_checks() {
  CASE_ENV+=(W3C_WC3_VERSIONS=)
  wc3_table "$T/fix/versions" eu:3.0.1.24371
  FEED=$'y\nn\n'
  run "$T" install
  wc3_norow 'install'
  case $OUT$ERR in *'is outdated'*) ERRS+=('install mentions an outdated build') ;; esac
  unset FEED
  run "$T" update
  wc3_norow 'update'
  case $OUT$ERR in *'is outdated'*) ERRS+=('update mentions an outdated build') ;; esac
  ! grep -qF "$WC3_URL" "$T/marks/curl" 2> /dev/null || ERRS+=('install or update fetched the version list')
}

# ---------- WC3-01: launch's outdated line (a stop under Steam) and steam-wrap's line and notification ----------

WC3_LINE_FAUGUS="Warcraft III 3.0.0.24268 is outdated (current 3.0.1.24371): $WC3_FIX_FAUGUS"
WC3_STOP='launch: Warcraft III 3.0.0.24268 is outdated (current 3.0.1.24371): run w3c-linux.sh update; nothing was started'
WC3_WRAP_LINE='steam-wrap: Warcraft III 3.0.0.24268 is outdated (current 3.0.1.24371): run w3c-linux.sh update'

# wc3_steam_bi: the Steam prefix's .build.info (a copy of the Faugus one taken when the Steam tree was built)
wc3_steam_bi() { printf '%s' "$SR/steamapps/compatdata/3389133332/pfx/drive_c/Program Files (x86)/Warcraft III/.build.info"; }

# wc3_steam_cold: a Steam launch that starts the launcher (as t_steam_launch_cold), so a quiet case can see steam_count 1
wc3_steam_cold() {
  steam_launch_setup
  on_steam "$(reaper_line 4400)" "$(w3c_line 4500)"
  at 3 - "$(reaper_line 4400)"
  at 3 - "$(w3c_line 4500)"
}

# wc3_lines: how many lines of OUT and ERR say a Warcraft III build is outdated
wc3_lines() { grep -c 'is outdated' <<< "$OUT"$'\n'"$ERR"; }

# Faugus: the line is printed once after the launcher-update check and launch goes on
t_wc3_launch_faugus() {
  local FORBIDDEN=(wine wineserver sudo nft iptables)   # launch runs umu-run and the launch client
  l_setup
  wc3_table "$T/fix/wc3-versions" eu:3.0.1.24371
  go
  rc_is 0
  [ "$(grep -cxF "$WC3_LINE_FAUGUS" <<< "$OUT")" = 1 ] || ERRS+=("stdout lines for the outdated build: want 1 got $(grep -cxF "$WC3_LINE_FAUGUS" <<< "$OUT")")
  umu_count 1
  out_has 'W3Champions exited'
}

# a current table or no file: launch says nothing about Warcraft III
t_wc3_launch_current() {
  local FORBIDDEN=(wine wineserver sudo nft iptables)   # launch runs umu-run and the launch client
  l_setup
  wc3_table "$T/fix/wc3-versions" eu:3.0.0.24268
  go
  rc_is 0
  [ "$(wc3_lines)" = 0 ] || ERRS+=('an outdated line is printed for a current table')
  rm -f "$T/fix/wc3-versions"
  go
  [ "$(wc3_lines)" = 0 ] || ERRS+=('an outdated line is printed without a table')
}

# WC3-01 amended: under Steam an outdated build stops launch before Steam is asked
t_wc3_launch_steam_stop() {
  wc3_steam_cold
  wc3_table "$T/fix/wc3-versions" eu:3.0.1.24371
  run "$T" launch
  rc_is 1
  out_has "$WC3_STOP"
  steam_count 0
}

# T-22-16: nothing that is not a parsed older build stops the Steam launch
t_wc3_launch_quiet() {
  wc3_steam_cold
  run "$T" launch
  rc_is 0
  [ "$(wc3_lines)" = 0 ] || ERRS+=('no file: an outdated line is printed')
  steam_count 1
}

t_wc3_launch_quiet_norow() {
  wc3_steam_cold
  sed -i 's/^eu|/tw|/' "$(wc3_steam_bi)"
  wc3_table "$T/fix/wc3-versions" eu:3.0.1.24371 us:3.0.1.24371
  run "$T" launch
  rc_is 0
  [ "$(wc3_lines)" = 0 ] || ERRS+=('no row for the Branch: an outdated line is printed')
  steam_count 1
}

t_wc3_launch_quiet_bad() {
  wc3_steam_cold
  wc3_table "$T/fix/wc3-versions" eu:3.0.1
  run "$T" launch
  rc_is 0
  [ "$(wc3_lines)" = 0 ] || ERRS+=('three-part VersionsName: an outdated line is printed')
  steam_count 1
}

# D-11, D-17: steam-wrap logs the line and notifies on every Play, and the command runs unchanged
t_wc3_wrap_outdated() {
  wrap_setup
  wc3_table "$T/fix/wc3-versions" eu:3.0.1.24371
  wrap_run "$T" steam-wrap "$T/bin/stub" a 'b c'
  rc_is 0
  wrap_ran
  printf 'a\nb c\n' | cmp -s - "$T/marks/stub-argv" || ERRS+=('stub argv changed')
  rm "$T/marks/stub-argv"
  wrap_run "$T" steam-wrap "$T/bin/stub" a 'b c'
  rc_is 0
  wrap_ran
  printf 'a\nb c\n' | cmp -s - "$T/marks/stub-argv" || ERRS+=('second run: stub argv changed')
  [ "$(wlog_count "$WC3_WRAP_LINE")" = 2 ] || ERRS+=("launch.log lines: want 2 got $(wlog_count "$WC3_WRAP_LINE")")
  [ "$(grep -cF 'Warcraft III 3.0.0.24268 is outdated' "$T/marks/notify-send")" = 2 ] || ERRS+=('the notification does not name the outdated build twice')
}

# D-17: no seam, one GET capped at 1 s connect and 2 s total
t_wc3_wrap_curl() {
  local n
  wrap_setup
  CASE_ENV+=(W3C_WC3_VERSIONS=)
  wc3_table "$T/fix/versions" eu:3.0.1.24371
  wrap_run "$T" steam-wrap "$T/bin/stub"
  rc_is 0
  wrap_ran
  wlog_has "$WC3_WRAP_LINE"
  n=$(grep -c "$WC3_URL" "$T/marks/curl")
  [ "$n" = 1 ] || ERRS+=("curl calls for the version list: want 1 got $n")
  for n in '--proto =https' '--proto-redir =https' '--connect-timeout 1' '--max-time 2'; do
    grep -F "$WC3_URL" "$T/marks/curl" | grep -qF -- "$n" || ERRS+=("the version GET lacks $n")
  done
}

# offline or unparsable: nothing about Warcraft III in the log, no notification for it, the stub ran
t_wc3_wrap_offline() {
  wrap_setup
  CASE_ENV+=(W3C_WC3_VERSIONS=)
  wrap_run "$T" steam-wrap "$T/bin/stub"
  rc_is 0
  wrap_ran
  ! grep -q 'Warcraft III' "$T/home/.cache/w3c-linux/launch.log" 2> /dev/null || ERRS+=('launch.log mentions Warcraft III offline')
  ! grep -q 'Warcraft III' "$T/marks/notify-send" 2> /dev/null || ERRS+=('a notification mentions Warcraft III offline')
}

# ---------- WC3-03 (D-15, spike D PASS): steam-wrap starts Battle.net instead of W3Champions while Warcraft III is behind ----------

WC3_SWAP_NOTE='Warcraft III needs an update: update in Battle.net, quit, press Play again'
WC3_SWAP_LINE='steam-wrap: Warcraft III 3.0.0.24268 is outdated (current 3.0.1.24371): starting Battle.net instead of W3Champions so it can update'
WC3_STOP_PLAY='launch: Warcraft III 3.0.0.24268 is outdated (current 3.0.1.24371): press Play in Steam to update it in Battle.net, quit Battle.net, then rerun w3c-linux.sh launch (or run w3c-linux.sh update); nothing was started'

# wc3_pfx, wc3_bnet, wc3_w3c: the Steam prefix, the Battle.net.exe the swap targets and the launcher exe Steam's %command% ends in
wc3_pfx() { printf '%s' "$SR/steamapps/compatdata/3389133332/pfx"; }
wc3_bnet() { printf '%s' "$(wc3_pfx)/drive_c/Program Files (x86)/Battle.net/Battle.net.exe"; }
wc3_w3c() { printf '%s' "$(wc3_pfx)/drive_c/Program Files/W3Champions/W3Champions.exe"; }

# wc3_swap_setup [TABLE]: a wrap fixture with Battle.net.exe in the prefix and a version list (eu:3.0.1.24371 unless TABLE), so 3.0.0.24268 is outdated
wc3_swap_setup() {
  wrap_setup
  mkdir -p "$(dirname "$(wc3_bnet)")"
  : > "$(wc3_bnet)"
  wc3_table "$T/fix/wc3-versions" "${1:-eu:3.0.1.24371}"
}

# argv_is ARGS...: the stub's recorded argv is exactly ARGS, one per line (cmp, so an empty or spaced argument counts)
argv_is() { printf '%s\n' "$@" | cmp -s - "$T/marks/stub-argv" || ERRS+=("stub argv: $(od -c < "$T/marks/stub-argv" | head -n 4 | tr '\n' '|')"); }

# outdated, W3Champions.exe last, Battle.net.exe present: only the last argument changes, no monitor, one swap line, one notification
t_wrap_swap() {
  wc3_swap_setup
  wrap_run "$T" steam-wrap "$T/bin/stub" a 'b c' '' "$(wc3_w3c)"
  rc_is 0
  wrap_ran
  argv_is a 'b c' '' "$(wc3_bnet)"
  wlog_has "$WC3_SWAP_LINE"
  ! grep -q 'Match monitor:' "$T/home/.cache/w3c-linux/launch.log" || ERRS+=('a match monitor started for the swap')
  [ "$(notify_calls)" = 1 ] || ERRS+=("notify-send calls: want 1 got $(notify_calls)")
  [ "$(grep -cF "$WC3_SWAP_NOTE" "$T/marks/notify-send")" = 1 ] || ERRS+=('the notification lacks the update text')
  [ "$OUT" = STUB-OUT ] || ERRS+=("stdout is not the stub's: [$OUT]")
}

# next_boot: the fixture's boot id changes, as after a reboot
next_boot() { printf '%s\n' "$BOOT_ID-next" > "$T/proc/sys/kernel/random/boot_id"; }

# WR-02: a second outdated Play in the same boot does not swap (the marker holds the boot id) and says to run update; a Play in a new boot swaps again
t_wrap_swap_once() {
  local st=$T/home/.local/state/w3c-linux
  wc3_swap_setup
  wrap_run "$T" steam-wrap "$T/bin/stub" "$(wc3_w3c)"
  rc_is 0
  argv_is "$(wc3_bnet)"
  [ "$(cat "$st/wrap-swap-done" 2> /dev/null)" = "$BOOT_ID" ] || ERRS+=('wrap-swap-done does not hold the boot id')
  rm "$T/marks/stub-argv" "$T/marks/notify-send"
  wrap_run "$T" steam-wrap "$T/bin/stub" "$(wc3_w3c)"
  rc_is 0
  wrap_ran
  argv_is "$(wc3_w3c)"
  wlog_has "$WC3_WRAP_LINE"
  [ "$(grep -cF 'run w3c-linux.sh update' "$T/marks/notify-send")" = 1 ] || ERRS+=('the second Play does not notify to run update')
  ! grep -qF "$WC3_SWAP_NOTE" "$T/marks/notify-send" || ERRS+=('the swap text is notified without a swap')
}

t_wrap_swap_new_boot() {
  wc3_swap_setup
  wrap_run "$T" steam-wrap "$T/bin/stub" "$(wc3_w3c)"
  rc_is 0
  argv_is "$(wc3_bnet)"
  rm "$T/marks/stub-argv"
  next_boot
  wrap_run "$T" steam-wrap "$T/bin/stub" "$(wc3_w3c)"
  rc_is 0
  wrap_ran
  argv_is "$(wc3_bnet)"
  [ "$(wlog_count "$WC3_SWAP_LINE")" = 2 ] || ERRS+=("swap lines: want 2 got $(wlog_count "$WC3_SWAP_LINE")")
}

# the basename test ignores case and takes a backslash path too
t_wrap_swap_case() {
  wc3_swap_setup
  wrap_run "$T" steam-wrap "$T/bin/stub" '/X/w3champions.EXE'
  rc_is 0
  wrap_ran
  argv_is "$(wc3_bnet)"
  rm "$T/marks/stub-argv"
  next_boot   # one swap per boot (WR-02): the second spelling needs a boot of its own
  wrap_run "$T" steam-wrap "$T/bin/stub" 'C:\x\W3CHAMPIONS.exe'
  rc_is 0
  wrap_ran
  argv_is "$(wc3_bnet)"
}

# Steam passed fd 8 (seen on the rig): a swap starts no monitor anyway, so the notification holds only the update text
t_wrap_swap_fd8() {
  wc3_swap_setup
  snap "$T" > "$TMPROOT/snap.before"
  run_cmd "$T" steam-wrap "$T/bin/stub" "$(wc3_w3c)" 8> "$TMPROOT/fd8" < /dev/null > "$TMPROOT/out" 2> "$TMPROOT/err"
  RC=$?
  lock_free
  post_run "$T"
  rc_is 0
  argv_is "$(wc3_bnet)"
  [ "$(notify_calls)" = 1 ] || ERRS+=("notify-send calls: want 1 got $(notify_calls)")
  [ "$(grep -cF "$WC3_SWAP_NOTE" "$T/marks/notify-send")" = 1 ] || ERRS+=('the notification lacks the update text')
  ! grep -q 'match monitor is off' "$T/marks/notify-send" || ERRS+=('the swap notification mentions the match monitor')
}

# a current build: the argv is untouched and the monitor starts as before
t_wrap_noswap_current() {
  wc3_swap_setup eu:3.0.0.24268
  wrap_run "$T" steam-wrap "$T/bin/stub" a 'b c' "$(wc3_w3c)"
  rc_is 0
  wrap_ran
  argv_is a 'b c' "$(wc3_w3c)"
  wlog_has "Match monitor: lost results and join bugs are tallied in $T/home/.local/state/w3c-linux/matches.log"
}

# T-22-25: no answer, no swap
t_wrap_noswap_offline() {
  wc3_swap_setup
  CASE_ENV+=(W3C_WC3_VERSIONS=)
  wrap_run "$T" steam-wrap "$T/bin/stub" "$(wc3_w3c)"
  rc_is 0
  wrap_ran
  argv_is "$(wc3_w3c)"
}

# T-22-24: a last argument that is not W3Champions.exe is never replaced, however outdated; the plain outdated line stays
t_wrap_noswap_other() {
  wc3_swap_setup
  wrap_run "$T" steam-wrap "$T/bin/stub" "$(wc3_w3c)" '/x/Other.exe'
  rc_is 0
  wrap_ran
  argv_is "$(wc3_w3c)" '/x/Other.exe'
  wlog_has "$WC3_WRAP_LINE"
  ! grep -qF "$WC3_SWAP_NOTE" "$T/marks/notify-send" || ERRS+=('the swap text is notified without a swap')
}

# no Battle.net.exe in the prefix: the command runs unchanged and only plan 22-05's line and notification appear
t_wrap_noswap_no_bnet() {
  wc3_swap_setup
  rm "$(wc3_bnet)"
  wrap_run "$T" steam-wrap "$T/bin/stub" "$(wc3_w3c)"
  rc_is 0
  wrap_ran
  argv_is "$(wc3_w3c)"
  wlog_has "$WC3_WRAP_LINE"
  [ "$(grep -cF 'Warcraft III 3.0.0.24268 is outdated' "$T/marks/notify-send")" = 1 ] || ERRS+=('the plain outdated notification is missing')
  ! grep -qF "$WC3_SWAP_NOTE" "$T/marks/notify-send" || ERRS+=('the swap text is notified without a swap')
}

# WC3-01 amended: with an executable steam-wrap in the Launch Options the stop names the Play route; without it, update
t_launch_steam_stop_play() {
  wc3_steam_cold
  wc3_table "$T/fix/wc3-versions" eu:3.0.1.24371
  set_opts "$(default_opts "$ROOT/w3c-linux.sh")"
  run "$T" launch
  rc_is 1
  out_has "$WC3_STOP_PLAY"
  steam_count 0
  set_opts ''
  run "$T" launch
  rc_is 1
  out_has "$WC3_STOP"
  steam_count 0
}

# WR-02: with this boot's swap spent a Play starts W3Champions, so launch prints the information-only line and goes on; it never writes the marker
# (the harness fails a case whose tree changed)
t_launch_steam_swap_spent() {
  local mark=$T/home/.local/state/w3c-linux/wrap-swap-done
  wc3_steam_cold
  wc3_table "$T/fix/wc3-versions" eu:3.0.1.24371
  set_opts "$(default_opts "$ROOT/w3c-linux.sh")"
  mkdir -p "${mark%/*}"
  printf '%s\n' "$BOOT_ID" > "$mark"
  run "$T" launch
  rc_is 0
  out_has 'Warcraft III 3.0.0.24268 is outdated (current 3.0.1.24371): run w3c-linux.sh update'
  steam_count 1
  [ "$(cat "$mark")" = "$BOOT_ID" ] || ERRS+=('launch changed the swap marker')
}

# the README documents the check and the guided update, and holds the swap's notification exactly when the code does (compared with lib/ only: tests/ ships
# in the public snapshot, which has no planning directory)
# shellcheck disable=SC2016 # the backticks are literal README markdown
t_wc3_docs_readme() {
  local f=$ROOT/README.md note='Warcraft III needs an update: update in Battle.net, quit, press Play again'
  grep -qF '`wc3 current`' "$f" || ERRS+=('README lacks the wc3 current row')
  grep -qF '**Warcraft III updates.**' "$f" || ERRS+=('README lacks the Warcraft III updates paragraph')
  if grep -qF "$note" "$ROOT/lib/steam_launch.sh"; then
    grep -qF "$note" "$f" || ERRS+=('lib/steam_launch.sh swaps but the README lacks the notification text')
  else
    ! grep -qF "$note" "$f" || ERRS+=('the README documents a swap lib/steam_launch.sh does not hold')
  fi
}

# ---------- WC3-02: update's guided Warcraft III patch under Steam (D-14 B) ----------

WC3_ASK='Walk through the Warcraft III update in Battle.net now? You point the shortcut at Battle.net.exe, press Play, then point it back. [Y/n]'
WC3_BN_OPTS='WINE_SIMULATE_WRITECOPY=1 PROTON_ENABLE_WAYLAND=0 %command%'

# wc3_walk_setup: Steam update with Proton and the launcher current, an outdated Warcraft III (3.0.0.24268, current 3.0.1.24371) and the shortcut
# on its fixture target; the cases that let the test edit Steam or prefix files during the run allow those paths.
wc3_walk_setup() {
  supd_setup 1.6.16
  wc3_table "$T/fix/wc3-versions" eu:3.0.1.24371
  ALLOW_EXTRA+=(home/.local/share/Steam/userdata/12345678/config/shortcuts.vdf "$SP_REL/drive_c/Program Files (x86)/Warcraft III/.build.info")
}

# wc3_exe EXE: the shortcut's Target becomes /x/EXE, as the user's Properties edit would make it.
wc3_exe() { sc_edit "$SR/userdata/12345678/config/shortcuts.vdf" set 3389133332 Exe "\"/x/$1\""; }

# wc3_build VERSION: the Steam prefix's installed Warcraft III build becomes VERSION, as Battle.net's patch would make it.
wc3_build() { sed -i "s/3\\.0\\.0\\.24268/$1/" "$(wc3_steam_bi)"; }

# the whole walk, one Enter per step: each page names its step and carries the click path of Phase 19; the build is refreshed on the Enter
t_wc3_update_walk() {
  local pfx
  wc3_walk_setup
  pfx=$SR/steamapps/compatdata/3389133332/pfx
  run_fifo "$T" update
  send $'y\n'
  wait_err 'press Enter to check again'
  wc3_exe Battle.net.exe
  send $'\n'
  wait_out 'Step 2: Press Play'   # the prompts share one stderr line, so the pages on stdout mark the waits
  wc3_build 3.0.1.24371
  send $'\n'
  wait_out 'Step 3: Point the shortcut back'
  wc3_exe W3Champions.exe
  send $'\n'
  finish
  rc_is 0
  out_line 'Warcraft III 3.0.0.24268 is outdated (current 3.0.1.24371)'
  err_has "$WC3_ASK"
  out_line 'Step 1: Point the shortcut at Battle.net.exe'
  ck_retarget "$pfx/drive_c/Program Files (x86)/Battle.net" Battle.net.exe "$WC3_BN_OPTS"
  out_line 'Step 2: Press Play: Battle.net updates Warcraft III to 3.0.1.24371, then quit Battle.net'
  out_has 'installed 3.0.0.24268, current 3.0.1.24371'
  out_line 'Step 3: Point the shortcut back at W3Champions.exe'
  ck_retarget "$pfx/drive_c/Program Files/W3Champions" W3Champions.exe "$(default_opts)"
  out_line '  [x] 1. Point the shortcut at Battle.net.exe'
  out_line '  [x] 2. Press Play: Battle.net updates Warcraft III to 3.0.1.24371, then quit Battle.net'
  out_line 'Warcraft III 3.0.1.24371 is current; checking with doctor (warn and fail rows only):'
  out_line 'Update finished.'
  proton_count 0
}

# the table, not the prefix, moves: step 2 is done once the list no longer names a newer build, so a seam-driven proof can finish the walk
t_wc3_update_refresh() {
  wc3_walk_setup
  ALLOW_EXTRA+=(fix/wc3-versions)   # the test rewrites the list during the run
  wc3_exe Battle.net.exe
  run_fifo "$T" update
  send $'y\n'
  wait_err 'press Enter to check again'
  wc3_table "$T/fix/wc3-versions" eu:3.0.0.24268
  wc3_exe W3Champions.exe
  send $'\n'
  finish
  rc_is 0
  out_line 'Step 2: Press Play: Battle.net updates Warcraft III to 3.0.1.24371, then quit Battle.net'
  lacks_text 'Step 3:'
  out_line 'Warcraft III 3.0.0.24268 is current; checking with doctor (warn and fail rows only):'
  out_line 'Update finished.'
}

# no_wait: stderr holds no wait prompt.
no_wait() { case $ERR in *'press Enter'*) ERRS+=("a wait was shown: $ERR") ;; esac; }

# the user declines the walk and nothing else is offered: the line, nothing changed, no wait
t_wc3_update_declined() {
  wc3_walk_setup
  FEED=$'n\n'
  run "$T" update
  rc_is 0
  out_line 'Warcraft III 3.0.0.24268 is outdated (current 3.0.1.24371)'
  err_has "$WC3_ASK"
  out_line 'Nothing was changed.'
  no_wait
  changed_is
}

# q at the first wait stops with the rerun line and records nothing
t_wc3_update_quit() {
  wc3_walk_setup
  run_fifo "$T" update
  send $'y\n'
  wait_err 'press Enter to check again'
  send $'q\n'
  finish
  rc_is 1
  out_line 'Stopped; rerun w3c-linux.sh update to continue.'
  out_line 'Step 1: Point the shortcut at Battle.net.exe'
  lacks_text 'Update finished.'
}

# no list to read: nothing about Warcraft III, no question, no wait
t_wc3_update_offline() {
  supd_setup 1.6.16
  run "$T" update
  rc_is 0
  case $OUT$ERR in *'Warcraft III'*) ERRS+=('Warcraft III is named without a list') ;; esac
  no_question
  changed_is
}

# the list names the build the prefix has
t_wc3_update_current() {
  supd_setup 1.6.16
  wc3_table "$T/fix/wc3-versions" eu:3.0.0.24268
  run "$T" update
  rc_is 0
  out_line 'Warcraft III 3.0.0.24268 up to date'
  no_question
  changed_is
}

# the shortcut is removed from Steam during a wait: a stop, not a step
t_wc3_update_gone() {
  wc3_walk_setup
  run_fifo "$T" update
  send $'y\n'
  wait_err 'press Enter to check again'
  rm "$SR/userdata/12345678/config/shortcuts.vdf"
  send $'\n'
  finish
  rc_is 1
  out_line 'update: the Battle.net shortcut is gone from Steam; stopping'
  lacks_text 'Update finished.'
}

# a launcher update offered too: the MSI runs on the new tool before the walk's first page
t_wc3_update_after_msi() {
  supd_setup 1.6.15
  wc3_table "$T/fix/wc3-versions" eu:3.0.1.24371
  run_fifo "$T" update
  send $'y\ny\n'
  wait_out 'Step 1: Point the shortcut at Battle.net.exe'
  proton_count 1
  [ "$(launcher_rec)" = 1.6.16 ] || ERRS+=("launcher record at the first page is $(launcher_rec)")
  send $'q\n'
  finish
  rc_is 1
  err_has 'Update W3Champions 1.6.15 -> 1.6.16? [Y/n]'
  err_has "$WC3_ASK"
  proton_count 1
}

# a whole walk writes no Steam file: the test's own Target edits end on the Target it started with, and then every file hashes as before
t_wc3_update_nowrite() {
  local before
  wc3_walk_setup
  wc3_exe W3Champions.exe   # a target the finder accepts; the walk's edits end back on it
  before=$(steam_hashes)
  run_fifo "$T" update
  send $'y\n'
  wait_err 'press Enter to check again'
  wc3_exe Battle.net.exe
  send $'\n'
  wait_out 'Step 2: Press Play'
  wc3_build 3.0.1.24371
  send $'\n'
  wait_out 'Step 3: Point the shortcut back'
  wc3_exe W3Champions.exe
  send $'\n'
  finish
  rc_is 0
  out_line 'Update finished.'
  [ "$before" = "$(steam_hashes)" ] || ERRS+=('a Steam file changed')
}

# ---------- Phase 23 D-12: walk styling ----------

# styled on a terminal (the fixtures' W3C_ASSUME_TTY_OUT=1 stands in for one): bold title, cyan values, green [x], italic prompt; text rows stay plain
t_walk_style_tty() {
  local pfx esc=$'\033' d
  CASE_ENV+=(W3C_ASSUME_TTY_OUT=1)
  wc3_walk_setup
  pfx=$SR/steamapps/compatdata/3389133332/pfx
  d="$pfx/drive_c/Program Files (x86)/Battle.net"
  run_fifo "$T" update
  send $'y\n'
  wait_err 'press Enter to check again'
  wc3_exe Battle.net.exe
  send $'\n'
  wait_out 'Step 2: Press Play'
  send $'q\n'
  finish
  rc_is 1
  out_line 'Warcraft III 3.0.0.24268 is outdated (current 3.0.1.24371)'
  out_line "${esc}[1mStep 1: Point the shortcut at Battle.net.exe${esc}[0m"
  out_line "    Target: ${esc}[36m\"$d/Battle.net.exe\"${esc}[0m"
  out_line "    Start In: ${esc}[36m\"$d/\"${esc}[0m"
  out_line "    Launch Options: ${esc}[36m${WC3_BN_OPTS}${esc}[0m"
  out_line "  ${esc}[32m[x]${esc}[0m 1. Point the shortcut at Battle.net.exe"
  out_line '  [ ] 2. Press Play: Battle.net updates Warcraft III to 3.0.1.24371, then quit Battle.net'
  err_has "${esc}[3mpress Enter to check again (q to quit): ${esc}[0m"
}

# piped, and NO_COLOR with the seam: no escape byte on either stream, the same text, the plain prompt
t_walk_style_plain() {
  local pfx esc=$'\033' d first
  wc3_walk_setup
  pfx=$SR/steamapps/compatdata/3389133332/pfx
  d="$pfx/drive_c/Program Files (x86)/Battle.net"
  FEED=$'y\nq\n'
  run "$T" update
  rc_is 1
  case $OUT$ERR in *"$esc"*) ERRS+=('piped run has an escape byte') ;; esac
  out_line 'Step 1: Point the shortcut at Battle.net.exe'
  ck_retarget "$d" Battle.net.exe "$WC3_BN_OPTS"
  err_has 'press Enter to check again (q to quit): '
  first=$OUT
  CASE_ENV+=(W3C_ASSUME_TTY_OUT=1 NO_COLOR=1)
  run "$T" update
  rc_is 1
  case $OUT$ERR in *"$esc"*) ERRS+=('NO_COLOR run has an escape byte') ;; esac
  out_line 'Step 1: Point the shortcut at Battle.net.exe'
  ck_retarget "$d" Battle.net.exe "$WC3_BN_OPTS"
  err_has 'press Enter to check again (q to quit): '
  [ "$OUT" = "$first" ] || ERRS+=('NO_COLOR stdout differs from the piped stdout')
}

# a zenity dialog never carries an escape byte, even when stdout is styled
t_walk_style_zenity() {
  local esc=$'\033' z
  nt_env
  CASE_ENV+=(W3C_ASSUME_TTY_OUT=1)
  wc3_walk_setup
  printf '0\n1\n' > "$T/fix/zenity.q"   # the walk question's Yes, then steam_wait's No
  run "$T" update
  rc_is 1
  z=$(< "$T/marks/zenity")
  case $z in *'Step 1: Point the shortcut at Battle.net.exe'*) ;; *) ERRS+=('the dialog lacks the Step 1 title') ;; esac
  case $z in *"$esc"*) ERRS+=('a zenity dialog has an escape byte') ;; esac
  out_line "${esc}[1mStep 1: Point the shortcut at Battle.net.exe${esc}[0m"
}

# a refresh that shows the same page again says what was re-read and what step 2 waits for; the advance to step 3 says nothing
t_walk_style_still() {
  local esc=$'\033' want='Checked Warcraft III again: still 3.0.0.24268, waiting for Battle.net to finish the update to 3.0.1.24371.'
  wc3_walk_setup
  wc3_exe Battle.net.exe   # the walk starts on step 2
  run_fifo "$T" update
  send $'y\n'
  wait_out 'Step 2: Press Play'
  send $'\n'
  wait_out 'Checked Warcraft III again'
  wc3_build 3.0.1.24371
  send $'\n'
  wait_out 'Step 3: Point the shortcut back'
  send $'q\n'
  finish
  rc_is 1
  [ "$(grep -cxF -- "$want" <<< "$OUT")" = 1 ] || ERRS+=("the still-waiting line is not printed exactly once: $want")
  [ "$(grep -c '^Step 2:' <<< "$OUT")" = 2 ] || ERRS+=('Step 2 was not printed exactly twice')
  case $OUT$ERR in *"$esc"*) ERRS+=('the plain run has an escape byte') ;; esac
}

# the same line on install's checklist wait (steam_walk)
t_walk_style_still_install() {
  local want="Checked Steam's files again: step 2 (${LBL[2]}) is not done yet."
  sprep
  mk_mapping 1000000:proton_9
  run_fifo "$T" install
  wait_err 'press Enter to check again'
  send $'\n'
  wait_out "Checked Steam's files again"
  send $'q\n'
  finish
  rc_is 1
  [ "$(grep -cxF -- "$want" <<< "$OUT")" = 1 ] || ERRS+=("the still-waiting line is not printed exactly once: $want")
}

# ask() with stdin closed: a failed read leaves ans unassigned; the message prints, the exit is 1, and set -u does not trip (CR-01)
t_ask_stdin_closed() {
  local o rc
  # shellcheck disable=SC2016 # the script text is single-quoted on purpose; the inner shell expands $1
  o=$(env -u DISPLAY -u WAYLAND_DISPLAY SELF=x bash -c 'set -u; source "$1/lib/common.sh"; ask Q? Y' _ "$ROOT" 2>&1 <&-)
  rc=$?
  [ "$rc" = 1 ] || ERRS+=("ask exit: want 1 got $rc")
  case $o in *'no answer (stdin closed); run in a terminal'*) ;; *) ERRS+=("ask output lacks the stdin-closed message: $o") ;; esac
  case $o in *'unbound variable'*) ERRS+=("ask tripped set -u: $o") ;; esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
