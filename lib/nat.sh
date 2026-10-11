# shellcheck shell=bash
# NAT rule text, apply and offer. Used by install.

# nat_variant: nft when it is on PATH, else iptables, else none. Presence only; neither tool is ever run here and nothing overrides it.
nat_variant() {
  if type -P nft > /dev/null; then
    NAT_VARIANT=nft
  elif type -P iptables > /dev/null; then
    NAT_VARIANT=iptables
  else
    NAT_VARIANT=none
  fi
}

# nat_text VARIANT (pure): sets NAT_SCRIPT, the one string that is printed inside single quotes and handed to `sudo sh -c`, so the printed
# text is the executed text; and NAT_REMOVE, the removal lines. Built from literals only (no single quote, no user, env or log data).
# nft: add, delete, add makes a first apply succeed without the table and a second apply replace it, all in one nft -f - transaction.
# iptables: -C tests for the rule, so a second apply appends nothing.
nat_text() {
  local rule='-d 255.255.255.255 -p udp --dport 16000 -j DNAT --to-destination 127.0.0.1:16000'
  case $1 in
    nft)
      NAT_SCRIPT='printf "%s\n" "add table ip w3c" "delete table ip w3c" "add table ip w3c" "add chain ip w3c output { type nat hook output priority -100; policy accept; }" "add rule ip w3c output ip daddr 255.255.255.255 udp dport 16000 dnat to 127.0.0.1:16000" | nft -f -'
      NAT_REMOVE=('sudo nft delete table ip w3c') ;;
    iptables)
      NAT_SCRIPT="iptables -t nat -C OUTPUT $rule 2>/dev/null || iptables -t nat -A OUTPUT $rule"
      NAT_REMOVE=("sudo iptables -t nat -D OUTPUT $rule") ;;
  esac
}

# nat_persist_text: the printed-only persistence notes for NAT_VARIANT. Nothing here runs and nothing touches /etc.
nat_persist_text() {
  say 'To keep it after a reboot (optional, printed only; Arch file and service names UNVERIFIED):\n'
  case $NAT_VARIANT in
    nft)
      say 'Put the five statements (without the printf and nft -f - wrapper) in a root-owned file such as /etc/nftables.d/w3c.nft, include it from an /etc/nftables.conf you already use, then enable the service:\n'
      printf '    sudo systemctl enable nftables\n'
      say "Warning: Arch's stock /etc/nftables.conf is a default-drop input firewall; enabling nftables.service with it unchanged blocks inbound traffic, mDNS included.\n"
      say 'Without a password prompt, one sudoers line pinned to the exact command (check it with visudo -c; never allow sh -c or a file you can write):\n'
      printf '    <user> ALL=(root) NOPASSWD: /usr/bin/nft -f /etc/nftables.d/w3c.nft\n' ;;
    iptables)
      say 'iptables-save saves every active rule, not only this one: review the file before you rely on it.\n'
      printf "    sudo sh -c 'iptables-save > /etc/iptables/iptables.rules'\n"
      say 'Then enable iptables.service, which loads that file at boot:\n'
      printf '    sudo systemctl enable iptables\n'
      say 'Without a password prompt, one sudoers line pinned to the exact command (check it with visudo -c; never allow sh -c):\n'
      printf '    <user> ALL=(root) NOPASSWD: /usr/bin/iptables -t nat -A OUTPUT %s\n' "${NAT_SCRIPT##*|| iptables -t nat -A OUTPUT }" ;;
  esac
}

# nat_block: the NAT text for NAT_VARIANT on stdout. Prose goes through say; command lines through plain printf, so they paste unchanged.
# With neither tool (none) it shows the nft text and says what is missing.
nat_block() {
  local l
  say "LAN-test NAT rule (plan.md section 5 step 9): the launcher's LAN test needs UDP 16000 broadcasts redirected to 127.0.0.1; applying or checking it needs root, so w3c-linux never checks it:\n"
  printf "    sudo sh -c '%s'\n" "$NAT_SCRIPT"
  say 'Remove it with:\n'
  for l in "${NAT_REMOVE[@]}"; do printf '    %s\n' "$l"; done
  printf '    rm -f %q\n' "$NAT_MARK"
  say 'While the rule is active, real LAN games with other machines are not announced on the network (INFERRED).\n'
  case $NAT_VARIANT in
    none) say 'Neither nft nor iptables is installed: the rule needs nft or iptables (for example: sudo pacman -S nftables), then rerun.\n' ;;
    *) nat_persist_text ;;
  esac
}

# nat_marker_ok: the marker holds the current boot_id.
nat_marker_ok() {
  local b='' m=''
  [ -r "$PROC_DIR/sys/kernel/random/boot_id" ] && read -r b < "$PROC_DIR/sys/kernel/random/boot_id"
  [ -r "$NAT_MARK" ] && read -r m < "$NAT_MARK"
  [ -n "$b" ] && [ "$b" = "$m" ]
}

# nat_apply: the one sudo call. On a terminal it runs in the foreground so its password prompt is visible; without one it runs through
# sudo -A and the password dialog of lib/w3c-askpass.sh (SUDO_ASKPASS and W3C_ASKPASS_CMD are set here, never taken from the caller).
# Both run exactly NAT_SCRIPT. Always returns 0 and never retries.
# ponytail: a rule removed by hand leaves the marker stale until reboot; the printed removal deletes it, so only a manual removal is not seen.
nat_apply() {
  local rc b='' a=()
  if no_tty; then
    a=(-A)
    local -x SUDO_ASKPASS=$LIB_DIR/w3c-askpass.sh W3C_ASKPASS_CMD=${NAT_SCRIPT##*| }
  fi
  sudo "${a[@]}" sh -c "$NAT_SCRIPT"
  rc=$?
  if [ "$rc" != 0 ]; then
    say 'NAT rule not applied (sudo exit %s); run the command above in another terminal.\n' "$rc"
    return 0
  fi
  [ -r "$PROC_DIR/sys/kernel/random/boot_id" ] && read -r b < "$PROC_DIR/sys/kernel/random/boot_id"
  if [ -n "$b" ]; then
    write_state "$NAT_MARK" "$b" || say 'could not write the marker %s\n' "$NAT_MARK"
  fi
  say 'NAT rule applied; it lasts until reboot or the removal command above.\n'
  return 0
}

# nat_wait PROMPT: waits for one line; Enter, q and EOF all continue. Always returns 0.
nat_wait() {
  if use_zenity; then
    zenity --info --no-markup --title=w3c-linux --text="$1" 2> /dev/null
    return 0
  fi
  printf '%s (q skips): ' "$1" >&2
  read -r _ || true
  return 0
}

# nat_offer_desk: the offer without a terminal. The block was just logged; the question carries it too because the log is not on screen.
# No question runs sudo and no second dialog follows. Always returns 0.
nat_offer_desk() {
  local blk
  blk=$(nat_block)
  if ! type -P sudo > /dev/null; then
    say 'sudo is not on PATH: as root in another terminal, run the command above without its leading sudo\n'
    nat_wait "$blk"$'\n\n''sudo is not on PATH: as root in a terminal, run the command above without its leading sudo, then click OK.'
  elif ( ask "$blk"$'\n\n''Apply the LAN-test NAT rule now with sudo? You will be asked for your password.' N ); then
    nat_apply
  else
    say 'NAT rule not applied (declined); the command is above in this log.\n'
  fi
  return 0
}

# nat_offer: the block, then the question or the wait. The ask runs in a subshell so EOF counts as No. Always returns 0.
nat_offer() {
  nat_variant
  nat_text "${NAT_VARIANT/none/nft}"
  nat_block
  [ "$NAT_VARIANT" != none ] || return 0   # nothing could be applied here: no question, no wait
  if no_tty; then nat_offer_desk; return 0; fi
  if ! type -P sudo > /dev/null; then
    say 'sudo is not on PATH: as root in another terminal, run the command above without its leading sudo\n' >&2
    nat_wait 'then press Enter'
  elif ( ask 'Apply the LAN-test NAT rule now with sudo?' N ); then
    nat_apply
  else
    nat_wait 'Run it in another terminal, then press Enter'
  fi
  return 0
}
