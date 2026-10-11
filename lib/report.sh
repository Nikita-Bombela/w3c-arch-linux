# shellcheck shell=bash
# The report subcommand: the maintainer bug report and its Vulkan ICD lookup.

# py_icd ROOT: the Vulkan lines of report, one per ICD manifest plus the loader. Unlike the NUL-field py_* helpers it prints human report lines.
# Reads only (json.load and a 20-byte ELF header); the x86_64 or i686 of a library comes from its ELF e_machine, never from its directory.
py_icd() {
  python3 -I -B "$HELPER" icd "$1" 2> /dev/null
}

# report_text: the body of report. Read-only and offline: files and a few queries only, no latest.json, no Wine, no sudo.
report_text() {
  local n=${W3C_REPORT_LINES:-40} fo='```text' fc='```' nopfx='unknown (Battle.net prefix not found: run w3c-linux.sh doctor)'
  local d k l g=0 card v dev drv f t rec disp exe dir
  [[ $n =~ ^[0-9]+$ ]] || n=40
  { faugus_backend; check_derived; } > /dev/null
  printf '## w3c-linux report\n\n'
  printf 'Review before pasting: the launcher log can contain your BattleTag and account names. Paths under your home directory are shown as ~.\n\n'
  printf '### System\n%s\n' "$fo"
  d=$(sed -n '/^PRETTY_NAME=/{s///;p;q}' "$SYS_ROOT/etc/os-release" 2> /dev/null)
  d=${d#[\"\']}
  d=${d%[\"\']}
  printf '%-10s %s\n' distro "${d:-unknown}"
  k=''
  [ -r "$PROC_DIR/sys/kernel/osrelease" ] && { read -r k < "$PROC_DIR/sys/kernel/osrelease" || true; }
  printf '%-10s %s\n' kernel "${k:-unknown}"
  if type -P lspci > /dev/null; then
    while IFS= read -r l; do
      printf '%-10s %s\n' gpu "$l"
      g=1
    done < <(lspci -nn 2> /dev/null | grep -E 'VGA|3D|Display')
  fi
  for card in "$SYS_ROOT"/sys/class/drm/card*; do
    [ -r "$card/device/vendor" ] && [ -r "$card/device/device" ] || continue   # connectors such as card1-DP-1 have no device
    read -r v < "$card/device/vendor"
    read -r dev < "$card/device/device"
    drv=$(readlink "$card/device/driver" 2> /dev/null)
    drv=${drv##*/}
    printf '%-10s %s\n' gpu "${card##*/} $v:$dev driver ${drv:-unknown}"
    g=1
  done
  [ "$g" = 1 ] || printf '%-10s %s\n' gpu unknown
  printf '%s\n\n### Vulkan\n%s\n' "$fc" "$fo"
  py_icd "$SYS_ROOT" || printf 'needs python3\n'
  printf '%s\n\n### Versions\n%s\n' "$fc" "$fo"
  printf '%-10s %s\n' faugus "${FAUGUS_VERSION:-unknown}"
  printf '%-10s %s\n' umu "${UMU_VERSION:-unknown}"
  t=$(read_proton_tag)
  if [ -n "$t" ]; then t="$t (recorded)"; else t='none recorded'; fi
  printf '%-10s %s\n' 'w3c build' "$t"
  rec=$(read_launcher_version)
  if [ -n "$NEED_ENTRY" ]; then
    printf '%-10s %s\n' runner "$nopfx"
  else
    printf '%-10s %s\n' runner "$(runner_label "$BN_RUNNER")"
  fi
  if [ -z "$PREFIX" ]; then
    printf '%-10s %s\n' launcher "$nopfx" webview2 "$nopfx"
  else
    if [ -f "$W3C_EXE" ]; then
      disp=$(launcher_dispver "$PREFIX/system.reg")
      printf '%-10s %s\n' launcher "installed ${disp:-unknown}, recorded ${rec:-none}"
    else
      printf '%-10s %s\n' launcher "not installed (recorded ${rec:-none})"
    fi
    exe=$(wv2_find)
    if [ -n "$exe" ]; then
      t=$(wv2_version "$exe")
      printf '%-10s %s\n' webview2 "${t:-unknown}"
    else
      printf '%-10s %s\n' webview2 absent
    fi
  fi
  printf '%s\n\n### wine.log (last %s lines)\n%s\n==> %s <==\n' "$fc" "$n" "$fo" "$WINE_LOG"
  if [ -f "$WINE_LOG" ]; then printf '%s\n' "$(tail -n "$n" -- "$WINE_LOG")"; else printf '(absent)\n'; fi
  printf '%s\n\n### Launcher log (last %s lines)\n%s\n' "$fc" "$n" "$fo"
  if [ -z "$PREFIX" ]; then
    printf '(Battle.net prefix not found: run w3c-linux.sh doctor)\n'
  else
    dir=$PREFIX/drive_c/users/steamuser/W3Champions/logs f=''
    for l in "$dir"/w3champions.*.log; do [ -f "$l" ] && f=$l; done   # the UTC date is in the name, so glob order is date order
    if [ -n "$f" ]; then
      printf '==> %s <==\n%s\n' "$f" "$(tail -n "$n" -- "$f")"
    else
      printf '==> %s/w3champions.*.log <==\n(absent)\n' "$dir"
    fi
  fi
  printf '%s\n' "$fc"
}

# report: Markdown for a bug report, always exit 0 (it is most needed when things are broken). $HOME shows as ~ and ESC bytes are removed, so no
# ANSI or terminal sequence from a log reaches the output. Redaction covers paths and log text; account names in the launcher log are not
# redacted, hence the review note in the header.
cmd_report() {
  local r h
  r=$(report_text)
  for h in "$(realpath -m -- "$HOME")" "$HOME"; do   # the realpath first, so a symlinked home is not half replaced
    [ "${#h}" -gt 1 ] && r=${r//"$h"/'~'}
  done
  printf '%s\n' "${r//$'\033'/}"
}
