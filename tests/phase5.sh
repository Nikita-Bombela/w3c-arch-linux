#!/usr/bin/env bash
# Phase 5 fixture check: runs the real w3c-linux.sh install under env -i against a fake HOME per case, on the harness of tests/phase2.sh to
# tests/phase4.sh. sudo, nft and iptables are marker shims: the sudo shim records its argv and never runs it. mk_tree seeds the fake boot_id
# and the matching nat-applied marker, so a case that exercises install prompt 8 removes the marker first (nat_setup). No case runs a real
# sudo, Wine, umu or network call; the nat-real-* cases run the host's nft or iptables inside a throwaway user and net namespace.
# Usage: bash tests/phase5.sh [GLOB]   (GLOB filters on display names such as nat-prompt-apply)
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=phase4.sh
source "$(dirname "${BASH_SOURCE[0]}")/phase4.sh"

# this suite has its own cases only
mapfile -t P4_CASES < <(compgen -A function t_)
unset -f "${P4_CASES[@]}"

# a case that answers y to the NAT question declares its own FORBIDDEN without sudo
FORBIDDEN=(wine wineserver sudo nft iptables notify-send)

# ---------- helpers ----------

# sudo_shim: replaces the marker shim; every call is recorded (a '== call ==' line, then one argument per line) and never executed.
# Its exit status is the number in $FIX/sudo-rc when that file exists.
sudo_shim() {
  cat > "$T/bin/sudo" <<'SH'
#!/bin/sh
{ echo '== call =='; for a in "$@"; do printf '%s\n' "$a"; done; } >> "$MARK/sudo"
rc=0
[ -f "$FIX/sudo-rc" ] && read -r rc < "$FIX/sudo-rc"
exit "$rc"
SH
  chmod +x "$T/bin/sudo"
}

# nat_setup: a complete install, the nat-applied marker gone (prompt 8 asks), the recording sudo shim in place.
nat_setup() {
  install_setup
  rm -f "$T/home/.local/state/w3c-linux/nat-applied"
  sudo_shim
}

# printed_script: the text between the single quotes of the first stdout line that starts with four spaces and `sudo sh -c '`.
printed_script() {
  local l
  while IFS= read -r l; do
    case $l in
      "    sudo sh -c '"*"'")
        l=${l#"    sudo sh -c '"}
        printf '%s' "${l%\'}"
        return 0 ;;
    esac
  done <<< "$OUT"
  return 1
}

# sudo_call N: the argument lines of the N-th recorded sudo call.
sudo_call() { awk -v n="$1" '/^== call ==$/ { c++; next } c == n' "$T/marks/sudo" 2> /dev/null; }

# sudo_calls: how many times sudo ran.
sudo_calls() {
  local n
  n=$(grep -c '^== call ==$' "$T/marks/sudo" 2> /dev/null)
  printf '%s' "${n:-0}"
}

# err_before A B: both texts are on stderr and A comes first.
err_before() {
  local a=${ERR%%"$1"*} b=${ERR%%"$2"*}
  case $ERR in *"$1"*) ;; *) ERRS+=("stderr lacks: $1"); return ;; esac
  case $ERR in *"$2"*) ;; *) ERRS+=("stderr lacks: $2"); return ;; esac
  [ "${#a}" -lt "${#b}" ] || ERRS+=("stderr order: $1 must come before $2")
}

# out_before A B: both texts are on stdout and A comes first.
out_before() {
  local a=${OUT%%"$1"*} b=${OUT%%"$2"*}
  case $OUT in *"$1"*) ;; *) ERRS+=("output lacks: $1"); return ;; esac
  case $OUT in *"$2"*) ;; *) ERRS+=("output lacks: $2"); return ;; esac
  [ "${#a}" -lt "${#b}" ] || ERRS+=("output order: $1 must come before $2")
}

# ---------- cases ----------

# The tracer: a complete install without the marker prints the block, asks, runs the printed text through one sudo on y and records the boot.
t_nat_prompt_apply() {
  local FORBIDDEN=(wine wineserver nft iptables notify-send) want got
  nat_setup
  FEED=$'y\ny\nn\n'
  run "$T" install
  rc_is 0
  err_has 'Apply the LAN-test NAT rule now with sudo? [y/N]'
  err_before 'Continue?' 'Apply the LAN-test NAT rule now with sudo?'
  err_before 'Apply the LAN-test NAT rule now with sudo?' 'Launch now?'
  out_before 'Install complete' "    sudo sh -c '"
  want=$(printed_script) || ERRS+=('no printed sudo sh -c line')
  [ "$(sudo_calls)" = 1 ] || ERRS+=("sudo calls: want 1 got $(sudo_calls)")
  got=$(sudo_call 1)
  [ "$got" = $'sh\n-c\n'"$want" ] || ERRS+=("sudo argv differs from the printed line: $got")
  want=$(< "$T/proc/sys/kernel/random/boot_id")
  got=$(cat "$T/home/.local/state/w3c-linux/nat-applied" 2> /dev/null)
  [ -n "$want" ] && [ "$got" = "$want" ] || ERRS+=("nat-applied marker: want $want got $got")
  [ ! -e "$T/marks/nft" ] && [ ! -e "$T/marks/iptables" ] || ERRS+=('nft or iptables ran')
  out_has 'NAT rule applied'
}

# ---------- the NAT block contract (Task 2) ----------

# the nft script and the iptables rule, written here independently of the script
NFT_SCRIPT='printf "%s\n" "add table ip w3c" "delete table ip w3c" "add table ip w3c" "add chain ip w3c output { type nat hook output priority -100; policy accept; }" "add rule ip w3c output ip daddr 255.255.255.255 udp dport 16000 dnat to 127.0.0.1:16000" | nft -f -'
IPT_RULE='-d 255.255.255.255 -p udp --dport 16000 -j DNAT --to-destination 127.0.0.1:16000'

# nat_decline: one install answered y (prompt 1), n (NAT), Enter (the wait), n (prompt 10); the marker is removed first so prompt 8 asks.
nat_decline() {
  rm -f "$T/home/.local/state/w3c-linux/nat-applied"
  FEED=$'y\nn\n\nn\n'
  run "$T" install
}

# nat_none: neither nft nor iptables on PATH.
nat_none() { rm -f "$T/bin/nft" "$T/bin/iptables"; }

# block_text: the NAT block of OUT, from the rule line through the side-effect line.
block_text() { printf '%s\n' "$OUT" | awk '/^LAN-test NAT rule \(plan.md/,/^While the rule is active/'; }

t_nat_variant_nft() {
  nat_setup
  nat_decline
  rc_is 0
  [ "$(printed_script)" = "$NFT_SCRIPT" ] || ERRS+=("printed nft script differs: $(printed_script)")
  out_has '    sudo nft delete table ip w3c'
  lacks_text 'iptables -t nat'
  [ ! -e "$T/marks/sudo" ] || ERRS+=('sudo ran')
}

t_nat_variant_iptables() {
  nat_setup
  rm -f "$T/bin/nft"
  nat_decline
  rc_is 0
  [ "$(printed_script)" = "iptables -t nat -C OUTPUT $IPT_RULE 2>/dev/null || iptables -t nat -A OUTPUT $IPT_RULE" ] \
    || ERRS+=("printed iptables script differs: $(printed_script)")
  out_has "    sudo iptables -t nat -D OUTPUT $IPT_RULE"
  lacks_text 'nft -f -'
}

t_nat_variant_none() {
  nat_setup
  nat_none
  FEED=$'y\nn\n'
  rm -f "$T/home/.local/state/w3c-linux/nat-applied"
  run "$T" install
  rc_is 0
  out_has 'needs nft or iptables'
  out_has 'add chain ip w3c output { type nat hook output priority -100; policy accept; }'
  out_has '    sudo nft delete table ip w3c'
  lacks_text 'printed only'
  case $ERR in *'Apply the LAN-test NAT rule now with sudo?'*) ERRS+=('asked the NAT question without a tool') ;; esac
  case $ERR in *'Run it in another terminal'*) ERRS+=('waited for the NAT step without a tool') ;; esac
  err_has 'Launch now?'
  [ ! -e "$T/marks/sudo" ] || ERRS+=('sudo ran')
}

# the printed rule text equals plan.md section 5 step 9 (the chain, the rule, the DNAT target and the removals)
t_nat_text_planmd() {
  local step chain rule del ipt_a ipt_d
  step=$(sed -n '/^### Step 9/,/^### Step 10/p' "$ROOT/plan.md")
  chain=$(printf '%s\n' "$step" | sed -n "s/^nft '\\(add chain .*\\)'\$/\\1/p")
  rule=$(printf '%s\n' "$step" | sed -n 's/^nft \(add rule .*\)$/\1/p')
  del=$(printf '%s\n' "$step" | sed -n 's/^\(nft delete table ip w3c\) .*$/\1/p')
  ipt_a=$(printf '%s\n' "$step" | sed -n 's/^\(iptables -t nat -A OUTPUT .*\)$/\1/p')
  ipt_d=$(printf '%s\n' "$step" | sed -n 's/.*or: \(iptables -t nat -D OUTPUT .*\)$/\1/p')
  { [ -n "$chain" ] && [ -n "$rule" ] && [ -n "$del" ] && [ -n "$ipt_a" ] && [ -n "$ipt_d" ]; } || ERRS+=('plan.md step 9 lines not found')
  nat_setup
  nat_decline
  out_has "$chain"
  out_has "$rule"
  out_has "$del"
  rm -f "$T/bin/nft"
  nat_decline
  out_has "$ipt_a"
  out_has "$ipt_d"
}

# two runs with the same tools print the same block
t_nat_text_stable() {
  local a b
  nat_setup
  nat_decline
  a=$(block_text)
  nat_decline
  b=$(block_text)
  [ -n "$a" ] && [ "$a" = "$b" ] || ERRS+=('the NAT block differs between two runs')
}

# on a terminal every command line starts with four spaces and carries no tag and no escape byte, so it pastes unchanged
t_nat_text_tty() {
  local cmd l n=0
  type -P script > /dev/null || { ERRS+=('script (util-linux) is missing; the case needs a pty'); return; }
  nat_setup
  snap "$T" > "$TMPROOT/snap.before"
  cmd=$(printf '%q ' env -i HOME="$T/home" PATH="$T/bin" MARK="$T/marks" FIX="$T/fix" W3C_PTRACE_SCOPE_FILE="$T/ptrace_scope" \
    W3C_PROC_DIR="$T/proc" W3C_FAUGUS_PY_DIR="$T/faugus-py" "$BASH_BIN" "$SCRIPT" install)
  printf 'y\nn\n\nn\n' | script -qec "$cmd" /dev/null > "$TMPROOT/out" 2> "$TMPROOT/err"
  RC=$?
  post_run "$T"
  rc_is 0
  OUT=$(tr -d '\r' <<< "$OUT")
  while IFS= read -r l; do
    case $l in
      *"sudo sh -c '"* | *'sudo nft delete table'*)
        n=$((n + 1))
        case $l in '    '[!' ']*) ;; *) ERRS+=("not four-space indented: $l") ;; esac
        case $l in *$'\033'* | *'[w3c-arch]'*) ERRS+=("tag or escape in a command line: $l") ;; esac ;;
    esac
  done <<< "$OUT"
  [ "$n" -ge 2 ] || ERRS+=("command lines seen on the terminal: want 2 got $n")
}

t_nat_persist_nft() {
  nat_setup
  nat_decline
  rc_is 0
  out_has 'printed only'
  out_has 'UNVERIFIED'
  out_has '/etc/nftables.conf'
  out_has 'systemctl enable nftables'
  out_has 'default-drop'
  out_has 'visudo -c'
  lacks_text 'iptables-save'
  changed_is
}

t_nat_persist_iptables() {
  nat_setup
  rm -f "$T/bin/nft"
  nat_decline
  rc_is 0
  out_has 'printed only'
  out_has 'UNVERIFIED'
  out_has 'iptables-save > /etc/iptables/iptables.rules'
  out_has 'iptables.service'
  out_has 'review'
  out_has 'visudo -c'
  lacks_text '/etc/nftables.conf'
  changed_is
}

# the removal block ends with the marker's removal, so the marker goes stale together with the rule
t_nat_remove_marker() {
  local want l found=0
  nat_setup
  nat_decline
  printf -v want '    rm -f %q' "$T/home/.local/state/w3c-linux/nat-applied"
  while IFS= read -r l; do [ "$l" = "$want" ] && found=1; done <<< "$OUT"
  [ "$found" = 1 ] || ERRS+=("no removal line: $want")
}

# real_nat VARIANT: the printed script run twice and its removal once, inside one throwaway user and net namespace
real_nat() {
  local v=$1 script rm_line list probe='nft list table ip w3c' out
  if ! unshare -Urn true 2> /dev/null || ! type -P "$v" > /dev/null; then
    printf '# skip: unshare -Urn unavailable or %s missing\n' "$v" >&2
    return 0
  fi
  nat_setup
  [ "$v" = nft ] || rm -f "$T/bin/nft"
  nat_decline
  script=$(printed_script)
  rm_line=$(printf '%s\n' "$OUT" | grep -m1 "^    sudo $v ")
  rm_line=${rm_line#'    sudo '}
  [ -n "$script" ] && [ -n "$rm_line" ] || { ERRS+=('no printed script or removal line'); return 0; }
  [ "$v" = nft ] || probe='iptables -t nat -S OUTPUT'
  out=$(unshare -Urn sh -c "$script; $script; echo ==1; $probe 2>&1; echo ==2; $rm_line 2>&1; echo ==3; $probe 2>&1" 2>&1)
  list=$(printf '%s\n' "$out" | awk '/^==1$/ { s = 1; next } /^==2$/ { s = 2; next } /^==3$/ { s = 3; next } s == 1')
  [ "$(printf '%s\n' "$list" | grep -c -e 'dnat to' -e '-j DNAT')" = 1 ] || ERRS+=("want exactly one rule after two applies: $out")
  list=$(printf '%s\n' "$out" | awk '/^==3$/ { s = 1; next } s')
  case $list in *'dnat to'* | *'-j DNAT'*) ERRS+=("the removal left the rule: $out") ;; esac
}

t_nat_real_nft() { real_nat nft; }
t_nat_real_iptables() { real_nat iptables; }

# ---------- prompt 8 edges (plan 05-02 Task 1) ----------

NAT_Q='Apply the LAN-test NAT rule now with sudo? [y/N]'

# nat_not_applied: no sudo call and no marker; install ended with exit 0 at prompt 10 (asked on stderr, or through zenity).
nat_not_applied() {
  rc_is 0
  case $ERR in *'Launch now?'*) ;; *) grep -qF 'Launch now?' "$T/marks/zenity" 2> /dev/null || ERRS+=('prompt 10 was not asked') ;; esac
  [ ! -e "$T/marks/sudo" ] || ERRS+=('sudo ran')
  [ ! -e "$T/home/.local/state/w3c-linux/nat-applied" ] || ERRS+=('a marker was written')
}

# nat_feed FEED: nat_setup, then one install with this stdin.
nat_feed() {
  nat_setup
  FEED=$1
  run "$T" install
}

t_nat_prompt_no() {
  nat_feed $'y\nn\n\nn\n'
  err_before 'Run it in another terminal, then press Enter' 'Launch now?'
  nat_not_applied
}

t_nat_prompt_default() {
  nat_feed $'y\n\n\nn\n'
  err_before 'Run it in another terminal, then press Enter' 'Launch now?'
  nat_not_applied
}

t_nat_prompt_quit() {
  nat_feed $'y\nn\nq\nn\n'
  err_before 'Run it in another terminal, then press Enter' 'Launch now?'
  nat_not_applied
}

t_nat_prompt_eof() {
  nat_feed $'y\n'
  err_has "$NAT_Q"
  err_has 'no answer (stdin closed); run in a terminal'
  nat_not_applied
}

t_nat_prompt_sudo_fail() {
  local FORBIDDEN=(wine wineserver nft iptables notify-send)
  nat_setup
  printf '1\n' > "$T/fix/sudo-rc"
  FEED=$'y\ny\nn\n'
  run "$T" install
  rc_is 0
  [ "$(printf '%s\n' "$OUT" | grep -c 'NAT rule not applied (sudo exit 1)')" = 1 ] || ERRS+=('want exactly one sudo failure line')
  [ "$(sudo_calls)" = 1 ] || ERRS+=("sudo calls: want 1 got $(sudo_calls)")
  [ ! -e "$T/home/.local/state/w3c-linux/nat-applied" ] || ERRS+=('a marker was written')
  err_has 'Launch now?'
}

t_nat_prompt_no_sudo() {
  nat_setup
  rm -f "$T/bin/sudo"
  FEED=$'y\n\nn\n'
  run "$T" install
  out_has "    sudo sh -c '"
  err_has 'sudo is not on PATH'
  case $ERR in *'Apply the LAN-test NAT rule now with sudo?'*) ERRS+=('asked the NAT question without sudo') ;; esac
  nat_not_applied
}

t_nat_prompt_zenity() {
  local q i l
  nat_setup
  # shellcheck disable=SC2016 # the shim text is written literally and expanded when the shim runs
  printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$0 $*" >> "$MARK/zenity"' 'case "$*" in *"NAT rule"* | *"Launch now?"*) exit 1 ;; esac' 'exit 0' > "$T/bin/zenity"
  chmod +x "$T/bin/zenity"
  CASE_ENV=(WAYLAND_DISPLAY=wayland-1)
  unset FEED
  run "$T" install
  nat_not_applied
  q=0 i=0 l=0
  while IFS= read -r line; do
    l=$((l + 1))
    case $line in
      *'NAT rule'*) q=$l; case $line in *--default-cancel*) ;; *) ERRS+=('the NAT question lacks --default-cancel') ;; esac ;;
      *--info*) [ "$q" -gt 0 ] && i=$l ;;
    esac
  done < "$T/marks/zenity"
  [ "$q" -gt 0 ] || ERRS+=('the NAT question did not go through zenity')
  [ "$i" -gt "$q" ] || ERRS+=('no zenity --info wait after the NAT question')
}

t_nat_prompt_order() {
  nat_feed $'y\nn\n\nn\n'
  err_before 'Continue?' 'Apply the LAN-test NAT rule now with sudo?'
  err_before 'Apply the LAN-test NAT rule now with sudo?' 'Launch now?'
  out_before 'Install complete' 'LAN-test NAT rule'
}

t_nat_marker_same_boot() {
  install_setup
  FEED=$'y\nn\n'
  run "$T" install
  rc_is 0
  out_has 'applied this boot (by w3c-linux)'
  case $ERR in *'Apply the LAN-test NAT rule now with sudo?'*) ERRS+=('asked although applied this boot') ;; esac
}

# marker_asks CONTENT: the marker holds CONTENT (nothing written when empty string is passed as the file kept empty); the question is asked.
marker_asks() {
  install_setup
  printf '%s' "$1" > "$T/home/.local/state/w3c-linux/nat-applied"
  FEED=$'y\nn\n\nn\n'
  run "$T" install
  rc_is 0
  err_has 'Apply the LAN-test NAT rule now with sudo?'
  lacks_text 'applied this boot'
}

t_nat_marker_other_boot() { marker_asks $'11111111-2222-3333-4444-555555555555\n'; }
t_nat_marker_empty() { marker_asks ''; }

t_nat_marker_no_bootid() {
  local FORBIDDEN=(wine wineserver nft iptables notify-send)
  nat_setup
  rm -f "$T/proc/sys/kernel/random/boot_id"
  FEED=$'y\ny\nn\n'
  run "$T" install
  rc_is 0
  err_has 'Apply the LAN-test NAT rule now with sudo?'
  [ "$(sudo_calls)" = 1 ] || ERRS+=("sudo calls: want 1 got $(sudo_calls)")
  [ ! -e "$T/home/.local/state/w3c-linux/nat-applied" ] || ERRS+=('a marker was written without a boot_id')
  FEED=$'y\ny\nn\n'
  run "$T" install
  err_has 'Apply the LAN-test NAT rule now with sudo?'
  [ "$(sudo_calls)" = 2 ] || ERRS+=("second run: sudo calls: want 2 got $(sudo_calls)")
}

# ---------- prompt 9: firewall and NTP lines (plan 05-02 Task 2) ----------

# fw_shims: systemctl answers `is-active --quiet U` with 0 only when U is a whole line of $FIX/active, else 3; timedatectl prints $FIX/ntp when
# it exists. Both log "$*" into $MARK/<name>. grep and cat are linked into the test PATH.
fw_shims() {
  # shellcheck disable=SC2016 # the shim text is written literally and expanded when the shim runs
  {
    printf '%s\n' '#!/bin/sh' 'echo "$*" >> "$MARK/systemctl"' \
      'if [ "$1" = is-active ] && [ "$2" = --quiet ] && grep -qx -- "$3" "$FIX/active" 2> /dev/null; then exit 0; fi' 'exit 3'
  } > "$T/bin/systemctl"
  # shellcheck disable=SC2016
  printf '%s\n' '#!/bin/sh' 'echo "$*" >> "$MARK/timedatectl"' '[ -f "$FIX/ntp" ] && cat "$FIX/ntp"' 'exit 0' > "$T/bin/timedatectl"
  chmod +x "$T/bin/systemctl" "$T/bin/timedatectl"
}

# fw_run ACTIVE_UNITS NTP: shims, the units that are active (space separated), the timedatectl output ('' prints nothing), one install at prompt 8's
# "applied this boot" line, then n at prompt 10.
fw_run() {
  install_setup
  fw_shims
  tr ' ' '\n' <<< "$1" > "$T/fix/active"
  [ "$2" = - ] || printf '%s\n' "$2" > "$T/fix/ntp"
  FEED=$'y\nn\n'
  run "$T" install
  rc_is 0
}

FW_PORTS='TCP 3550 3551 3552 | UDP 3552 5353 | mDNS multicast 224.0.0.251 UDP 5353'

t_fw_active() {
  fw_run 'ufw firewalld' yes
  out_has 'ufw firewalld'
  out_has "$FW_PORTS"
  out_has 'service.w3flo.com:3550'
  out_has 'stats.w3flo.com:3557'
  out_has 'INFERRED'
  lacks_text 'set-ntp'
}

t_fw_one() {
  fw_run nftables yes
  out_has "A firewall is active (nftables): allow $FW_PORTS"
  lacks_text 'iptables'
}

t_fw_none() {
  fw_run '' yes
  lacks_text '3550'
  lacks_text 'set-ntp'
}

t_fw_absent() {
  install_setup
  FEED=$'y\nn\n'
  run "$T" install
  rc_is 0
  lacks_text '3550'
  lacks_text 'set-ntp'
}

t_fw_ntp_off() {
  fw_run '' no
  out_has 'timedatectl set-ntp true'
  lacks_text '3550'
}

t_fw_ntp_empty() {
  fw_run '' -
  lacks_text 'set-ntp'
}

t_fw_order() {
  fw_run nftables no
  out_before 'applied this boot' 'A firewall is active'
  out_before 'A firewall is active' 'NTP is off'
  case $ERR in *'Launch now?'*) ;; *) ERRS+=('prompt 10 was not asked') ;; esac
}

t_fw_readonly() {
  fw_run nftables no
  [ "$(cat "$T/marks/systemctl")" = $'is-active --quiet nftables\nis-active --quiet iptables\nis-active --quiet ufw\nis-active --quiet firewalld' ] \
    || ERRS+=("systemctl calls: $(tr '\n' ';' < "$T/marks/systemctl")")
  [ "$(cat "$T/marks/timedatectl")" = 'show -p NTP --value' ] || ERRS+=("timedatectl calls: $(tr '\n' ';' < "$T/marks/timedatectl")")
  [ ! -e "$T/marks/sudo" ] || ERRS+=('sudo ran')
}

# sudo is run from exactly one place: the nat_apply function
t_static_one_sudo() {
  local hits
  hits=$(awk '/^[a-z_0-9]+\(\) \{/ { fn = $1 } /^[[:space:]]*#/ { next } /(^|[;&|!][[:space:]]*|[[:space:]](then|do|if)[[:space:]]+)[[:space:]]*sudo[[:space:]]/ { print fn }' "${SOURCES[@]}")
  [ "$hits" = 'nat_apply()' ] || ERRS+=("sudo invoked outside nat_apply or not exactly once: $hits")
}

# ---------- the monitor (plan 05-03) ----------
# monitor cases run on the base tree: the real tail behind a recording shim, real date, and the daily log written by the test process.

TAIL_BIN=$(type -P tail)   # resolved before any PATH narrowing
DATE_BIN=$(type -P date)
MLOG_REL='home/.local/state/w3c-linux/matches.log'

# tail_shim: records "<tail pid> <parent pid>" per start, then becomes the real tail (the monitor's bash is the parent).
tail_shim() {
  {
    printf '#!/bin/sh\n'
    # shellcheck disable=SC2016 # shim body is written literally and expanded when the shim runs
    printf 'echo "$$ $PPID" >> "$MARK/tail.pid"\n'
    printf 'exec %s "$@"\n' "$TAIL_BIN"
  } > "$T/bin/tail"
  chmod +x "$T/bin/tail"
}

# mon_setup: tail shim, ls, and the paths the test process writes under the prefix.
mon_setup() {
  tail_shim
  add_link "$T" ls
  ALLOW_EXTRA+=("${LAN_DIR_REL%/*}" "$LAN_DIR_REL")
}

# day_file DAY: the launcher's log file for that UTC day, relative to T.
day_file() { printf '%s/w3champions.%s.log' "$LAN_DIR_REL" "$1"; }

# log_line TEXT [DAY]: appends a line to that day's log (today by default), creating the directory.
log_line() {
  local d=${2:-$("$DATE_BIN" -u +%F)}
  mkdir -p "$T/$LAN_DIR_REL"
  printf '%s\n' "$1" >> "$T/$(day_file "$d")"
  ALLOW_EXTRA+=("$(day_file "$d")")
}

matches() { cat "$T/$MLOG_REL" 2> /dev/null; }

# wait_file_has FILE TEXT [N]: up to 10 s until FILE holds TEXT on at least N lines (default 1).
wait_file_has() {
  local i n
  for ((i = 0; i < 100; i++)); do
    n=$(grep -cF -- "$2" "$1" 2> /dev/null)
    [ "${n:-0}" -ge "${3:-1}" ] && return 0
    sleep 0.1
  done
  ERRS+=("timed out waiting for $1 to hold: $2")
}

# wait_matches TEXT [N]: wait_file_has on the tally.
wait_matches() { wait_file_has "$T/$MLOG_REL" "$@"; }

# tail_up [N]: up to 10 s until N tails have started (default 1) and the last one has exec'd the real tail and gone to sleep, that is, made its
# first look at the file or directory; a line written after this returns is therefore never skipped by -n 0 and never written before the tail looked.
tail_up() {
  local i n p want
  want=$(readlink -f "$TAIL_BIN")
  for ((i = 0; i < 100; i++)); do
    n=$(grep -c . "$T/marks/tail.pid" 2> /dev/null)
    if [ "${n:-0}" -ge "${1:-1}" ]; then
      p=$(tail_pid)
      [ "$(readlink -f "/proc/$p/exe" 2> /dev/null)" = "$want" ] && [ "$(awk '{ print $3 }' "/proc/$p/stat" 2> /dev/null)" = S ] && return 0
    fi
    sleep 0.1
  done
  ERRS+=("timed out waiting for tail start $1")
}

# tail_pid [N], mon_pid: the tail (N-th start, default last) and the monitor's own pid (of the last start).
tail_pid() { awk -v n="${1:-0}" 'n == 0 { l = $1 } NR == n { l = $1 } END { print l }' "$T/marks/tail.pid" 2> /dev/null; }
mon_pid() { awk 'END { print $2 }' "$T/marks/tail.pid" 2> /dev/null; }
# mon_kill: TERM to every monitor that started a tail (a stray second one included, so a failing case cannot hang finish).
mon_kill() {
  local p
  while read -r p; do kill -TERM "$p" 2> /dev/null; done < <(awk '{ print $2 }' "$T/marks/tail.pid" 2> /dev/null | sort -u)
}

# gone PID: up to 2 s until the process no longer exists.
gone() {
  local i
  for ((i = 0; i < 20; i++)); do
    kill -0 "$1" 2> /dev/null || return 0
    sleep 0.1
  done
  return 1
}

# mon_quiet: stdout empty, as D-14 demands of every monitor run.
mon_quiet() { [ -z "$OUT" ] || ERRS+=("stdout is not empty: $OUT"); }

GAME_END_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2} game-end target=\? mode=\? wv2flags=--no-sandbox$'
TELEMETRY='[2026-10-09T10:00:00Z INFO match_telemetry] PlayerMatchTelemetryReport emitted'

# The tracer: a telemetry line in today's log, written after the monitor started, becomes one game-end line.
t_mon_tally_game_end() {
  local tp
  mon_setup
  run_fifo "$T" monitor
  tail_up 1
  wait_err 'does not exist yet'
  tp=$(tail_pid)
  log_line "$TELEMETRY"
  wait_matches game-end
  mon_kill
  finish
  rc_is 0
  mon_quiet
  [ "$(matches | grep -c .)" = 1 ] || ERRS+=("matches.log lines: $(matches)")
  [[ $(matches) =~ $GAME_END_RE ]] || ERRS+=("matches.log line: $(matches)")
  gone "$tp" || ERRS+=("tail $tp is still running")
}

# ---------- tally events (Task 2) ----------

# A dead tail is not silent: the monitor tallies MONITOR-DOWN and exits 1.
t_mon_tail_down() {
  mon_setup
  run_fifo "$T" monitor
  tail_up 1
  kill "$(tail_pid)" 2> /dev/null
  wait_matches MONITOR-DOWN
  finish
  rc_is 1
  mon_quiet
  ev_is MONITOR-DOWN 1
}

SENTINEL='[2026-10-09T10:09:59Z WARN instanceHandle] Left during game creation'
SUBMIT='[2026-10-09T10:05:00Z ERROR frontend] [match] submitGameExited: No current match or battleTag'
SENT='2026-10-10T21:31:36.745951Z  INFO frontend: [match] Match result UYGYL9pz8P sent successfully'

# notify_shim: a recording notify-send (a '== call ==' line, then one argument per line).
notify_shim() {
  cat > "$T/bin/notify-send" <<'SH'
#!/bin/sh
{ echo '== call =='; for a in "$@"; do printf '%s\n' "$a"; done; } >> "$MARK/notify-send"
SH
  chmod +x "$T/bin/notify-send"
}

# notify_call N: the argument lines of the N-th recorded notify-send call.
notify_call() { awk -v n="$1" '/^== call ==$/ { c++; next } c == n' "$T/marks/notify-send" 2> /dev/null; }
notify_calls() {
  local n
  n=$(grep -c '^== call ==$' "$T/marks/notify-send" 2> /dev/null)
  printf '%s' "${n:-0}"
}

# mon_feed_n N LINE...: starts the monitor, writes the lines and then the sentinel (a JOIN-BUG line), waits until the tally holds N JOIN-BUG
# lines (so every earlier line was processed), stops the monitor and finishes.
mon_feed_n() {
  local n=$1 l
  shift
  run_fifo "$T" monitor
  tail_up 1
  for l in "$@"; do log_line "$l"; done
  log_line "$SENTINEL"
  wait_matches JOIN-BUG "$n"
  mon_kill
  finish
  rc_is 0
  mon_quiet
}
mon_feed() { mon_feed_n 1 "$@"; }

# ev_count EVENT: how many tally lines carry that event.
ev_count() {
  local n
  n=$(matches | grep -c " $1 target=")
  printf '%s' "${n:-0}"
}

# ev_is EVENT N: the tally holds exactly N lines of that event.
ev_is() { [ "$(ev_count "$1")" = "$2" ] || ERRS+=("$1 lines: want $2 got $(ev_count "$1"): $(matches | tr '\n' '|')"); }

t_mon_tally_result_lost() {
  local FORBIDDEN=(wine wineserver sudo nft iptables) c
  mon_setup
  notify_shim
  mon_feed "$TELEMETRY" "$SUBMIT"
  ev_is game-end 1
  ev_is RESULT-LOST 1
  [ "$(matches | awk '{ print $2 }' | tr '\n' ' ')" = 'game-end RESULT-LOST JOIN-BUG ' ] || ERRS+=("event order: $(matches | tr '\n' '|')")
  [ "$(notify_calls)" = 1 ] || ERRS+=("notify-send calls: $(notify_calls)")
  c=$(notify_call 1)
  [ "$(sed -n 1,3p <<< "$c" | tr '\n' ' ')" = '-u critical W3Champions ' ] || ERRS+=("notify-send argv: $c")
  case $c in *'Match result NOT submitted'*) ;; *) ERRS+=("notify-send body: $c") ;; esac
}

t_mon_tally_unarmed() {
  mon_setup
  mon_feed "$SUBMIT" "$SUBMIT" "$SUBMIT"
  ev_is RESULT-LOST 0
  ev_is game-end 0
}

t_mon_tally_ttl() {
  CASE_ENV=(W3C_MONITOR_ARM_SECS=0)
  mon_setup
  mon_feed "$TELEMETRY" "$SUBMIT"
  ev_is game-end 1
  ev_is RESULT-LOST 0
}

t_mon_tally_once() {
  local FORBIDDEN=(wine wineserver sudo nft iptables)
  mon_setup
  notify_shim
  mon_feed "$TELEMETRY" "$SUBMIT" "$SUBMIT"
  ev_is RESULT-LOST 1
  [ "$(notify_calls)" = 1 ] || ERRS+=("notify-send calls: $(notify_calls)")
}

t_mon_tally_sent() {
  local FORBIDDEN=(wine wineserver sudo nft iptables)
  mon_setup
  notify_shim
  mon_feed "$TELEMETRY" "$SENT" "$SUBMIT" "$SUBMIT"
  ev_is game-end 1
  ev_is RESULT-LOST 0
  [ "$(notify_calls)" = 0 ] || ERRS+=("notify-send calls: $(notify_calls)")
  [ "$(matches | awk '{ print $2 }' | tr '\n' ' ')" = 'game-end JOIN-BUG ' ] || ERRS+=("event order: $(matches | tr '\n' '|')")
  case $(matches) in *UYGYL9pz8P*) ERRS+=("match id leaked into the tally") ;; esac
}

# A failure line holding the success words must not disarm: the lost result is still reported.
t_mon_tally_sent_failure_line() {
  local FORBIDDEN=(wine wineserver sudo nft iptables)
  mon_setup
  notify_shim
  mon_feed "$TELEMETRY" '2026-10-10T21:31:36.745951Z  INFO frontend: [match] Match result UYGYL9pz8P was not sent successfully' "$SUBMIT"
  ev_is RESULT-LOST 1
  [ "$(notify_calls)" = 1 ] || ERRS+=("notify-send calls: $(notify_calls)")
}

t_mon_tally_sent_rearm() {
  local FORBIDDEN=(wine wineserver sudo nft iptables)
  mon_setup
  notify_shim
  mon_feed "$SENT" "$TELEMETRY" "$SENT" "$TELEMETRY" "$SUBMIT"
  ev_is game-end 2
  ev_is RESULT-LOST 1
  [ "$(matches | awk '{ print $2 }' | tr '\n' ' ')" = 'game-end game-end RESULT-LOST JOIN-BUG ' ] || ERRS+=("event order: $(matches | tr '\n' '|')")
  [ "$(notify_calls)" = 1 ] || ERRS+=("notify-send calls: $(notify_calls)")
}

t_mon_tally_joined() {
  mon_setup
  mon_feed '[2026-10-09T10:01:00Z INFO instanceHandle] Received LanGameJoined event for game: 2 for flo-ladder-81'
  ev_is joined 1
}

# flo's slot-status line alone is not a join source: LanGameJoined is logged for the same join and names the game.
t_mon_tally_slot_joined() {
  mon_setup
  mon_feed '[2026-10-09T10:01:00Z INFO flo] update slot client status: Joined'
  ev_is joined 0
}

t_mon_tally_ladder_join() {
  mon_setup
  mon_feed '2026-10-10T21:30:51.558305Z  INFO frontend: [InstanceHandle] Received LanGameJoined event for game: 1 for w3c-20-UYGYL9pz8P-19843442' \
    '2026-10-10T21:30:51.597274Z  INFO flo_client::node::stream: update slot client status: Joined game_id=13884776 player_id=19843442'
  ev_is joined 1
}

t_mon_tally_test_join() {
  mon_setup
  mon_feed '[2026-10-09T10:01:00Z INFO InstanceHandle] Received LanGameJoined event for game: 1 for w3c-test-17688'
  ev_is joined 0
}

t_mon_tally_join_bug() {
  mon_setup
  mon_feed_n 3 '[2026-10-09T10:02:00Z WARN flo] Left during game creation' '[2026-10-09T10:02:01Z WARN launcher] Causing join bug, restart launcher'
  ev_is JOIN-BUG 3
}

t_mon_tally_hostile() {
  local hostile
  mon_setup
  # shellcheck disable=SC2016 # the hostile text must stay literal
  printf -v hostile '%s $(touch %s) `touch %s` \033[31m ; rm -rf x' "$TELEMETRY" "$T/fix/pwned" "$T/fix/pwned"
  mon_feed "$hostile"
  ev_is game-end 1
  [[ $(matches | grep ' game-end ') =~ $GAME_END_RE ]] || ERRS+=("game-end line is not the plain form: $(matches)")
  # shellcheck disable=SC2016 # a literal $( is what is looked for
  case $(matches) in *$'\033'* | *'$('* | *touch* | *rm*) ERRS+=("matches.log holds line text: $(matches)") ;; esac
  [ ! -e "$T/fix/pwned" ] || ERRS+=('a command in the log line ran')
}

t_mon_tally_crlf() {
  mon_setup
  mon_feed "$TELEMETRY"$'\r'
  ev_is game-end 1
  [ -z "$(matches | tr -d -c '\r')" ] || ERRS+=('matches.log holds a carriage return')
}

# replay_at REL MTIME: an empty .w3g under the prefix's Documents/Warcraft III/BattleNet, with that modification time.
replay_at() {
  local f
  f="$(pfx)/drive_c/users/steamuser/Documents/Warcraft III/BattleNet/$1"
  mkdir -p "${f%/*}"
  : > "$f"
  touch -d "$2" "$f"
}

t_mon_notify_replay() {
  local FORBIDDEN=(wine wineserver sudo nft iptables) c
  mon_setup
  notify_shim
  replay_at 111/Replays/a.w3g '2026-10-01 12:00:00'
  replay_at 222/Replays/b.w3g '2026-10-08 12:00:00'
  mon_feed "$TELEMETRY" "$SUBMIT"
  c=$(notify_call 1)
  case $c in *"Newest replay: $(pfx)/drive_c/users/steamuser/Documents/Warcraft III/BattleNet/222/Replays/b.w3g") ;; *) ERRS+=("body does not end with the newest replay: $c") ;; esac
}

t_mon_notify_none() {
  local FORBIDDEN=(wine wineserver sudo nft iptables) c
  mon_setup
  notify_shim
  mon_feed "$TELEMETRY" "$SUBMIT"
  c=$(notify_call 1)
  case $c in *"no replay found under $(pfx)/drive_c/users/steamuser/Documents/Warcraft III/BattleNet"*) ;; *) ERRS+=("body: $c") ;; esac
}

t_mon_notify_absent() {
  mon_setup
  rm -f "$T/bin/notify-send"
  mon_feed "$TELEMETRY" "$SUBMIT"
  ev_is RESULT-LOST 1
  case $ERR in *notify*) ERRS+=("stderr mentions notify: $ERR") ;; esac
}

# ---------- day switch, read-from-end, single instance, tag (Task 3) ----------

# date_shim DAY: `date -u +%F` prints the day in $FIX/utcday (written here, changed by the case); every other call is the real date.
date_shim() {
  rm -f "$T/bin/date"   # mk_tree linked the real one
  {
    printf '#!/bin/sh\n'
    # shellcheck disable=SC2016 # shim body is written literally and expanded when the shim runs
    printf 'if [ $# = 2 ] && [ "$1 $2" = "-u +%%F" ] && [ -f "$FIX/utcday" ]; then read -r d < "$FIX/utcday"; echo "$d"; exit 0; fi\n'
    printf 'exec %s "$@"\n' "$DATE_BIN"
  } > "$T/bin/date"
  chmod +x "$T/bin/date"
  printf '%s\n' "$1" > "$T/fix/utcday"
  ALLOW_EXTRA+=(fix/utcday)
}

# tail_opens FILE: up to 10 s until the last tail holds FILE open.
tail_opens() {
  local i f p
  for ((i = 0; i < 100; i++)); do
    p=$(tail_pid)
    for f in /proc/"$p"/fd/*; do
      [ "$(readlink -f -- "$f" 2> /dev/null)" = "$(readlink -f -- "$1")" ] && return 0
    done
    sleep 0.1
  done
  ERRS+=("tail never opened $1")
}

JOINED='[2026-10-08T23:59:00Z INFO instanceHandle] Received LanGameJoined event for game: 2 for flo-ladder-81'

t_mon_day_switch() {
  local t1
  CASE_ENV=(W3C_MONITOR_POLL_SECS=1)
  mon_setup
  date_shim 2026-10-08
  run_fifo "$T" monitor
  tail_up 1
  t1=$(tail_pid 1)
  log_line "$JOINED" 2026-10-08
  wait_matches joined
  printf '2026-10-09\n' > "$T/fix/utcday"
  log_line "$SENTINEL" 2026-10-09
  wait_matches JOIN-BUG
  mon_kill
  finish
  rc_is 0
  mon_quiet
  [ "$(grep -c . "$T/marks/tail.pid")" = 2 ] || ERRS+=("tail starts: $(grep -c . "$T/marks/tail.pid")")
  gone "$t1" || ERRS+=("the first tail $t1 is still running")
  ev_is joined 1
  ev_is JOIN-BUG 1
}

t_mon_day_no_file() {
  CASE_ENV=(W3C_MONITOR_POLL_SECS=1)
  mon_setup
  date_shim 2026-10-08
  run_fifo "$T" monitor
  tail_up 1
  log_line "$JOINED" 2026-10-08
  wait_matches joined
  printf '2026-10-09\n' > "$T/fix/utcday"
  sleep 3   # the one observation window: the monitor must stay on the old file while the new day has none
  [ "$(grep -c . "$T/marks/tail.pid")" = 1 ] || ERRS+=("a second tail started without a new file")
  log_line "$JOINED" 2026-10-08
  wait_matches joined 2
  mon_kill
  finish
  rc_is 0
  mon_quiet
  ev_is joined 2
}

t_mon_from_end() {
  mon_setup
  log_line "$TELEMETRY"
  run_fifo "$T" monitor
  tail_up 1
  tail_opens "$T/$(day_file "$("$DATE_BIN" -u +%F)")"
  log_line "$SENTINEL"
  wait_matches JOIN-BUG
  mon_kill
  finish
  rc_is 0
  mon_quiet
  ev_is game-end 0
  ev_is JOIN-BUG 1
}

t_mon_solo_second() {
  local out2 err2 rc2 pid2 i
  mon_setup
  run_fifo "$T" monitor
  tail_up 1
  err2=$TMPROOT/err2
  run_cmd "$T" monitor < /dev/null > "$TMPROOT/out2" 2> "$err2" &
  pid2=$!
  for ((i = 0; i < 50; i++)); do
    kill -0 "$pid2" 2> /dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid2" 2> /dev/null; then   # it must have exited by itself; a second live monitor is stopped so the case ends
    ERRS+=('the second monitor kept running')
    pkill -TERM -P "$pid2" 2> /dev/null
    kill -TERM "$pid2" 2> /dev/null
  fi
  wait "$pid2"
  rc2=$?
  out2=$(< "$TMPROOT/out2")
  [ "$rc2" = 0 ] || ERRS+=("second monitor exit code: $rc2")
  [ -z "$out2" ] || ERRS+=("second monitor stdout: $out2")
  case $(< "$err2") in *'monitor: already running'*) ;; *) ERRS+=("second monitor stderr: $(< "$err2")") ;; esac
  [ "$(grep -c . "$T/marks/tail.pid")" = 1 ] || ERRS+=("the second monitor started a tail")
  mon_kill
  finish
  rc_is 0
  mon_quiet
}

t_mon_solo_nodir() {
  mon_setup
  mon_feed "$JOINED"
  [ "$(grep -cF 'does not exist yet' <<< "$ERR")" = 1 ] || ERRS+=("does-not-exist lines on stderr: $ERR")
  ev_is joined 1
}

t_mon_solo_unwritable() {
  mon_setup
  mkdir -p "$T/$MLOG_REL"
  run_fifo "$T" monitor
  tail_up 1
  log_line "$TELEMETRY"
  wait_err 'monitor: cannot write'
  kill -0 "$(mon_pid)" 2> /dev/null || ERRS+=('the monitor died on an unwritable tally')
  mon_kill
  finish
  rc_is 0
  mon_quiet
}

t_mon_tag_flags() {
  local l1 l2 l3
  mon_setup
  CASE_ENV=('W3C_WRAPPER_WEBVIEW_FLAGS=--no-sandbox --in-process-gpu')
  mon_feed_n 1
  CASE_ENV=(W3C_WRAPPER_WEBVIEW_FLAGS=)
  mon_feed_n 2
  CASE_ENV=("W3C_WRAPPER_WEBVIEW_FLAGS=--a"$'\n'"2026-10-09T00:00:00+00:00 RESULT-LOST \$(x)")
  mon_feed_n 3
  [ "$(matches | grep -c .)" = 3 ] || ERRS+=("matches.log lines: $(matches | tr '\n' '|')")
  l1=$(matches | sed -n 1p) l2=$(matches | sed -n 2p) l3=$(matches | sed -n 3p)
  case $l1 in *' wv2flags=--no-sandbox,--in-process-gpu') ;; *) ERRS+=("line 1: $l1") ;; esac
  case $l2 in *' wv2flags=off') ;; *) ERRS+=("line 2: $l2") ;; esac
  [[ $l3 =~ ^[^\ ]+\ JOIN-BUG\ target=\?\ mode=\?\ wv2flags=[A-Za-z0-9._=,:+-]+$ ]] || ERRS+=("line 3: $l3")
}

# ---------- launch owns the monitor (plan 05-04) ----------

REAL_SLEEP=$(type -P sleep)   # the session sleep shim is sleep itself, so it calls the real one by path
MONLOCK_REL='home/.local/state/w3c-linux/monitor.lock'

# life_pre: shim text, run once the launcher has appeared ($FIX/armed): waits (bounded 10 s) until the monitor's tail has exec'd the real tail and
# gone to sleep, so a line written afterwards is never skipped by -n 0 and the session cannot end before the monitor ran.
life_pre() {
  cat <<EOF
if [ -f "\$FIX/armed" ]; then
  i=0
  while [ "\$i" -lt 100 ]; do
    if [ -s "\$MARK/tail.pid" ] && read -r tp mp 2> /dev/null < "\$MARK/tail.pid" && [ "\$(readlink -f "/proc/\$tp/exe" 2> /dev/null)" = '$(readlink -f "$TAIL_BIN")' ] && [ "\$(awk '{ print \$3 }' "/proc/\$tp/stat" 2> /dev/null)" = S ]; then break; fi
    $REAL_SLEEP 0.1
    i=\$((i + 1))
  done
fi
EOF
}

# life_tell: shim text, once: appends a telemetry line to today's log (absent before, so tail reads it from line 1) and waits (bounded) until
# the tally holds it, so the session cannot end before the monitor wrote the line.
life_tell() {
  cat <<EOF
if [ -f "\$FIX/armed" ] && [ ! -f "\$FIX/told" ]; then
  : > "\$FIX/told"
  mkdir -p '$T/$LAN_DIR_REL'
  printf '%s\n' '$TELEMETRY' >> "$T/$LAN_DIR_REL/w3champions.\$(date -u +%F).log"
  i=0
  while [ "\$i" -lt 100 ] && ! grep -qF game-end '$T/$MLOG_REL' 2> /dev/null; do
    $REAL_SLEEP 0.1
    i=\$((i + 1))
  done
fi
EOF
}

# life_setup [plain|tell]: l_setup, the tail shim and the daily-log paths; the sleep shim waits for the monitor's tail (not with plain), with
# tell it also writes the telemetry line.
life_setup() {
  local body=$SLEEP_BODY
  l_setup
  mon_setup
  case ${1:-} in
    plain) ;;
    tell)
      ALLOW_EXTRA+=(fix/told "$(day_file "$("$DATE_BIN" -u +%F)")")
      body=$(life_pre)$'\n'$(life_tell)$'\n'$SLEEP_BODY ;;
    *) body=$(life_pre)$'\n'$SLEEP_BODY ;;
  esac
  sleep_shim "$T" "$body"
}

# lock_free: the monitor lock is not held by anyone.
lock_free() { flock -n "$T/$MONLOCK_REL" true 2> /dev/null || ERRS+=('the monitor lock is held'); }

# all_gone: the recorded tail and monitor processes are gone within 2 s each.
all_gone() {
  local tp mp
  tp=$(tail_pid) mp=$(mon_pid)
  if [ -z "$tp" ] || [ -z "$mp" ]; then
    ERRS+=('no monitor tail was recorded')
    return
  fi
  gone "$tp" || ERRS+=("tail $tp is still running")
  gone "$mp" || ERRS+=("monitor $mp is still running")
}

# The tracer: a launch session starts one monitor right after the launcher and leaves nothing behind.
t_mon_life_launch() {
  life_setup
  go
  rc_is 0
  out_has "Match monitor: lost results and join bugs are tallied in $T/$MLOG_REL"
  umu_count 1
  [ "$(grep -c . "$T/marks/tail.pid" 2> /dev/null)" = 1 ] || ERRS+=("tail starts: want 1 got $(grep -c . "$T/marks/tail.pid" 2> /dev/null)")
  lock_free
  all_gone
  mon_kill
}

# D-13: the session's knobs are in the tally lines (.bat target, flags as one token)
t_mon_life_tag() {
  CASE_ENV=(W3C_LAUNCH_BAT=1 'W3C_WRAPPER_WEBVIEW_FLAGS=--no-sandbox --in-process-gpu')
  life_setup tell
  go
  rc_is 0
  case $(matches) in
    *' game-end target=bat mode=nsenter wv2flags=--no-sandbox,--in-process-gpu') ;;
    *) ERRS+=("matches.log: $(matches)") ;;
  esac
  all_gone
  mon_kill
}

# D-13: the D-08 fallback is mode=run
t_mon_life_run_mode() {
  life_setup tell
  down
  CASE_ENV=(W3C_BUS_WAIT_SECS=2)
  FEED=$'y\n\n'
  run "$T" launch
  rc_is 0
  faugus_once
  case $(matches) in
    *' game-end target=exe mode=run wv2flags=--no-sandbox') ;;
    *) ERRS+=("matches.log: $(matches)") ;;
  esac
  all_gone
  mon_kill
}

# never more than one: a standalone monitor during a launch session says so and exits 0
t_mon_life_second() {
  local err2=$TMPROOT/err2 pid2 i rc2
  life_setup
  run_fifo "$T" launch
  send $'\n'
  tail_up 1
  : > "$err2"
  run_cmd "$T" monitor < /dev/null > "$TMPROOT/out2" 2> "$err2" &
  pid2=$!
  for ((i = 0; i < 50; i++)); do
    kill -0 "$pid2" 2> /dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid2" 2> /dev/null; then   # a second live monitor is stopped so the case ends
    ERRS+=('the standalone monitor kept running')
    pkill -TERM -P "$pid2" 2> /dev/null
    kill -TERM "$pid2" 2> /dev/null
  fi
  wait "$pid2"
  rc2=$?
  [ "$rc2" = 0 ] || ERRS+=("standalone monitor exit code: $rc2")
  case $(< "$err2") in *'monitor: already running'*) ;; *) ERRS+=("standalone monitor stderr: $(< "$err2")") ;; esac
  [ "$(grep -c . "$T/marks/tail.pid" 2> /dev/null)" = 1 ] || ERRS+=("tail starts: want 1 got $(grep -c . "$T/marks/tail.pid" 2> /dev/null)")
  mon_kill
  finish
  rc_is 0
}

# a held monitor lock: launch says so, starts none and leaves the holder alone
t_mon_life_busy() {
  local fd
  life_setup plain
  mkdir -p "$T/${MONLOCK_REL%/*}"
  exec {fd}> "$T/$MONLOCK_REL"
  flock -n "$fd" || ERRS+=('the test could not take the monitor lock')
  go
  rc_is 0
  out_has 'Match monitor already running'
  [ ! -e "$T/marks/tail.pid" ] || ERRS+=('a tail started although the lock was held')
  if flock -n "$T/$MONLOCK_REL" true 2> /dev/null; then ERRS+=("the holder's lock was released by the run"); fi
  exec {fd}>&-
  lock_free
  umu_count 1
}

# TERM on launch: the EXIT trap stops the monitor and its tail and frees the lock
t_mon_life_term() {
  local mp lp
  life_setup
  run_fifo "$T" launch
  send $'\n'
  tail_up 1
  mp=$(mon_pid)
  lp=''
  [ -z "$mp" ] || lp=$(awk '{ print $4 }' "/proc/$mp/stat" 2> /dev/null)
  case $(tr '\0' ' ' < "/proc/${lp:-0}/cmdline" 2> /dev/null) in *"$SCRIPT"*) ;; *) ERRS+=("the monitor's parent is not the launch process: ${lp:-none}") ;; esac
  kill -TERM "${lp:-0}" 2> /dev/null
  finish
  rc_is 143
  lock_free
  all_gone
  mon_kill
}

# the monitor never holds the run lock (fd 9): the launcher is late, so launch still holds it while the monitor runs
t_mon_life_fd9() {
  local mp lp
  life_setup
  no_start_hook
  printf '%s\n' "$LP" > "$T/fix/appear"
  run_fifo "$T" launch
  send $'\n'
  tail_up 1
  mp=$(mon_pid)
  lp=''
  [ -z "$mp" ] || lp=$(awk '{ print $4 }' "/proc/$mp/stat" 2> /dev/null)
  [ -e "/proc/${lp:-0}/fd/9" ] || ERRS+=('control: launch no longer holds the run lock')
  [ -z "$mp" ] || [ ! -e "/proc/$mp/fd/9" ] || ERRS+=('the monitor holds the run lock descriptor')
  mon_kill
  finish
  rc_is 0
}

# a launcher respawned by the D-10 restart does not hold the monitor lock (fd 8)
t_mon_life_fd() {
  local i
  life_setup
  # shellcheck disable=SC2016 # the hook text is written literally and expanded when umu-run sources it
  umu_hook "$T" "$LAUNCH_HOOK"$'\n''[ -e /proc/$$/fd/8 ] && echo fd8 >> "$MARK/fd8"'
  run_fifo "$T" launch
  send $'\n'
  tail_up 1
  wait_err 'it starts again by itself'
  send $'\n'
  wait_err 'Restart requested: close the W3Champions window; it starts again once it has exited'
  grep -v 'W3Champions\.exe' "$T/fix/procs" > "$T/fix/procs.n"
  mv "$T/fix/procs.n" "$T/fix/procs"
  for ((i = 0; i < 100; i++)); do
    [ "$(grep -c . "$T/marks/umu-run" 2> /dev/null)" = 2 ] && break
    sleep 0.1
  done
  finish
  rc_is 0
  umu_count 2
  [ ! -e "$T/marks/fd8" ] || ERRS+=('the respawned launcher holds the monitor lock descriptor')
  [ "$(grep -c . "$T/marks/tail.pid" 2> /dev/null)" = 1 ] || ERRS+=("tail starts: want 1 got $(grep -c . "$T/marks/tail.pid" 2> /dev/null)")
  mon_kill
}

# D-14: nothing of the monitor on the terminal but launch's own line
t_mon_life_silent() {
  life_setup
  go
  rc_is 0
  [ "$(grep -c onitor <<< "$OUT")" = 1 ] || ERRS+=("monitor lines on stdout: $(grep onitor <<< "$OUT")")
  case $ERR in *onitor*) ERRS+=("stderr mentions the monitor: $ERR") ;; esac
  mon_kill
}

# ---------- LAN-test failure in launch (plan 05-04 Task 2) ----------

# nl_case N: lan_case with N LAN-test failure lines written when the launcher starts, the nat-applied marker gone, the recording sudo shim.
nl_case() {
  lan_case "$(hook_lines "$1")"
  rm -f "$T/home/.local/state/w3c-linux/nat-applied"
  sudo_shim
}

# wait_out TEXT: up to 10 s until stdout holds TEXT.
wait_out() {
  local i
  for ((i = 0; i < 100; i++)); do
    grep -qF -- "$1" "$TMPROOT/out" && return 0
    sleep 0.1
  done
  ERRS+=("timed out waiting for stdout: $1")
}

# nat_q_count: how often the NAT question was asked on stderr.
nat_q_count() { grep -oF 'Apply the LAN-test NAT rule now with sudo?' <<< "$ERR" | wc -l; }

# the offer is a LAN-test failure in this session, then y: the printed text runs through one sudo and the boot is recorded
t_nat_launch_offer() {
  local FORBIDDEN=(wine wineserver nft iptables notify-send) want got
  nl_case 1
  run_fifo "$T" launch
  send $'\n'
  wait_err "$NAT_Q"
  send $'y\n'
  wait_out 'To retest:'
  finish
  rc_is 0
  [ "$(hint_count)" = 1 ] || ERRS+=("hint lines: want 1 got $(hint_count)")
  out_has 'NAT rule applied'
  out_has "To retest: use the launcher's LAN test, or press Enter here and then close the W3Champions window; it starts again by itself."
  out_has 'W3C_LAUNCH_BAT=1 w3c-linux.sh launch'
  out_before 'LAN test failed' "    sudo sh -c '"
  out_before "    sudo sh -c '" 'To retest:'
  want=$(printed_script) || ERRS+=('no printed sudo sh -c line')
  [ "$(sudo_calls)" = 1 ] || ERRS+=("sudo calls: want 1 got $(sudo_calls)")
  got=$(sudo_call 1)
  [ "$got" = $'sh\n-c\n'"$want" ] || ERRS+=("sudo argv differs from the printed line: $got")
  want=$(< "$T/proc/sys/kernel/random/boot_id")
  got=$(cat "$T/home/.local/state/w3c-linux/nat-applied" 2> /dev/null)
  [ -n "$want" ] && [ "$got" = "$want" ] || ERRS+=("nat-applied marker: want $want got $got")
  umu_count 1
}

# n: the wait takes its own Enter, which is not a restart request; no sudo, no marker
t_nat_launch_no() {
  nl_case 1
  run_fifo "$T" launch
  send $'\n'
  wait_err "$NAT_Q"
  send $'n\n'
  wait_err 'Run it in another terminal, then press Enter'
  send $'\n'
  wait_out 'To retest:'
  finish
  rc_is 0
  [ ! -e "$T/marks/sudo" ] || ERRS+=('sudo ran')
  case $ERR in *'Restart requested'*) ERRS+=('the answer to the NAT wait requested a restart') ;; esac
  [ ! -e "$T/home/.local/state/w3c-linux/nat-applied" ] || ERRS+=('a marker was written')
  umu_count 1
  out_has 'W3Champions exited'
}

# EOF is No: the launch goes on to the launcher's normal exit
t_nat_launch_eof() {
  nl_case 1
  go
  rc_is 0
  err_has "$NAT_Q"
  err_has 'no answer (stdin closed)'
  out_has 'W3Champions exited'
  [ "$(hint_count)" = 1 ] || ERRS+=("hint lines: want 1 got $(hint_count)")
  [ ! -e "$T/home/.local/state/w3c-linux/nat-applied" ] || ERRS+=('a marker was written')
}

# D-04: the marker equals this boot, so the hint says so and nothing is asked
t_nat_launch_marker() {
  lan_case "$(hook_lines 1)"
  sudo_shim
  go
  rc_is 0
  out_has 'NAT rule applied this boot (by w3c-linux)'
  out_has 'W3C_LAUNCH_BAT=1 w3c-linux.sh launch'
  [ "$(hint_count)" = 1 ] || ERRS+=("hint lines: want 1 got $(hint_count)")
  case $ERR in *'[y/N]'*) ERRS+=('a question was asked although the rule was applied this boot') ;; esac
  lacks_text 'LAN-test NAT rule ('
}

# D-03: no failure in this session, no question and no block (the marker is gone, so a question would show)
t_nat_launch_quiet() {
  l_setup
  rm -f "$T/home/.local/state/w3c-linux/nat-applied"
  sudo_shim
  go
  rc_is 0
  case $ERR in *'[y/N]'*) ERRS+=('a question was asked without a LAN-test failure') ;; esac
  lacks_text 'LAN-test NAT rule'
  lacks_text 'LAN test failed'
}

# the offer is made at most once per session
t_nat_launch_once() {
  nl_case 2
  go
  rc_is 0
  [ "$(nat_q_count)" = 1 ] || ERRS+=("NAT question count: want 1 got $(nat_q_count)")
  [ "$(hint_count)" = 1 ] || ERRS+=("hint lines: want 1 got $(hint_count)")
}

# without sudo on PATH the block is printed and nothing is asked
t_nat_launch_no_sudo() {
  nl_case 1
  rm -f "$T/bin/sudo"
  go
  rc_is 0
  err_has 'sudo is not on PATH'
  case $ERR in *'Apply the LAN-test NAT rule now with sudo?'*) ERRS+=('asked the NAT question without sudo') ;; esac
  out_has "    sudo sh -c '"
  out_has 'W3Champions exited'
}

# ---------- report (quick 261009-wn4) ----------
# report cases read a host tree under $T/sys (W3C_SYS_ROOT) and the fake /proc; nothing is written, nothing leaves the machine.

# elf_stub FILE 64|32: the 20-byte header of a shared object, little endian, e_machine x86_64 (62) or i386 (3).
elf_stub() {
  mkdir -p "${1%/*}"
  if [ "$2" = 64 ]; then printf '\177ELF\002' > "$1"; else printf '\177ELF\001' > "$1"; fi
  printf '\001\001\000\000\000\000\000\000\000\000\000\003\000' >> "$1"
  if [ "$2" = 64 ]; then printf '\076\000' >> "$1"; else printf '\003\000' >> "$1"; fi
}

# rep_sys: the report-full host: distro, kernel, one DRM card and one connector, lspci and pacman shims, ICD manifests with ELF stubs
# (a 64-bit library sits in usr/lib32 as the wrong-arch trap), a 50-line wine.log, two launcher day logs and a recorded W3C build.
rep_sys() {
  local s=$T/sys i icd=$T/sys/usr/share/vulkan/icd.d
  mkdir -p "$s/etc/vulkan/icd.d" "$icd" "$s/sys/class/drm/card1/device" "$s/sys/class/drm/card1-DP-1" "$T/proc/sys/kernel" "$T/home/.cache/w3c-linux"
  printf 'NAME="Arch Linux"\nPRETTY_NAME="Arch Linux"\nID=arch\n' > "$s/etc/os-release"
  printf '7.2.9-arch1-1\n' > "$T/proc/sys/kernel/osrelease"
  printf '0x1002\n' > "$s/sys/class/drm/card1/device/vendor"
  printf '0x73df\n' > "$s/sys/class/drm/card1/device/device"
  ln -s ../../../../bus/pci/drivers/amdgpu "$s/sys/class/drm/card1/device/driver"
  cat > "$T/bin/lspci" <<'SH'
#!/bin/sh
echo '03:00.0 VGA compatible controller [0300]: Advanced Micro Devices, Inc. [AMD/ATI] Navi 22 [1002:73df]'
echo '00:1f.3 Audio device [0403]: Intel Corporation Device [8086:7a50]'
SH
  cat > "$T/bin/pacman" <<'SH'
#!/bin/sh
echo "$*" >> "$MARK/pacman"
[ "$*" = '-Q faugus-launcher' ] && { echo 'faugus-launcher 2.4.2-1'; exit 0; }
exit 1
SH
  chmod +x "$T/bin/lspci" "$T/bin/pacman"
  add_link "$T" tail
  printf '{"file_format_version": "1.0.0", "ICD": {"library_path": "/usr/lib/libvulkan_radeon.so"}}\n' > "$icd/radeon_icd.x86_64.json"
  printf '{"file_format_version": "1.0.0", "ICD": {"library_path": "/usr/lib32/libvulkan_radeon.so"}}\n' > "$icd/radeon_icd.i686.json"
  printf '{"file_format_version": "1.0.0", "ICD": {"library_path": "libGLX_nvidia.so.0"}}\n' > "$icd/nvidia_icd.json"
  printf 'not json\n' > "$s/etc/vulkan/icd.d/broken.json"
  for i in usr/lib/libvulkan_radeon.so usr/lib/libGLX_nvidia.so.0 usr/lib/libvulkan.so.1 usr/lib32/libGLX_nvidia.so.0; do elf_stub "$s/$i" 64; done
  for i in usr/lib32/libvulkan_radeon.so usr/lib32/libvulkan.so.1; do elf_stub "$s/$i" 32; done
  for i in $(seq 1 48); do printf 'wine line %d\n' "$i"; done > "$T/home/.cache/w3c-linux/wine.log"
  printf 'wine line 49 \033[31mred\033[0m\nwine line 50 %s/home/.cache/x\n' "$T" >> "$T/home/.cache/w3c-linux/wine.log"
  mkdir -p "$T/$LAN_DIR_REL"
  printf 'old day line\n' > "$T/$(day_file 2026-10-08)"
  printf 'new day line\n' > "$T/$(day_file 2026-10-09)"
  printf '%s\n' "$TAG" > "$T/home/.local/state/w3c-linux/proton-tag"
  CASE_ENV=("W3C_SYS_ROOT=$s")
}

# rep_val LABEL VALUE: out_has of one value line, as report prints it.
rep_val() { out_has "$(printf '%-10s %s' "$1" "$2")"; }

# rep_line LABEL VALUE: one whole line of OUT, as report prints it.
rep_line() { grep -qxF -- "$(printf '%-10s %s' "$1" "$2")" <<< "$OUT" || ERRS+=("report lacks the line: $1 $2"); }

# rep_run: runs report and asserts what holds for every case: exit 0, nothing written, no network, no ESC, every heading.
rep_run() {
  local FORBIDDEN=(wine wineserver sudo nft iptables notify-send faugus-launcher umu-run steam-runtime-launch-client pkill pgrep) h
  run "$T" report
  rc_is 0
  changed_is
  [ ! -e "$T/marks/curl" ] || ERRS+=('curl ran')
  case $OUT in *$'\033'*) ERRS+=('output holds an ESC byte') ;; esac
  for h in '## w3c-linux report' 'Review before pasting' '### System' '### Vulkan' '### Versions' '### wine.log' '### Launcher log'; do out_has "$h"; done
}

t_report_full() {
  rep_sys
  CASE_ENV+=("W3C_FAUGUS_PY_DIR=$T/nofaugus")   # no readable package, so the version comes from the pacman shim
  rep_run
  rep_line distro 'Arch Linux (arch)'
  rep_val kernel 7.2.9-arch1-1
  rep_val gpu '03:00.0 VGA compatible controller [0300]: Advanced Micro Devices, Inc. [AMD/ATI] Navi 22 [1002:73df]'
  rep_val gpu 'card1 0x1002:0x73df driver amdgpu'
  lacks_text card1-DP-1
  lacks_text 'Audio device'
  rep_val faugus 2.4.2
  [ "$(cat "$T/marks/pacman" 2> /dev/null)" = '-Q faugus-launcher' ] || ERRS+=("pacman calls: $(cat "$T/marks/pacman" 2> /dev/null)")
  rep_val umu 1.4.4-patch
  rep_val 'w3c build' "$TAG (recorded)"
  rep_val runner 'Proton-GE Latest'
  rep_val launcher 'installed 1.6.16, recorded 1.6.16'
  rep_val webview2 149.0.4022.98
  out_has '==> ~/.cache/w3c-linux/wine.log <=='
  out_has 'wine line 11'
  lacks_text 'wine line 10'
  out_has 'wine line 50 ~/.cache/x'
  out_has "==> ~/Faugus/battlenet/drive_c/users/steamuser/W3Champions/logs/w3champions.2026-10-09.log <=="
  out_has 'new day line'
  lacks_text 'old day line'
  lacks_text "$T"
  out_has '/etc/vulkan/icd.d/broken.json  unreadable'
  out_has '/usr/share/vulkan/icd.d/nvidia_icd.json  libGLX_nvidia.so.0  x86_64 /usr/lib/libGLX_nvidia.so.0  i686 missing'
  out_has '/usr/share/vulkan/icd.d/radeon_icd.i686.json  /usr/lib32/libvulkan_radeon.so  x86_64 missing  i686 /usr/lib32/libvulkan_radeon.so'
  out_has '/usr/share/vulkan/icd.d/radeon_icd.x86_64.json  /usr/lib/libvulkan_radeon.so  x86_64 /usr/lib/libvulkan_radeon.so  i686 missing'
  out_has 'loader libvulkan.so.1  x86_64 /usr/lib/libvulkan.so.1  i686 /usr/lib32/libvulkan.so.1'
  out_before '### System' '### Vulkan'
  out_before '### Vulkan' '### Versions'
}

t_report_bare() {
  CASE_ENV=("W3C_SYS_ROOT=$T/nosys" "W3C_FAUGUS_PY_DIR=$T/nofaugus")
  rep_run
  rep_line distro unknown
  rep_val kernel unknown
  rep_val gpu unknown
  rep_val faugus unknown
  rep_val 'w3c build' 'none recorded'
  out_has "$(printf '==> ~/.cache/w3c-linux/wine.log <==\n(absent)')"
  out_has "$(printf '==> ~/Faugus/battlenet/drive_c/users/steamuser/W3Champions/logs/w3champions.*.log <==\n(absent)')"
  out_has 'no ICD manifests in /etc/vulkan/icd.d or /usr/share/vulkan/icd.d'
  out_has 'loader libvulkan.so.1  x86_64 missing  i686 missing'
}

t_report_no_faugus() {
  local u='unknown (Battle.net prefix not found: run w3c-linux.sh doctor)'
  rm -f "$T/home/.local/share/faugus-launcher/games.json"
  rep_run
  rep_val faugus 2.4.2
  rep_val umu 1.4.4-patch
  rep_val runner "$u"
  rep_val launcher "$u"
  rep_val webview2 "$u"
  case ${OUT#*'### Launcher log'} in *'(Battle.net prefix not found: run w3c-linux.sh doctor)'*) ;; *) ERRS+=('launcher section lacks the prefix note') ;; esac
}

t_report_lines() {
  rep_sys
  CASE_ENV+=(W3C_REPORT_LINES=3)
  rep_run
  out_has 'last 3 lines'
  out_has 'wine line 48'
  lacks_text 'wine line 47'
}

t_report_vk_env() {
  rep_sys
  mkdir -p "$T/sys/opt/icd"
  printf '{"ICD": {"library_path": "/usr/lib/libvulkan_radeon.so"}}\n' > "$T/sys/opt/icd/custom.json"
  CASE_ENV+=("VK_DRIVER_FILES=$T/sys/opt/icd")
  rep_run
  out_has 'VK_DRIVER_FILES='
  out_has '(replaces the default ICD search)'
  out_has '/opt/icd/custom.json  /usr/lib/libvulkan_radeon.so  x86_64 /usr/lib/libvulkan_radeon.so  i686 missing'
}

t_report_static() {
  local b
  # shellcheck disable=SC2016 # the literal text of the script's line
  grep -qF '[ "${1-}" != report ] && banner' "${SOURCES[@]}" || ERRS+=('the banner gate does not exclude report')
  b=$(awk '/^(report_text|cmd_report)\(\) \{$/ { f = 1 } f; /^\}$/ { f = 0 }' "${SOURCES[@]}")
  [ -n "$b" ] || ERRS+=('report_text and cmd_report not found')
  ! grep -nE '\bC_[A-Z]+|(^|[^a-z_])(say|emit|banner)([^a-z_]|$)' <<< "$b" || ERRS+=('report code uses colours, say, emit or banner')
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
