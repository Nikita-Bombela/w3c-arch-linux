# shellcheck shell=bash disable=SC2034
# Why SC2034 is off: NAT_STATE is read by install, launch, steam-wrap and doctor, which shellcheck cannot see when it checks this file alone.
# NAT rule text, apply and offer. Used by install.

# The oneshot unit the printed recipe installs. Users copy this name into /etc by hand and Phase 22 D-02 checks it, so a rename is costly:
# every persisted user's unit would stop counting as applied until they reinstall it.
NAT_UNIT=w3c-nat.service

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

# nat_unit_exec (pure): NAT_SCRIPT escaped for a systemd ExecStart word, on stdout. systemd.service(5) expands % specifiers, $ variables and C
# escapes inside ExecStart (measured on systemd 262: an unescaped %s became the user shell), so every backslash, then every %, then every $ is
# doubled (that order, so a later doubling never re-escapes an earlier one) and the shell systemd starts receives exactly NAT_SCRIPT.
# NAT_SCRIPT holds no single quote, so the single-quoted ExecStart word is safe.
nat_unit_exec() {
  local s=$NAT_SCRIPT
  s=${s//\\/\\\\}
  s=${s//'%'/%%}
  s=${s//\$/\$\$}
  printf '%s' "$s"
}

# nat_remove_lines: the removal command lines, four-space indented: the variant's (NAT_REMOVE), the marker's, then the two lines that undo
# the printed unit (Phase 22 D-04). Printed only.
nat_remove_lines() {
  local l
  for l in "${NAT_REMOVE[@]}"; do printf '    %s\n' "$l"; done
  printf '    rm -f %q\n' "$NAT_MARK"
  say 'If you installed %s, also:\n' "$NAT_UNIT"
  printf '    sudo systemctl disable --now %s\n' "$NAT_UNIT"
  printf '    sudo rm /etc/systemd/system/%s\n' "$NAT_UNIT"
}

# nat_revert_note: D-04: revert points at the NAT block's removal lines (same variant pick, same text), printed only. It never touches the rule or the
# unit, and it prints on every full revert because revert cannot read the ruleset (D-02).
nat_revert_note() {
  nat_variant
  nat_text "${NAT_VARIANT/none/nft}"
  say 'revert leaves the LAN-test NAT rule alone; if you applied or persisted it, remove it with:\n'
  nat_remove_lines
}

# nat_persist_text: the printed-only persistence recipe: one oneshot unit whose ExecStart runs the same NAT_SCRIPT as the apply line, for every
# family and both variants (Phase 22 D-01), then the one warning of the detected family (D-07). Nothing here runs and nothing touches /etc.
# The unit and the heredoc print flush-left, so the pasted block is the file; only the enable line is a four-space command line. No sudoers
# line (D-03), no include-file recipe and no whole-ruleset save: the unit never flushes anything but its own table.
# The status strings live only in the case below: a rig run that checks a family flips its line (D-07, e.g. "checked on Linux Mint 22").
nat_persist_text() {
  local st w
  case $DISTRO_FAMILY in
    arch)
      st='checked on Arch Linux'
      w='Arch: do not enable nftables.service for this: the stock /etc/nftables.conf is a default-drop input firewall and blocks inbound traffic, mDNS included.' ;;
    fedora)
      st='UNVERIFIED on Fedora and Bazzite'
      w="Fedora and Bazzite: never enable nftables.service next to firewalld: stopping or reloading it flushes the whole ruleset (/etc/sysconfig/nftables.conf), firewalld's tables included." ;;
    debian)
      st='UNVERIFIED on Debian, Ubuntu and Linux Mint'
      w="Debian, Ubuntu and Mint: do not enable nftables.service for this: the stock /etc/nftables.conf begins with flush ruleset, which wipes this rule and every other firewall's rules at boot." ;;
    *)
      st='UNVERIFIED: distro family unknown'
      w='Do not enable a distro nftables.service whose config starts with flush ruleset next to another firewall.' ;;
  esac
  say 'To keep it after a reboot (optional, printed only; %s): a oneshot %s runs the same command at boot. Paste this block into a terminal:\n' "$st" "$NAT_UNIT"
  printf "sudo tee /etc/systemd/system/%s <<'EOF'\n" "$NAT_UNIT"
  printf '%s\n' '[Unit]' 'Description=w3c-linux LAN-test NAT rule' 'After=network-pre.target firewalld.service ufw.service' \
    '[Service]' 'Type=oneshot' 'RemainAfterExit=yes'
  printf "ExecStart=/bin/sh -c '%s'\n" "$(nat_unit_exec)"
  printf '%s\n' '[Install]' 'WantedBy=multi-user.target' 'EOF'
  printf '    sudo systemctl enable --now %s\n' "$NAT_UNIT"
  say '%s\n' "$w"
}

# nat_block: the NAT text for NAT_VARIANT on stdout. Prose goes through say; command lines through plain printf, so they paste unchanged.
# With neither tool (none) it shows the nft text and says what is missing.
nat_block() {
  say "LAN-test NAT rule (plan.md section 5 step 9): the launcher's LAN test needs UDP 16000 broadcasts redirected to 127.0.0.1; applying or checking it needs root, so w3c-linux never checks it:\n"
  printf "    sudo sh -c '%s'\n" "$NAT_SCRIPT"
  say 'Remove it with:\n'
  nat_remove_lines
  say 'While the rule is active, real LAN games with other machines are not announced on the network (INFERRED).\n'
  case $NAT_VARIANT in
    none) say 'Neither nft nor iptables is installed: the rule needs nft or iptables (for example: %s), then rerun.\n' "$(install_hint nft)" ;;
    *) nat_persist_text ;;
  esac
}

# nat_marker_ok: the rule counts as applied. Sets NAT_STATE: marker (the marker holds the current boot_id, checked first and with no other
# probe), unit (an active w3c-nat.service, Phase 22 D-02) or empty. The ruleset itself is never read (that needs root): an active oneshot with
# RemainAfterExit=yes means it ran at boot and was not stopped, which says nothing about a rule removed by hand since.
nat_marker_ok() {
  local b='' m=''
  NAT_STATE=''
  [ -r "$PROC_DIR/sys/kernel/random/boot_id" ] && read -r b < "$PROC_DIR/sys/kernel/random/boot_id"
  [ -r "$NAT_MARK" ] && read -r m < "$NAT_MARK"
  if [ -n "$b" ] && [ "$b" = "$m" ]; then
    NAT_STATE=marker
    return 0
  fi
  if type -P systemctl > /dev/null && timeout 2 systemctl is-active --quiet "$NAT_UNIT" 2> /dev/null; then
    NAT_STATE=unit
    return 0
  fi
  return 1
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
