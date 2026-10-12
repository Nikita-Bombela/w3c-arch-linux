#!/usr/bin/env bash
# Phase 3 fixture check: runs the real w3c-linux.sh under env -i against a fake HOME per case, on the harness of tests/phase2.sh.
# mk_tree there provisions every Phase 3 step; a case here takes one piece away (no_launcher) and lets the umu-run shim play Wine's
# file effects through T/fix/on-umu.sh. No case runs a real Wine, umu or network call.
# Usage: bash tests/phase3.sh [GLOB]   (GLOB filters on display names such as msi-fresh)
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=phase2.sh
source "$(dirname "${BASH_SOURCE[0]}")/phase2.sh"

# this suite has its own cases only
mapfile -t P2_CASES < <(compgen -A function t_)
unset -f "${P2_CASES[@]}"

# umu-run and pkill are expected here; the rest must never run
FORBIDDEN=(wine wineserver faugus-launcher steam-runtime-launch-client sudo nft iptables notify-send)

# ---------- helpers ----------

# on_w3c T: the state after the Proton step: the build present and recorded, Battle.net on it.
on_w3c() {
  mk_installed "$1"
  seed_tag "$1" "$TAG"
  bn_set4 "$1" runner "$TAG"
}

# no_launcher T: the launcher is not installed: no exe, no record, no W3Champions Uninstall entry.
no_launcher() {
  local p=$1/home/Faugus/battlenet
  rm -f "$p/drive_c/Program Files/W3Champions/W3Champions.exe" "$1/home/.local/state/w3c-linux/launcher-version"
  sed -i -e '/6C2A7B21/d' -e '/^"DisplayName"="W3Champions"$/d' -e '/^"DisplayVersion"="1.6.16"$/d' "$p/system.reg"
}

# umu_hook T TEXT: what the umu-run shim sources when it runs (the file effects of Wine).
umu_hook() { printf '%s\n' "$2" > "$1/fix/on-umu.sh"; }

# zpath P: the Wine path of a host path, written independently of the script.
zpath() { printf 'Z:%s' "${1//\//\\}"; }

# umu_count N: umu-run ran exactly N times.
umu_count() {
  local n=0
  [ ! -f "$T/marks/umu-run" ] || n=$(wc -l < "$T/marks/umu-run")
  [ "$n" = "$1" ] || ERRS+=("umu-run calls: want $1 got $n")
}

# umu_env_has KV: umu-run's environment holds exactly the line KV. umu_env_lacks REGEX: no line of it matches.
umu_env_has() { grep -qxF -- "$1" "$T/marks/umu-run.env" 2> /dev/null || ERRS+=("umu env lacks: $1"); }
umu_env_lacks() { ! grep -q -- "$1" "$T/marks/umu-run.env" 2> /dev/null || ERRS+=("umu env has a line matching: $1"); }

# launcher_rec: the recorded launcher version, or nothing.
launcher_rec() { cat "$T/home/.local/state/w3c-linux/launcher-version" 2> /dev/null; }

# no_umu: umu-run never ran.
no_umu() { [ ! -e "$T/marks/umu-run" ] || ERRS+=('umu-run ran'); }

# what the msiexec call does inside the prefix: the exe and the Uninstall entry (a hook line `exit N` may follow)
IFS= read -r -d '' MSI_HOOK <<'SH' || true
if [ "$1" = msiexec ]; then
  d="$WINEPREFIX/drive_c/Program Files/W3Champions"
  mkdir -p "$d"
  : > "$d/W3Champions.exe"
  printf '%s\n' '' '[Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{6C2A7B21-0000-4000-8000-000000000001}] 1700000000' \
    '"DisplayName"="W3Champions"' '"DisplayVersion"="1.6.16"' >> "$WINEPREFIX/system.reg"
fi
SH

# msi_setup: the tracer's start state: Battle.net on the W3C build, no launcher, a hook that installs it, the two prefix paths the hook writes allowed.
msi_setup() {
  mk_release "$T"
  on_w3c "$T"
  no_launcher "$T"
  umu_hook "$T" "$MSI_HOOK"$'\n'"${1:-}"
  ALLOW_EXTRA+=(home/Faugus/battlenet/system.reg 'home/Faugus/battlenet/drive_c/Program Files/W3Champions/W3Champions.exe')
}

# lingering_wineserver: a wineserver of this prefix appears when umu-run runs (the hook adds its process line to fix/procs).
lingering_wineserver() {
  local name
  name=$(prefix_server_name "$T")
  mkdir -p "$T/wine-tmp/$name" "$T/proc/4343"
  ln -s "$T/wine-tmp/$name" "$T/proc/4343/cwd"
  umu_hook "$T" "$MSI_HOOK
echo '4343|wineserver|/usr/bin/wineserver -p' >> \"\$FIX/procs\""
  ALLOW_EXTRA+=(fix/procs)
}

# sleep_shim T BODY: replaces the linked sleep (never written through the link) with a shim that logs, then runs BODY.
sleep_shim() {
  rm -f "$1/bin/sleep"
  # shellcheck disable=SC2016 # the shim body is written literally and expanded when the shim runs
  printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$0 $*" >> "$MARK/sleep"' "$2" > "$1/bin/sleep"
  chmod +x "$1/bin/sleep"
}

# ---------- cases ----------

# The tracer: install on a W3C-runner tree takes the launcher from latest.json to the recorded version.
t_msi_fresh() {
  local msi=$T/home/.cache/w3c-linux/launcher/W3Champions_1.6.16_x64_en-US.msi
  msi_setup
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 0
  err_has 'Install W3Champions 1.6.16 (latest)? [Y/n]'
  umu_count 1
  case $(cat "$T/marks/umu-run" 2> /dev/null) in
    *" msiexec /i $(zpath "$msi") /qn") ;;
    *) ERRS+=("umu-run argv is not msiexec /i $(zpath "$msi") /qn: $(cat "$T/marks/umu-run" 2> /dev/null)") ;;
  esac
  umu_env_has PROTON_VERB=run
  umu_env_has "WINEPREFIX=$(realpath "$T/home/Faugus/battlenet")"
  umu_env_has "PROTONPATH=$T/home/.local/share/Steam/compatibilitytools.d/$TAG"
  umu_env_has WINE_SIMULATE_WRITECOPY=1
  umu_env_has PROTON_ENABLE_WAYLAND=0
  [ "$(launcher_rec)" = 1.6.16 ] || ERRS+=("launcher-version holds: $(launcher_rec)")
  [ ! -e "$msi" ] || ERRS+=('the MSI is still in the cache')
  out_has "Install complete: Battle.net runs on $TAG"
  grep -qF 'launcher-e-release/releases/latest/download/latest.json' "$T/marks/curl" || ERRS+=('latest.json was not fetched')
  grep -qF 'https://update-service.w3champions.com/api/launcher-e' "$T/marks/curl" || ERRS+=('the launcher MSI was not fetched')
}

# Inherited umu variables never reach Wine; the wrapper's verb is run.
t_pfx_env_contract() {
  msi_setup
  CASE_ENV=(GAMEID=x STORE=y FAUGUSID=z UMU_USE_STEAM=1 UMU_CONTAINER_NSENTER=1)
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 0
  umu_count 1
  umu_env_has PROTON_VERB=run
  umu_env_lacks '^GAMEID='
  umu_env_lacks '^STORE='
  umu_env_lacks '^FAUGUSID='
  umu_env_lacks '^UMU_USE_STEAM='
  umu_env_lacks '^UMU_CONTAINER_NSENTER='
}

# Faugus toggles, launch_arguments, envar.json, then the wrapper's three variables: later wins, ours last.
t_pfx_env_order() {
  msi_setup
  printf '%s\n' '{"wayland-driver": "False", "wow64-enabled": "False", "discrete-gpu": "True"}' > "$T/home/.config/faugus-launcher/config.json"
  printf '%s\n' '["WINE_SIMULATE_WRITECOPY=7"]' > "$T/home/.config/faugus-launcher/envar.json"
  bn_set4 "$T" launch_arguments 'WINE_SIMULATE_WRITECOPY=1 PROTON_ENABLE_WAYLAND=0 WINEPREFIX=/evil PROTONPATH=/evil PROTON_VERB=waitforexitandrun'
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 0
  umu_count 1
  umu_env_has DRI_PRIME=1
  umu_env_has WINE_SIMULATE_WRITECOPY=7
  umu_env_has PROTON_ENABLE_WAYLAND=0
  umu_env_has "WINEPREFIX=$(realpath "$T/home/Faugus/battlenet")"
  umu_env_has "PROTONPATH=$T/home/.local/share/Steam/compatibilitytools.d/$TAG"
  umu_env_has PROTON_VERB=run
  umu_env_lacks '/evil'
  umu_env_lacks 'waitforexitandrun'
}

# run_fifo to the launcher prompt, so the case can change the tree while install waits at it.
to_launcher_prompt() {
  ALLOW_EXTRA+=(orig-games.json)
  run_fifo "$T" install
  send $'y\n'
  wait_err 'Install W3Champions 1.6.16 (latest)?'
}

# The runner is read when the command runs, not when install started.
t_pfx_refuse_runner_changed() {
  msi_setup
  to_launcher_prompt
  bn_set4 "$T" runner 'Proton-GE Latest'
  send $'y\n'
  finish
  rc_is 1
  out_has 'in-prefix step refused: Battle.net runs on Proton-GE Latest'
  no_umu
  [ -z "$(launcher_rec)" ] || ERRS+=('launcher-version was written')
}

t_pfx_refuse_runner_incomplete() {
  msi_setup
  to_launcher_prompt
  rm -rf "$T/home/.local/share/Steam/compatibilitytools.d/$TAG/files"
  send $'y\n'
  finish
  rc_is 1
  out_has 'in-prefix step refused: Battle.net runs on'
  no_umu
  [ -z "$(launcher_rec)" ] || ERRS+=('launcher-version was written')
}

# Battle.net starts after the wait's idle check passed, so only run_in_prefix's own check sees it (the late pgrep seam).
t_pfx_refuse_busy() {
  msi_setup
  printf '%s\n' '4242|Battle.net.exe|C:\Program Files (x86)\Battle.net\Battle.net.exe' > "$T/fix/procs.late"
  printf '1\n' > "$T/fix/late-after"
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 1
  err_has $'Still running:\n\n    Battle.net'
  out_has 'in-prefix step refused: something is still running'
  no_umu
}

# The prefix's own wineserver outlives msiexec; install waits for it with sleep and then reads the files.
t_pfx_settle_waits() {
  msi_setup
  lingering_wineserver
  # shellcheck disable=SC2016 # the shim body expands when the shim runs
  sleep_shim "$T" ': > "$FIX/procs"'
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 0
  [ -f "$T/marks/sleep" ] || ERRS+=('install never slept while the wineserver lingered')
  [ "$(launcher_rec)" = 1.6.16 ] || ERRS+=("launcher-version holds: $(launcher_rec)")
}

t_pfx_settle_timeout() {
  msi_setup
  lingering_wineserver
  sleep_shim "$T" ':'
  CASE_ENV=(W3C_SETTLE_SECS=2)
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 1
  out_has 'is still running 2 s after msiexec'
  [ -z "$(launcher_rec)" ] || ERRS+=('launcher-version was written')
}

# umu-run's exit status is informative only: the files decide (D-04).
t_pfx_rc_ignored() {
  msi_setup 'exit 3'
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 0
  umu_count 1
  [ "$(launcher_rec)" = 1.6.16 ] || ERRS+=("launcher-version holds: $(launcher_rec)")
}

# umu and Proton output goes to the Wine log, not the terminal; one line says the step is working.
t_pfx_quiet_log() {
  local log=$T/home/.cache/w3c-linux/wine.log
  msi_setup 'echo PROTON-CHATTER; echo PROTON-ERR >&2'
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 0
  out_has "Running msiexec in the Battle.net prefix; this can take a few minutes and prints nothing until it is done (Wine output: $log)"
  case $OUT$ERR in *PROTON-*) ERRS+=('umu-run output reached the terminal') ;; esac
  grep -q PROTON-CHATTER "$log" && grep -q PROTON-ERR "$log" || ERRS+=('umu-run output is not in the Wine log')
}

# Version truth is the highest W3Champions Uninstall DisplayVersion in either view; other names and malformed values never count.
t_msi_dispver_highest() {
  mk_release "$T"
  on_w3c "$T"
  printf '%s\n' '' '[Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{OLD}] 1700000000' \
    '"DisplayName"="W3Champions"' '"DisplayVersion"="1.6.9"' \
    '' '[Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{BAD}] 1700000000' '"DisplayName"="W3Champions"' '"DisplayVersion"="../x"' \
    '' '[Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{OTHER}] 1700000000' '"DisplayName"="Other"' '"DisplayVersion"="9.9.9"' \
    >> "$T/home/Faugus/battlenet/system.reg"
  FEED=$'y\n'
  run "$T" install
  rc_is 0
  out_has 'W3Champions 1.6.16 is in its prefix'
  no_umu
}

# ---------- D-01 batch ----------

BN_LINE='4242|Battle.net.exe|C:\Program Files (x86)\Battle.net\Battle.net.exe'

# batch_setup: Battle.net still on Proton-GE Latest, the W3C build installed and recorded, no launcher, the MSI hook in place.
batch_setup() {
  msi_setup
  bn_set4 "$T" runner 'Proton-GE Latest'
}

t_batch_switch_then_msi() {
  batch_setup
  FEED=$'y\ny\ny\n'
  run "$T" install
  rc_is 0
  err_has "Switch Faugus's Battle.net runner to $TAG?"
  err_has 'Install W3Champions 1.6.16 (latest)? [Y/n]'
  out_has 'Battle.net runner switched'
  umu_count 1
  case $(cat "$T/marks/umu-run.env" 2> /dev/null) in
    *"PROTONPATH=$T/home/.local/share/Steam/compatibilitytools.d/$TAG"*) ;;
    *) ERRS+=('umu-run did not run on the W3C build') ;;
  esac
  [ "$(launcher_rec)" = 1.6.16 ] || ERRS+=("launcher-version holds: $(launcher_rec)")
  out_has "Install complete: Battle.net runs on $TAG"
}

# Every question is asked before the wait; the installer is downloaded before it; nothing is written when the wait ends.
t_batch_prompts_before_wait() {
  batch_setup
  printf '%s\n' "$BN_LINE" > "$T/fix/procs"
  FEED=$'y\ny\ny\n'
  run "$T" install
  rc_is 1
  case $ERR in
    *'Install W3Champions'*'Still running:'*) ;;
    *) ERRS+=('the launcher prompt does not come before the wait') ;;
  esac
  [ -f "$T/home/.cache/w3c-linux/launcher/W3Champions_1.6.16_x64_en-US.msi" ] || ERRS+=('the MSI was not downloaded before the wait')
  unchanged_games
  no_umu
}

t_batch_decline_switch() {
  batch_setup
  FEED=$'y\nn\n'
  run "$T" install
  rc_is 0
  out_has 'Battle.net runner not switched; rerun install when ready.'
  out_has 'run only on the W3C build'
  case $ERR in *'Install W3Champions'*) ERRS+=('the launcher prompt was asked') ;; esac
  ! grep -qF '/api/launcher-e' "$T/marks/curl" || ERRS+=('an installer was downloaded')
  no_umu
  unchanged_games
}

t_batch_decline_msi() {
  msi_setup
  FEED=$'y\nn\n'
  run "$T" install
  rc_is 0
  ! grep -qF '/api/launcher-e' "$T/marks/curl" || ERRS+=('the MSI was downloaded')
  [ ! -e "$T/marks/pgrep" ] || ERRS+=('install waited for idle although nothing was chosen')
  out_has 'Not done yet'
  out_has 'W3Champions launcher'
  no_umu
}

# One wait for the whole run: the list is printed once and the steps follow without another question.
t_batch_single_wait() {
  local n
  batch_setup
  ALLOW_EXTRA+=(fix/procs)
  printf '%s\n' "$BN_LINE" > "$T/fix/procs"
  run_fifo "$T" install
  send $'y\ny\ny\n'
  wait_err 'press Enter to check again'
  : > "$T/fix/procs"
  send $'\n'
  finish
  rc_is 0
  n=$(grep -c 'Still running:' <<< "$ERR")
  [ "$n" = 1 ] || ERRS+=("want the list once, got $n")
  umu_count 1
  out_has 'Battle.net runner switched'
}

# ---------- WebView2 (PFX-02) ----------

# no_wv2 T: the prefix has no WebView2 runtime. wv2_at T DIRNAME: msedgewebview2.exe under Application/DIRNAME.
no_wv2() { rm -rf "$1/home/Faugus/battlenet/drive_c/Program Files (x86)/Microsoft/EdgeWebView"; }
wv2_at() {
  local d="$1/home/Faugus/battlenet/drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application/$2"
  mkdir -p "$d"
  : > "$d/msedgewebview2.exe"
}

WV2_INSTALLER=MicrosoftEdgeWebView2RuntimeInstallerX64.exe
# what the WebView2 installer does inside the prefix
IFS= read -r -d '' WV2_HOOK <<'SH' || true
case $1 in
  *MicrosoftEdgeWebView2RuntimeInstallerX64.exe)
    d="$WINEPREFIX/drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application/149.0.4022.98"
    mkdir -p "$d"
    : > "$d/msedgewebview2.exe"
    ;;
esac
SH
WV2_ALLOW=('home/Faugus/battlenet/drive_c/Program Files (x86)/Microsoft/EdgeWebView' 'home/Faugus/battlenet/drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application'
  'home/Faugus/battlenet/drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application/149.0.4022.98'
  'home/Faugus/battlenet/drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application/149.0.4022.98/msedgewebview2.exe')

# wv2_setup: on the W3C runner, launcher present, WebView2 absent, a hook that installs it.
wv2_setup() {
  mk_release "$T"
  on_w3c "$T"
  no_wv2 "$T"
  umu_hook "$T" "$WV2_HOOK"$'\n'"${1:-}"
  ALLOW_EXTRA+=("${WV2_ALLOW[@]}")
}

t_wv2_present_skip() {
  mk_release "$T"
  on_w3c "$T"
  FEED=$'y\n'
  run "$T" install
  rc_is 0
  case $ERR in *'Install Microsoft Edge WebView2'*) ERRS+=('prompt 5 was asked') ;; esac
  ! grep -qF 'go.microsoft.com' "$T/marks/curl" || ERRS+=('the WebView2 installer was downloaded')
  no_umu
  out_has 'WebView2 runtime 149.0.4022.98 already in the prefix'
}

t_wv2_install() {
  local inst=$T/home/.cache/w3c-linux/webview2/$WV2_INSTALLER
  wv2_setup
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 0
  err_has 'Install Microsoft Edge WebView2 runtime into the prefix? [Y/n]'
  umu_count 1
  case $(cat "$T/marks/umu-run" 2> /dev/null) in
    *" $(zpath "$inst") /silent /install") ;;
    *) ERRS+=("umu-run argv is not $(zpath "$inst") /silent /install: $(cat "$T/marks/umu-run" 2> /dev/null)") ;;
  esac
  case $(cat "$T/marks/pkill" 2> /dev/null) in
    *" -u $(id -u) -f MicrosoftEdgeUpdate\\.exe") ;;
    *) ERRS+=("pkill argv is not -u $(id -u) -f MicrosoftEdgeUpdate\\.exe: $(cat "$T/marks/pkill" 2> /dev/null)") ;;
  esac
  [ "$(wc -l < "$T/marks/pkill")" = 1 ] || ERRS+=('pkill ran more than once')
  out_has 'Installed WebView2 runtime 149.0.4022.98'
  out_has "pkill -u $(id -u) -f 'MicrosoftEdgeUpdate\\.exe'"
  [ ! -e "$inst" ] || ERRS+=('the installer is still in the cache')
  out_has "Install complete: Battle.net runs on $TAG"
}

# 109.x and 144.x are in the working range; 110.x and 143.x only warn.
t_wv2_range() {
  local v want
  for v in 109.0.1518.78:no 110.0.1587.41:yes 143.0.3650.75:yes 144.0.3719.82:no; do
    rm -f "$T/marks/umu-run"
    mk_release "$T"
    on_w3c "$T"
    no_wv2 "$T"
    wv2_at "$T" "${v%%:*}"
    FEED=$'y\n'
    run "$T" install
    rc_is 0
    want=${v##*:}
    case $OUT in
      *'warn  webview2'*) [ "$want" = yes ] || ERRS+=("${v%%:*}: unexpected webview2 warn row") ;;
      *) [ "$want" = no ] || ERRS+=("${v%%:*}: no webview2 warn row") ;;
    esac
    [ "$want" = no ] || out_has '110 to 143'
  done
}

t_wv2_unknown_version() {
  local reg=$T/home/Faugus/battlenet/system.reg
  mk_release "$T"
  on_w3c "$T"
  no_wv2 "$T"
  wv2_at "$T" current
  FEED=$'y\n'
  run "$T" install
  rc_is 0
  out_has 'WebView2 runtime unknown already in the prefix'
  out_has 'version unknown'
  printf '%s\n' '' '[Software\\Wow6432Node\\Microsoft\\EdgeUpdate\\Clients\\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}] 1700000000' \
    '"pv"="150.0.3800.10"' >> "$reg"
  ALLOW_EXTRA+=(home/Faugus/battlenet/system.reg)
  run "$T" install
  rc_is 0
  out_has 'WebView2 runtime 150.0.3800.10 already in the prefix'
  case $OUT in *'version unknown'*) ERRS+=('a pv version still reports unknown') ;; esac
}

t_wv2_two_installs() {
  mk_release "$T"
  on_w3c "$T"
  wv2_at "$T" 143.0.3650.75
  FEED=$'y\n'
  run "$T" install
  rc_is 0
  case $ERR in *'Install Microsoft Edge WebView2'*) ERRS+=('prompt 5 was asked') ;; esac
  no_umu
}

# wv2_failed_run: the installer leaves nothing, the launcher is missing too; install stops at the WebView2 step.
wv2_failed_run() {
  mk_release "$T"
  on_w3c "$T"
  no_wv2 "$T"
  no_launcher "$T"
  umu_hook "$T" ':'
  ALLOW_EXTRA+=(home/Faugus/battlenet/system.reg)
  FEED=$'y\ny\ny\n'
  run "$T" install
}

# install stops before the launcher step (msiexec never ran) and keeps the installer for diagnosis.
t_wv2_fail_stops() {
  wv2_failed_run
  rc_is 1
  out_has 'WebView2 step failed: msedgewebview2.exe not found under'
  umu_count 1
  [ -f "$T/home/.cache/w3c-linux/webview2/$WV2_INSTALLER" ] || ERRS+=('the installer was not kept for diagnosis')
  [ -z "$(launcher_rec)" ] || ERRS+=('launcher-version was written')
}

# the rerun asks prompt 5 again and continues where it stopped
t_wv2_resume() {
  wv2_failed_run
  rc_is 1
  umu_hook "$T" "$WV2_HOOK"$'\n'"$MSI_HOOK"
  ALLOW_EXTRA+=("${WV2_ALLOW[@]}" 'home/Faugus/battlenet/drive_c/Program Files/W3Champions/W3Champions.exe')
  rm -f "$T/marks/umu-run" "$T/marks/umu-run.env"
  FEED=$'y\ny\ny\n'
  run "$T" install
  rc_is 0
  err_has 'Install Microsoft Edge WebView2 runtime into the prefix? [Y/n]'
  umu_count 2
  out_has 'Install complete'
}

# ---------- registry (PFX-03) ----------

# reg_drop T KEY: removes one value line from user.reg. reg_set_build T N: rewrites CurrentBuild in system.reg.
reg_drop() { sed -i "/^\"$2\"=/d" "$1/home/Faugus/battlenet/user.reg"; }
reg_set_build() { sed -i "s/^\"CurrentBuild\"=.*/\"CurrentBuild\"=\"$2\"/" "$1/home/Faugus/battlenet/system.reg"; }

# user_reg T HEADER [VER]: user.reg with the Allow Local Files value under HEADER and the WebView2 default VER (default win7).
user_reg() {
  printf '%s\n' 'WINE REGISTRY Version 2' '' "$2 1700000000" '"Allow Local Files"=dword:00000001' '' \
    '[Software\\Wine\\AppDefaults\\msedgewebview2.exe] 1700000000' "\"Version\"=\"${3:-win7}\"" '' > "$1/home/Faugus/battlenet/user.reg"
}

# what regedit and winecfg do inside the prefix: regedit copies the file it was given to marks and writes user.reg from it, winecfg sets build 19045
IFS= read -r -d '' REG_HOOK <<'SH' || true
case $1 in
  regedit)
    cp "$HOME/.cache/w3c-linux/w3c.reg" "$MARK/w3c.reg"
    ver=$(sed -n 's/^"Version"="\(.*\)"$/\1/p' "$MARK/w3c.reg")
    printf '%s\n' 'WINE REGISTRY Version 2' '' '[Software\\Blizzard Entertainment\\Warcraft III] 1700000000' '"Allow Local Files"=dword:00000001' '' \
      '[Software\\Wine\\AppDefaults\\msedgewebview2.exe] 1700000000' "\"Version\"=\"$ver\"" '' > "$WINEPREFIX/user.reg"
    ;;
  winecfg)
    sed -i 's/^"CurrentBuild"="[0-9]*"$/"CurrentBuild"="19045"/' "$WINEPREFIX/system.reg"
    ;;
esac
SH
REG_ALLOW=(home/Faugus/battlenet/user.reg home/Faugus/battlenet/system.reg)

# reg_setup: on the W3C runner, everything but the registry provisioned, the Allow Local Files value missing, a hook that applies the registry.
reg_setup() {
  mk_release "$T"
  on_w3c "$T"
  reg_drop "$T" 'Allow Local Files'
  umu_hook "$T" "$REG_HOOK"$'\n'"${1:-}"
  ALLOW_EXTRA+=("${REG_ALLOW[@]}")
}

# reg_applied VER: umu-run got regedit /S <w3c.reg> then winecfg -v win10, regedit read exactly the 7 expected lines, the cache file is gone.
reg_applied() {
  local l1 l2
  umu_count 2
  { read -r l1; read -r l2; } < "$T/marks/umu-run"
  case $l1 in *" regedit /S $(zpath "$T/home/.cache/w3c-linux/w3c.reg")") ;; *) ERRS+=("first umu-run call: $l1") ;; esac
  case $l2 in *" winecfg -v win10") ;; *) ERRS+=("second umu-run call: $l2") ;; esac
  printf '%s\n' 'Windows Registry Editor Version 5.00' '' '[HKEY_CURRENT_USER\Software\Wine\AppDefaults\msedgewebview2.exe]' "\"Version\"=\"$1\"" '' \
    '[HKEY_CURRENT_USER\Software\Blizzard Entertainment\Warcraft III]' '"Allow Local Files"=dword:00000001' | cmp -s - "$T/marks/w3c.reg" \
    || ERRS+=('the w3c.reg regedit read is not the expected 7 LF lines')
  [ ! -e "$T/home/.cache/w3c-linux/w3c.reg" ] || ERRS+=('w3c.reg is still in the cache')
  out_has 'Registry set'
}

t_reg_satisfied_noop() {
  mk_release "$T"
  on_w3c "$T"
  FEED=$'y\n'
  run "$T" install
  rc_is 0
  case $ERR in *'Apply registry tweaks'*) ERRS+=('prompt 6 was asked') ;; esac
  no_umu
  changed_is
}

t_reg_missing_allow() {
  reg_setup
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 0
  err_has 'Apply registry tweaks (msedgewebview2.exe -> win7, prefix -> win10, Allow Local Files)? [Y/n]'
  reg_applied win7
}

# the user's win8 stays when only Allow Local Files is missing (D-07)
t_reg_keep_win8() {
  reg_setup
  user_reg "$T" '[Software\\Blizzard Entertainment\\Warcraft III]' win8
  reg_drop "$T" 'Allow Local Files'
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 0
  err_has '(msedgewebview2.exe -> win8, prefix -> win10'
  reg_applied win8
}

t_reg_toggle_win8() {
  reg_setup
  user_reg "$T" '[Software\\Blizzard Entertainment\\Warcraft III]'
  CASE_ENV=(W3C_WEBVIEW_WINVER=win8)
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 0
  err_has '(msedgewebview2.exe -> win8, prefix -> win10'
  reg_applied win8
  rm -f "$T/marks/umu-run" "$T/marks/umu-run.env"
  FEED=$'y\n'
  run "$T" install
  rc_is 0
  case $ERR in *'Apply registry tweaks'*) ERRS+=('prompt 6 was asked on the second run') ;; esac
  no_umu
}

t_reg_toggle_same() {
  mk_release "$T"
  on_w3c "$T"
  CASE_ENV=(W3C_WEBVIEW_WINVER=win7)
  FEED=$'y\n'
  run "$T" install
  rc_is 0
  case $ERR in *'Apply registry tweaks'*) ERRS+=('prompt 6 was asked') ;; esac
  no_umu
}

# a bad toggle is a usage error before any question, any network call or any change
t_reg_toggle_bogus() {
  mk_release "$T"
  on_w3c "$T"
  CASE_ENV=(W3C_WEBVIEW_WINVER=win10)
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 2
  err_has 'must be win7 or win8'
  case $ERR in *'Continue?'*) ERRS+=('prompt 1 was asked') ;; esac
  [ ! -e "$T/marks/curl" ] || ERRS+=('curl ran')
  no_umu
  changed_is
}

t_reg_win11() {
  reg_setup
  user_reg "$T" '[Software\\Blizzard Entertainment\\Warcraft III]'
  reg_set_build "$T" 22000
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 0
  err_has 'Apply registry tweaks'
  reg_applied win7
  out_has 'Windows 10 (build 19045)'
}

# Allow Local Files counts only under its own section, whatever the header's case
t_reg_section_scope() {
  reg_setup
  user_reg "$T" '[Software\\Blizzard Entertainment\\Warcraft III\\Other]'
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 0
  err_has 'Apply registry tweaks'
  rm -f "$T/marks/umu-run" "$T/marks/umu-run.env"
  user_reg "$T" '[software\\blizzard entertainment\\warcraft iii]'
  FEED=$'y\n'
  run "$T" install
  rc_is 0
  case $ERR in *'Apply registry tweaks'*) ERRS+=('prompt 6 was asked for a lower-case header') ;; esac
  no_umu
}

# reg_failed_run: the registry commands change nothing and the launcher is missing too; install stops at the registry step.
reg_failed_run() {
  mk_release "$T"
  on_w3c "$T"
  no_launcher "$T"
  reg_drop "$T" 'Allow Local Files'
  umu_hook "$T" ':'
  FEED=$'y\ny\ny\n'
  run "$T" install
}

t_reg_verify_fail() {
  reg_failed_run
  rc_is 1
  out_has 'registry step failed'
  out_has 'Allow Local Files is absent'
  umu_count 2
  ! grep -q msiexec "$T/marks/umu-run" || ERRS+=('msiexec ran after the failed registry step')
  [ -f "$T/home/.cache/w3c-linux/w3c.reg" ] || ERRS+=('w3c.reg was not kept for diagnosis')
}

t_reg_busy_between() {
  reg_setup "[ \"\$1\" != regedit ] || echo '$BN_LINE' >> \"\$FIX/procs\""
  ALLOW_EXTRA+=(fix/procs)
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 1
  out_has 'in-prefix step refused: something is still running'
  umu_count 1
}

t_reg_resume() {
  reg_failed_run
  rc_is 1
  umu_hook "$T" "$REG_HOOK"$'\n'"$MSI_HOOK"
  ALLOW_EXTRA+=("${REG_ALLOW[@]}" 'home/Faugus/battlenet/drive_c/Program Files/W3Champions/W3Champions.exe')
  rm -f "$T/marks/umu-run" "$T/marks/umu-run.env"
  FEED=$'y\ny\ny\n'
  run "$T" install
  rc_is 0
  err_has 'Apply registry tweaks'
  umu_count 3
  out_has 'Install complete'
}

# ---------- launcher completion (PFX-04) ----------

# set_dispver T V: rewrites the W3Champions DisplayVersion in system.reg, adds the entry when there is none, removes the line when V is empty.
set_dispver() {
  local f=$1/home/Faugus/battlenet/system.reg
  if [ -z "$2" ]; then
    sed -i '/^"DisplayVersion"=/d' "$f"
  elif grep -q '^"DisplayVersion"=' "$f"; then
    sed -i "s/^\"DisplayVersion\"=.*/\"DisplayVersion\"=\"$2\"/" "$f"
  else
    printf '%s\n' '' '[Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{6C2A7B21-0000-4000-8000-000000000001}] 1700000000' \
      '"DisplayName"="W3Champions"' "\"DisplayVersion\"=\"$2\"" >> "$f"
  fi
}

# rec_set T V: the recorded launcher version, removed when V is empty.
rec_set() {
  if [ -z "$2" ]; then rm -f "$1/home/.local/state/w3c-linux/launcher-version"; else printf '%s\n' "$2" > "$1/home/.local/state/w3c-linux/launcher-version"; fi
}

LATEST_JSON_TEXT='{"version": "1.6.16", "notes": "", "pub_date": "2026-10-08T10:10:26Z", "platforms": {"windows-x86_64-msi": {"signature": "sig", "url": "https://github.com/w3champions/launcher-e-release/releases/download/1.6.16/W3Champions_1.6.16_x64_en-US.msi"}}}'

# set_latest_json T PYTHON: resets T/fix/latest.json to the 1.6.16 manifest, then mutates it; PYTHON sees r (the manifest object).
set_latest_json() {
  printf '%s\n' "$LATEST_JSON_TEXT" > "$1/fix/latest.json"
  python3 - "$1/fix/latest.json" "$2" <<'PY'
import json, sys
f, code = sys.argv[1:3]
r = json.load(open(f, encoding="utf-8"))
exec(code)
json.dump(r, open(f, "w", encoding="utf-8"), ensure_ascii=False)
PY
}

# the msiexec effect on an upgrade or an unknown version: the DisplayVersion becomes 1.6.16 (the entry gets one when it had none)
IFS= read -r -d '' UPD_HOOK <<'SH' || true
if [ "$1" = msiexec ]; then
  sed -i -e '/^"DisplayVersion"=/d' -e 's/^"DisplayName"="W3Champions"$/&\n"DisplayVersion"="1.6.16"/' "$WINEPREFIX/system.reg"
fi
SH

# upd_setup V: the launcher is installed as version V (DisplayVersion and record), latest is 1.6.16, msiexec upgrades it.
upd_setup() {
  mk_release "$T"
  on_w3c "$T"
  set_dispver "$T" "$1"
  rec_set "$T" "$1"
  umu_hook "$T" "$UPD_HOOK"
  ALLOW_EXTRA+=(home/Faugus/battlenet/system.reg)
}

# no_prompt7: neither the install nor the update question was asked and no MSI was downloaded.
no_prompt7() {
  case $ERR in *'Install W3Champions'* | *'Update W3Champions'*) ERRS+=('prompt 7 was asked') ;; esac
  ! grep -qF '/api/launcher-e' "$T/marks/curl" 2> /dev/null || ERRS+=('an MSI was downloaded')
}

t_msi_update_prompt() {
  upd_setup 1.6.15
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 0
  err_has 'Update W3Champions 1.6.15 -> 1.6.16? [Y/n]'
  umu_count 1
  [ "$(launcher_rec)" = 1.6.16 ] || ERRS+=("launcher-version holds: $(launcher_rec)")
  grep -qF '"DisplayVersion"="1.6.16"' "$T/home/Faugus/battlenet/system.reg" || ERRS+=('the hook did not upgrade')
  out_has 'Installed W3Champions 1.6.16'
}

t_msi_unknown() {
  upd_setup ''
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 0
  err_has 'Update W3Champions unknown -> 1.6.16? [Y/n]'
  umu_count 1
  [ "$(launcher_rec)" = 1.6.16 ] || ERRS+=("launcher-version holds: $(launcher_rec)")
}

# a launcher installed by hand: no record, a current DisplayVersion; install adopts it without asking or running Wine
t_msi_adopt() {
  mk_release "$T"
  on_w3c "$T"
  rec_set "$T" ''
  FEED=$'y\n'
  run "$T" install
  rc_is 0
  no_prompt7
  no_umu
  [ "$(launcher_rec)" = 1.6.16 ] || ERRS+=("launcher-version holds: $(launcher_rec)")
  out_has 'Recorded W3Champions 1.6.16'
}

t_msi_resync() {
  mk_release "$T"
  on_w3c "$T"
  rec_set "$T" 1.6.10
  FEED=$'y\n'
  run "$T" install
  rc_is 0
  no_prompt7
  no_umu
  [ "$(launcher_rec)" = 1.6.16 ] || ERRS+=("launcher-version holds: $(launcher_rec)")
}

t_msi_adopt_older() {
  mk_release "$T"
  on_w3c "$T"
  set_dispver "$T" 1.6.15
  rec_set "$T" ''
  FEED=$'y\nn\n'
  run "$T" install
  rc_is 0
  err_has 'Update W3Champions 1.6.15 -> 1.6.16? [Y/n]'
  no_umu
  [ "$(launcher_rec)" = 1.6.15 ] || ERRS+=("launcher-version holds: $(launcher_rec)")
}

t_msi_two_entries() {
  mk_release "$T"
  on_w3c "$T"
  printf '%s\n' '' '[Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{OLD}] 1700000000' \
    '"DisplayName"="W3Champions"' '"DisplayVersion"="1.6.14"' >> "$T/home/Faugus/battlenet/system.reg"
  FEED=$'y\n'
  run "$T" install
  rc_is 0
  no_prompt7
  no_umu
  out_has 'W3Champions 1.6.16 is in its prefix'
}

# msi_hook_setup HOOK: the launcher is not installed and msiexec does HOOK.
msi_hook_setup() {
  mk_release "$T"
  on_w3c "$T"
  no_launcher "$T"
  umu_hook "$T" "$1"
  ALLOW_EXTRA+=(home/Faugus/battlenet/system.reg 'home/Faugus/battlenet/drive_c/Program Files/W3Champions/W3Champions.exe')
}

# the argv of the Nth umu-run call
umu_call() { sed -n "${1}p" "$T/marks/umu-run"; }

# the silent run leaves nothing; the interactive one (no /qn) installs
t_msi_qn_no_exe() {
  msi_hook_setup 'case " $* " in *" /qn "*) ;; *)
'"$MSI_HOOK"';; esac'
  FEED=$'y\ny\ny\n'
  run "$T" install
  rc_is 0
  err_has 'Run the MSI installer interactively? [Y/n]'
  umu_count 2
  case $(umu_call 1) in *' /qn') ;; *) ERRS+=("first call lacks /qn: $(umu_call 1)") ;; esac
  case $(umu_call 2) in *'/qn'*) ERRS+=("second call has /qn: $(umu_call 2)") ;; esac
  [ "$(launcher_rec)" = 1.6.16 ] || ERRS+=("launcher-version holds: $(launcher_rec)")
}

# an upgrade whose silent run leaves the old DisplayVersion
t_msi_old_left() {
  upd_setup 1.6.15
  umu_hook "$T" 'case " $* " in *" /qn "*) ;; *)
'"$UPD_HOOK"';; esac'
  FEED=$'y\ny\ny\n'
  run "$T" install
  rc_is 0
  err_has 'Run the MSI installer interactively? [Y/n]'
  umu_count 2
  [ "$(launcher_rec)" = 1.6.16 ] || ERRS+=("launcher-version holds: $(launcher_rec)")
}

t_msi_interactive_declined() {
  msi_hook_setup ':'
  FEED=$'y\ny\nn\n'
  run "$T" install
  rc_is 1
  err_has 'Run the MSI installer interactively? [Y/n]'
  out_has 'interactive installer declined'
  umu_count 1
  [ -z "$(launcher_rec)" ] || ERRS+=('launcher-version was written')
}

t_msi_interactive_fails() {
  msi_hook_setup ':'
  FEED=$'y\ny\ny\n'
  run "$T" install
  rc_is 1
  out_has 'after the interactive installer'
  umu_count 2
  [ -z "$(launcher_rec)" ] || ERRS+=('launcher-version was written')
}

t_msi_url_fallback() {
  msi_setup
  rm "$T/fix/launcher-e"
  printf 'fake launcher msi\n' > "$T/fix/W3Champions_1.6.16_x64_en-US.msi"
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 0
  grep -qF 'https://update-service.w3champions.com/api/launcher-e' "$T/marks/curl" || ERRS+=('the API URL was not tried')
  grep -qF 'https://github.com/w3champions/launcher-e-release/releases/download/1.6.16/W3Champions_1.6.16_x64_en-US.msi' "$T/marks/curl" \
    || ERRS+=('the manifest URL was not tried')
  umu_count 1
  [ "$(launcher_rec)" = 1.6.16 ] || ERRS+=("launcher-version holds: $(launcher_rec)")
}

t_msi_download_fails() {
  msi_setup
  rm "$T/fix/launcher-e"
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 1
  out_has 'launcher download failed'
  no_umu
}

# the trust boundary: every malformed manifest stops install before an MSI is downloaded
t_msi_latest_bad() {
  local v n
  msi_setup
  for v in "r['version'] = '../x'" "r['version'] = '1.6'" "r['version'] = 7" "del r['platforms']" \
    "r['platforms']['windows-x86_64-msi']['url'] = 'https://evil.example/W3Champions_1.6.16_x64_en-US.msi'" \
    "r['platforms']['windows-x86_64-msi']['url'] = r['platforms']['windows-x86_64-msi']['url'].replace('https', 'http')" NOTJSON; do
    n=${#ERRS[@]}
    if [ "$v" = NOTJSON ]; then printf 'not json\n' > "$T/fix/latest.json"; else set_latest_json "$T" "$v"; fi
    rm -f "$T/marks/curl"
    FEED=$'y\ny\n'
    run "$T" install
    rc_is 1
    out_has 'cannot read the latest W3Champions version ('
    ! grep -qF '/api/launcher-e' "$T/marks/curl" 2> /dev/null || ERRS+=('an MSI was downloaded')
    no_umu
    [ "${#ERRS[@]}" -eq "$n" ] || ERRS+=("variant: $v")
  done
}

t_msi_offline_installed() {
  mk_release "$T"
  on_w3c "$T"
  rm "$T/fix/latest.json"
  FEED=$'y\n'
  run "$T" install
  rc_is 0
  out_has 'could not check for a newer launcher'
  no_prompt7
  no_umu
}

t_msi_offline_absent() {
  msi_setup
  rm "$T/fix/latest.json"
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 1
  out_has 'cannot read the latest W3Champions version ('
  no_umu
}

t_msi_rerun_noop() {
  msi_setup
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 0
  rm -f "$T/marks/umu-run" "$T/marks/umu-run.env" "$T/marks/curl"
  FEED=$'y\n'
  run "$T" install
  rc_is 0
  no_prompt7
  no_umu
}

# ---------- Phase 2 review fixes (WR-01 to WR-04) ----------

# bn_unset4 T KEY null|drop: the battlenet entry's key is null or absent; refreshes the pre-run copy like bn_set4.
bn_unset4() {
  python3 - "$1/home/.local/share/faugus-launcher/games.json" "$2" "$3" <<'PY2'
import json, sys
f, k, how = sys.argv[1:4]
data = json.load(open(f, encoding="utf-8"))
for e in data:
    if e.get("gameid") == "battlenet":
        if how == "drop":
            del e[k]
        else:
            e[k] = None
json.dump(data, open(f, "w", encoding="utf-8"), indent=4, ensure_ascii=False)
PY2
  cp "$1/home/.local/share/faugus-launcher/games.json" "$1/orig-games.json"
}

# hold_lock / drop_lock: this shell holds the wrapper's run lock on its own descriptor, the way a second wrapper run would.
LOCK_FD=''
hold_lock() {
  mkdir -p "$T/home/.local/state/w3c-linux"
  exec {LOCK_FD}> "$T/home/.local/state/w3c-linux/lock"
  flock -n "$LOCK_FD" || ERRS+=('the test could not take the lock')
}
drop_lock() { exec {LOCK_FD}>&-; }

# lock_refused: the run said so, changed nothing and downloaded nothing.
lock_refused() {
  rc_is 1
  out_has 'another w3c-linux.sh run is in progress'
  [ ! -e "$T/marks/curl" ] || ERRS+=('curl ran')
  unchanged_games
  changed_is
}

# no_err TEXT: stderr lacks TEXT.
no_err() { case $ERR in *"$1"*) ERRS+=("stderr has: $1") ;; esac; }

t_wr1_revert_stock() {
  bn_set4 "$T" runner 'Proton-GE Latest'
  mk_bak "$T" 20260101-000000-100000 'Proton-EM Latest'
  FEED=$'y\n'
  run "$T" revert
  rc_is 1
  out_has 'revert: Battle.net runs on Proton-GE Latest, not a W3C build; nothing to revert'
  unchanged_games_keep_bak
  changed_is
}

# games.json is the pre-run file (the seeded backup stays)
unchanged_games_keep_bak() {
  cmp -s "$T/orig-games.json" "$T/home/.local/share/faugus-launcher/games.json" || ERRS+=('games.json changed')
  bak_count 1
}

t_wr1_revert_custom() {
  mk_installed "$T"
  seed_tag "$T" "$TAG"
  bn_set4 "$T" runner 'Proton-CachyOS Latest'
  mk_bak "$T" 20260101-000000-100000 'Proton-GE Latest'
  FEED=$'y\n'
  run "$T" revert
  rc_is 1
  out_has 'revert: Battle.net runs on Proton-CachyOS Latest, not a W3C build; nothing to revert'
  unchanged_games_keep_bak
  runner_is 'Proton-CachyOS Latest'
  changed_is
}

t_wr1_revert_empty_runner() {
  bn_set4 "$T" runner ''
  mk_bak "$T" 20260101-000000-100000 'Proton-GE Latest'
  FEED=$'y\n'
  run "$T" revert
  rc_is 1
  out_has 'revert: Battle.net runs on UMU-Proton Latest, not a W3C build; nothing to revert'
  unchanged_games_keep_bak
  changed_is
}

t_wr1_doctor_hint() {
  local row
  seed_tag "$T" "$TAG"
  bn_set4 "$T" runner GE-Proton-Other
  run "$T" doctor
  rc_is 0
  has_row warn 'runner build' "GE-Proton-Other, expected $TAG: run w3c-linux.sh install"
  row=$(grep '^warn  runner build' <<< "$OUT")
  case $row in *revert*) ERRS+=("the hint names revert: $row") ;; esac
  case $row in *"install") ;; *) ERRS+=("the row does not end with install: $row") ;; esac
}

# a missing or null runner is read as '' everywhere: install switches without a false compare-and-swap loss
wr2_switch() {
  mk_release "$T"
  mk_installed "$T"
  seed_tag "$T" "$TAG"
  bn_unset4 "$T" runner "$1"
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 0
  out_has 'Battle.net runner switched'
  lacks_text 'changed while install was waiting'
  runner_is "$TAG"
}
t_wr2_missing_runner() { wr2_switch drop; }
t_wr2_null_runner() { wr2_switch null; }

t_wr2_backup_no_runner() {
  local b
  mk_installed "$T"
  seed_tag "$T" "$TAG"
  bn_set4 "$T" runner "$TAG"
  mk_bak "$T" 20260101-000000-100000 x
  b=$T/home/.local/state/w3c-linux/games.json.20260101-000000-100000.bak
  python3 - "$b" <<'PY2'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for e in d:
    if e.get("gameid") == "battlenet":
        del e["runner"]
json.dump(d, open(sys.argv[1], "w", encoding="utf-8"), indent=4, ensure_ascii=False)
PY2
  FEED=$'y\n\n'
  run "$T" revert
  rc_is 0
  err_has "from $TAG back to UMU-Proton Latest?"
  out_has 'Battle.net runner restored'
  runner_is ''
}

t_wr3_lock_held_install() {
  mk_release "$T"
  hold_lock
  FEED=$'y\n'
  run "$T" install
  drop_lock
  lock_refused
}

t_wr3_lock_held_revert() {
  w3c_on
  hold_lock
  FEED=$'y\n'
  run "$T" revert
  drop_lock
  rc_is 1
  out_has 'another w3c-linux.sh run is in progress'
  unchanged_games_keep_bak
  changed_is
}

# a Wine child that outlives install must not keep the lock (fd 9 closed on every in-prefix command)
t_wr3_lock_released() {
  msi_setup 'sleep 3 > /dev/null 2>&1 < /dev/null &'
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 0
  FEED=$'y\n'
  run "$T" install
  rc_is 0
  lacks_text 'another w3c-linux.sh run is in progress'
}

t_wr3_declined_no_lock() {
  mk_release "$T"
  FEED=$'n\n'
  run "$T" install
  rc_is 0
  [ ! -e "$T/home/.local/state/w3c-linux/lock" ] || ERRS+=('a lock file exists after a declined prompt 1')
}

t_wr4_install_no_pgrep() {
  mk_release "$T"
  rm "$T/bin/pgrep"
  FEED=$'y\n'
  run "$T" install
  rc_is 1
  out_has 'missing: pgrep'
  no_err 'Continue?'
  [ ! -e "$T/marks/curl" ] || ERRS+=('curl ran')
}

t_wr4_revert_no_pgrep() {
  w3c_on
  rm "$T/bin/pgrep"
  FEED=$'y\n'
  run "$T" revert
  rc_is 1
  err_has 'cannot check processes: pgrep (procps-ng) is missing'
  no_err 'press Enter'
  unchanged_games_keep_bak
}

# ---------- doctor rows (PFX-05) ----------

# doc_run: doctor exits 0, makes the one latest.json GET, lists no process, starts no Wine and changes no path.
doc_run() {
  run "$T" doctor
  rc_is 0
  curl_only_latest_json
  no_umu
  [ ! -e "$T/marks/pgrep" ] || ERRS+=('doctor ran pgrep')
  [ ! -e "$T/marks/pkill" ] || ERRS+=('doctor ran pkill')
  changed_is
}

t_doc_provisioned() {
  local exe
  exe=$(realpath "$T/home/Faugus/battlenet")/drive_c/Program\ Files/W3Champions/W3Champions.exe
  on_w3c "$T"
  mk_prefix_state "$T" GE-Proton11-7 "$(lib_line "$T" "$TAG")"
  doc_run
  has_row pass webview2 '149.0.4022.98 ('
  has_row pass 'webview2 winver' 'win7 ('
  has_row pass 'local files' 'Allow Local Files dword:00000001'
  has_row pass 'windows version' 'Windows 10 (build 19045)'
  has_row pass launcher "$exe"
  has_row pass 'launcher version' '1.6.16 (installed 1.6.16, recorded 1.6.16, latest 1.6.16)'
  ! grep -v '^warn  desktop entry ' <<< "$OUT" | grep -q '^warn' || ERRS+=("a warn row is printed: $(grep -v '^warn  desktop entry ' <<< "$OUT" | grep '^warn')")
}

t_doc_fresh() {
  on_w3c "$T"
  no_wv2 "$T"
  no_launcher "$T"
  rm "$T/home/Faugus/battlenet/user.reg"
  sed -i '/CurrentBuild/d' "$T/home/Faugus/battlenet/system.reg"
  doc_run
  has_row warn webview2 'absent: run w3c-linux.sh install'
  has_row warn 'webview2 winver' 'unset: run w3c-linux.sh install'
  has_row warn 'local files' 'Allow Local Files absent'
  has_row warn 'windows version' 'unknown (CurrentBuild absent)'
  has_row warn launcher 'not installed: run w3c-linux.sh install'
  has_row warn 'launcher version' 'installed -, recorded -, latest 1.6.16: run w3c-linux.sh install'
}

t_doc_wv2_range() {
  local v
  on_w3c "$T"
  for v in 109.0.1518.78 144.0.3719.82 110.0.1587.41 143.0.3650.75; do
    no_wv2 "$T"
    wv2_at "$T" "$v"
    rm -f "$T/marks/curl"
    doc_run
    case $v in
      109* | 144*) has_row pass webview2 "$v (" ;;
      *) has_row warn webview2 "$v: outside the working range"; has_row warn webview2 '110 to 143 is the broken range' ;;
    esac
  done
}

t_doc_winver_win8() {
  on_w3c "$T"
  user_reg "$T" '[Software\\Blizzard Entertainment\\Warcraft III]' win8
  doc_run
  has_row pass 'webview2 winver' 'win8 ('
  has_row pass 'webview2 winver' 'W3C_WEBVIEW_WINVER=win7 w3c-linux.sh install'
}

t_doc_win11() {
  on_w3c "$T"
  reg_set_build "$T" 22000
  doc_run
  has_row warn 'windows version' 'Windows 11 (build 22000)'
}

t_doc_record_differs() {
  on_w3c "$T"
  rec_set "$T" 1.6.15
  doc_run
  has_row warn 'launcher version' 'installed 1.6.16, recorded 1.6.15'
  has_row warn 'launcher version' 'record differs from installed'
}

t_doc_newer() {
  on_w3c "$T"
  set_latest_json "$T" "u = r['platforms']['windows-x86_64-msi']; u['url'] = u['url'].replace('1.6.16', '1.6.17'); r['version'] = '1.6.17'"
  doc_run
  has_row warn 'launcher version' 'latest 1.6.17'
  has_row warn 'launcher version' 'run w3c-linux.sh update'
}

t_doc_offline() {
  on_w3c "$T"
  rm "$T/fix/latest.json"
  doc_run
  has_row warn 'launcher version' 'latest unknown: offline'
}

t_doc_no_prefix() {
  local l
  printf '[]' > "$T/home/.local/share/faugus-launcher/games.json"
  run "$T" doctor
  rc_is 1
  for l in webview2 'webview2 winver' 'local files' 'windows version' launcher 'launcher version'; do
    has_row skip "$l" 'needs: battlenet entry'
  done
  [ ! -e "$T/marks/curl" ] || ERRS+=('curl ran without a prefix')
  changed_is
}

# ---------- update (UPD-01, UPD-02) ----------

T8=GE-Proton11-8-W3C
COMPAT_REL=home/.local/share/Steam/compatibilitytools.d

# the msiexec effect of an upgrade to 1.6.17
IFS= read -r -d '' UPD17_HOOK <<'SH' || true
if [ "$1" = msiexec ]; then
  sed -i 's/^"DisplayVersion"=.*/"DisplayVersion"="1.6.17"/' "$WINEPREFIX/system.reg"
fi
SH

# latest_17 T: latest.json says 1.6.17 and the MSI download exists.
latest_17() {
  set_latest_json "$1" "u = r['platforms']['windows-x86_64-msi']; u['url'] = u['url'].replace('1.6.16', '1.6.17'); r['version'] = '1.6.17'"
}

# newer_both: Battle.net on TAG, the fork's latest is T8, the launcher 1.6.17 is out, msiexec upgrades it.
newer_both() {
  on_w3c "$T"
  mk_release "$T" "$T8"
  latest_17 "$T"
  umu_hook "$T" "$UPD17_HOOK"
  ALLOW_EXTRA+=(home/Faugus/battlenet/system.reg)
}

# prev_is TAG: proton-tag.prev holds TAG, or nothing when TAG is empty.
prev_is() {
  local f=$T/home/.local/state/w3c-linux/proton-tag.prev
  if [ -z "$1" ]; then
    [ ! -e "$f" ] || ERRS+=('proton-tag.prev exists')
  else
    [ "$(cat "$f" 2> /dev/null)" = "$1" ] || ERRS+=("proton-tag.prev does not hold $1")
  fi
}

# no_tarball: no .tar.gz was fetched.
no_tarball() { ! grep -qF '.tar.gz' "$T/marks/curl" 2> /dev/null || ERRS+=('a tarball was downloaded'); }

# a Faugus major we never tested only warns: update carries on as before
t_upd_faugus_untested() {
  mk_release "$T"
  on_w3c "$T"
  printf '%s\n' 'VERSION = "3.0.1"' > "$T/faugus-py/faugus/launcher.py"
  run "$T" update
  rc_is 0
  out_has "$(printf '%s  %-16s  %s' warn 'faugus version' 'untested Faugus major 3: games.json/envar.json format may differ')"
  lacks_text 'pass  faugus version'
  out_has "patched Proton $TAG up to date"
  out_has 'launcher 1.6.16 up to date'
}

t_upd_all_current() {
  local o
  mk_release "$T"
  on_w3c "$T"
  run "$T" update
  rc_is 0
  out_has "patched Proton $TAG up to date"
  out_has 'launcher 1.6.16 up to date'
  case $ERR in *'[Y/n]'*) ERRS+=('a question was asked') ;; esac
  no_umu
  [ ! -e "$T/marks/pgrep" ] || ERRS+=('processes were listed')
  changed_is
  o=$OUT
  run "$T" update
  rc_is 0
  [ "$OUT" = "$o" ] || ERRS+=('the second run printed something else')
  changed_is
}

t_upd_launcher_newer() {
  mk_release "$T"
  on_w3c "$T"
  latest_17 "$T"
  umu_hook "$T" "$UPD17_HOOK"
  ALLOW_EXTRA+=(home/Faugus/battlenet/system.reg)
  FEED=$'y\n'
  run "$T" update
  rc_is 0
  err_has 'Update W3Champions 1.6.16 -> 1.6.17? [Y/n]'
  umu_count 1
  grep -qF "msiexec /i $(zpath "$T/home/.cache/w3c-linux/launcher/W3Champions_1.6.17_x64_en-US.msi") /qn" "$T/marks/umu-run" || ERRS+=('msiexec argv differs')
  [ "$(launcher_rec)" = 1.6.17 ] || ERRS+=("launcher-version holds: $(launcher_rec)")
  out_has 'Update finished.'
  rm -f "$T/marks/umu-run"
  unset FEED
  run "$T" update
  rc_is 0
  out_has 'launcher 1.6.17 up to date'
  no_umu
}

t_upd_launcher_adopt() {
  mk_release "$T"
  on_w3c "$T"
  rec_set "$T" ''
  run "$T" update
  rc_is 0
  out_has 'Recorded W3Champions 1.6.16'
  out_has 'launcher 1.6.16 up to date'
  no_prompt7
  no_umu
  [ "$(launcher_rec)" = 1.6.16 ] || ERRS+=("launcher-version holds: $(launcher_rec)")
}

t_upd_launcher_unknown() {
  upd_setup ''
  FEED=$'y\n'
  run "$T" update
  rc_is 0
  err_has 'Update W3Champions unknown -> 1.6.16? [Y/n]'
  umu_count 1
  [ "$(launcher_rec)" = 1.6.16 ] || ERRS+=("launcher-version holds: $(launcher_rec)")
}

t_upd_not_installed() {
  mk_release "$T"
  on_w3c "$T"
  no_launcher "$T"
  run "$T" update
  rc_is 0
  out_has 'W3Champions is not installed: run w3c-linux.sh install'
  no_prompt7
  no_umu
}

t_upd_proton_newer() {
  local c=$T/$COMPAT_REL
  newer_both
  FEED=$'y\ny\n'
  run "$T" update
  rc_is 0
  err_has "Install $T8 (about 1.1 GB) and switch Faugus's Battle.net runner to it? $TAG stays installed; w3c-linux.sh revert switches back."
  err_has 'Update W3Champions 1.6.16 -> 1.6.17? [Y/n]'
  case ${ERR%%Update W3Champions*} in *"Install $T8"*) ;; *) ERRS+=('the Proton question did not come first') ;; esac
  runner_is "$T8"
  tag_is "$T8"
  prev_is "$TAG"
  build_ok "$c/$TAG"
  build_ok "$c/$T8"
  umu_count 1
  umu_env_has "PROTONPATH=$c/$T8"
  [ "$(launcher_rec)" = 1.6.17 ] || ERRS+=("launcher-version holds: $(launcher_rec)")
  out_has "Recorded $T8; the previous W3C build $TAG stays installed"
  out_has 'Update finished.'
}

t_upd_proton_declined() {
  newer_both
  FEED=$'n\ny\n'
  run "$T" update
  rc_is 0
  runner_is "$TAG"
  no_tarball
  umu_count 1
  umu_env_has "PROTONPATH=$T/$COMPAT_REL/$TAG"
  prev_is ''
  tag_is "$TAG"
  [ "$(launcher_rec)" = 1.6.17 ] || ERRS+=("launcher-version holds: $(launcher_rec)")
}

t_upd_proton_present() {
  on_w3c "$T"
  mk_release "$T" "$T8"
  mk_installed "$T" "$T8"
  FEED=$'y\n'
  run "$T" update
  rc_is 0
  err_has "Switch Faugus's Battle.net runner to $T8? $TAG stays installed"
  case $ERR in *'Install '*) ERRS+=('the question says Install') ;; esac
  no_tarball
  runner_is "$T8"
  tag_is "$T8"
  prev_is "$TAG"
}

t_upd_order_busy() {
  newer_both
  add_proc "$T" 4242 Battle.net.exe 'C:\Program Files (x86)\Battle.net\Battle.net.exe'
  FEED=$'y\ny\n'
  run "$T" update
  rc_is 1
  build_ok "$T/$COMPAT_REL/$T8"
  [ -f "$T/home/.cache/w3c-linux/launcher/W3Champions_1.6.17_x64_en-US.msi" ] || ERRS+=('the MSI was not downloaded before the wait')
  unchanged_games
  no_umu
  tag_is "$TAG"
  prev_is ''
}

t_upd_no_w3c_runner() {
  mk_release "$T"
  on_w3c "$T"
  bn_set4 "$T" runner 'Proton-GE Latest'
  latest_17 "$T"
  run "$T" update
  rc_is 0
  out_has 'launcher update needs Battle.net on a W3C build: run w3c-linux.sh install'
  case $ERR in *'Update W3Champions'*) ERRS+=('the launcher question was asked') ;; esac
  no_umu
  changed_is
}

t_upd_api_down() {
  mk_release "$T"
  on_w3c "$T"
  rm "$T/fix/latest"
  run "$T" update
  rc_is 0
  has_row warn 'w3c build' 'could not check for a newer build'
  out_has 'launcher 1.6.16 up to date'
  changed_is
}

t_upd_lock_held() {
  mk_release "$T"
  on_w3c "$T"
  hold_lock
  run "$T" update
  drop_lock
  lock_refused
}

t_upd_rerun_after_switch() {
  newer_both
  FEED=$'y\ny\n'
  run "$T" update
  rc_is 0
  rm -f "$T/marks/umu-run" "$T/marks/curl"
  FEED=$'\n'   # D-15: the later run asks about the replaced build; Enter keeps it
  run "$T" update
  rc_is 0
  err_has "Remove $TAG (about 1.5 GB)? Only if a ladder match on $T8 worked. [y/N]"
  out_has "patched Proton $T8 up to date"
  out_has 'launcher 1.6.17 up to date'
  prev_is "$TAG"
  changed_is
}

# an update stopped after the switch: the runner already is T8 while proton-tag still names TAG
t_upd_recover() {
  on_w3c "$T"
  mk_release "$T" "$T8"
  mk_installed "$T" "$T8"
  bn_set4 "$T" runner "$T8"
  FEED=$'y\n'
  run "$T" update
  rc_is 0
  no_tarball
  unchanged_games
  tag_is "$T8"
  prev_is "$TAG"
}

# ---------- upstream fix watch (UPD-03) ----------

# watch_fix T [FLAG]: the three watch fixtures in the quiet state; FLAG puts limit_flags into the get_job_info reply.
watch_fix() {
  {
    printf '%s\n' '@REQ(get_job_info)' '    obj_handle_t handle;' '@REPLY' '    int          running_processes;'
    [ -z "${2:-}" ] || printf '%s\n' '    unsigned int limit_flags;'
    printf '%s\n' '@END' '' '@REQ(set_job_limits)' '    obj_handle_t handle;' '    unsigned int limit_flags;' '@END'
  } > "$1/fix/protocol.def"
  printf '{"state": "open"}\n' > "$1/fix/issue57"
  printf '{"tag_name": "GE-Proton11-7"}\n' > "$1/fix/ge-latest"
}

# watch_base: a provisioned tree, current on both components, so update prints the watch and asks nothing.
watch_base() {
  mk_release "$T"
  on_w3c "$T"
  watch_fix "$T" "${1:-}"
}

t_watch_quiet() {
  watch_base
  run "$T" update
  rc_is 0
  out_has 'Upstream fix watch (advisory; nothing here changes the runner):'
  out_has 'the get_job_info reply has no limit_flags yet'
  out_has '#57 is open'
  out_has 'not lagging'
  out_has 'github.com/search?q=repo%3AGloriousEggroll%2Fproton-ge-custom+JobObjectBasicLimitInformation'
  runner_is "$TAG"
  changed_is
}

t_watch_fix_landed() {
  watch_base flag
  run "$T" update
  rc_is 0
  out_has 'an upstream fix may have landed'
  out_has 'never switches back by itself'
  runner_is "$TAG"
  changed_is
}

t_watch_ge_newer() {
  watch_base
  printf '{"tag_name": "GE-Proton11-10"}\n' > "$T/fix/ge-latest"
  run "$T" update
  rc_is 0
  out_has 'GE-Proton11-10 is newer than the W3C build'
  out_has 'base GE-Proton11-7'
  out_has "stay on $TAG"
  out_has 'wait for a rebase'
  out_has 'rebuild'
  runner_is "$TAG"
  changed_is
}

t_watch_issue_closed() {
  watch_base
  printf '{"state": "closed"}\n' > "$T/fix/issue57"
  run "$T" update
  rc_is 0
  out_has '#57 is closed'
  changed_is
}

t_watch_all_fail() {
  local n
  mk_release "$T"
  on_w3c "$T"
  run "$T" update
  rc_is 0
  out_has 'could not check Wine master'
  out_has 'could not check w3champions-issues #57'
  out_has "could not check GE-Proton's latest release"
  n=$(grep -c 'could not check' <<< "$OUT")
  [ "$n" = 3 ] || ERRS+=("could not check lines: want 3 got $n")
  changed_is
}

# bad_watch FILE BODY WANT: the fixture FILE holds BODY, update still exits 0 and prints "could not check WANT".
bad_watch() {
  watch_base
  printf '%s' "$2" > "$T/fix/$1"
  run "$T" update
  rc_is 0
  out_has "could not check $3"
  lacks_text 'an upstream fix may have landed'
  changed_is
}

t_watch_bad_input() {
  local ge="GE-Proton's latest release" wine='Wine master'
  bad_watch protocol.def '' "$wine"
  bad_watch protocol.def $'@REQ(set_job_limits)\n    unsigned int limit_flags;\n@END\n' "$wine"
  bad_watch issue57 '' 'w3champions-issues #57'
  bad_watch issue57 'not json' 'w3champions-issues #57'
  bad_watch issue57 '{"state": "OPEN"}' 'w3champions-issues #57'
  bad_watch issue57 '{"state": 7}' 'w3champions-issues #57'
  bad_watch ge-latest '' "$ge"
  bad_watch ge-latest '{"tag_name": "GE-Próton11-8"}' "$ge"
  bad_watch ge-latest '{"tag_name": "../x"}' "$ge"
}

t_watch_twice() {
  local o
  watch_base
  run "$T" update
  o=$OUT
  run "$T" update
  rc_is 0
  [ "$OUT" = "$o" ] || ERRS+=('the second watch block differs')
  changed_is
}

# ---------- old-build removal (UPD-02, D-15) ----------

# prev_setup: the state after an update switched TAG -> T8: both builds complete, Battle.net and proton-tag on T8, proton-tag.prev on TAG.
prev_setup() {
  mk_siblings "$T"
  mk_installed "$T"
  mk_installed "$T" "$T8"
  seed_tag "$T" "$T8"
  printf '%s\n' "$TAG" > "$T/home/.local/state/w3c-linux/proton-tag.prev"
  bn_set4 "$T" runner "$T8"
  mk_release "$T" "$T8"
}

# prev_question: the removal question for TAG (replaced by T8), exactly.
prev_question() { printf 'Remove %s (about 1.5 GB)? Only if a ladder match on %s worked. [y/N]' "$TAG" "$T8"; }

# prev_removed: exactly the TAG build and proton-tag.prev are gone, T8 and the siblings stand.
prev_removed() {
  local c=$COMPAT_REL/$TAG
  [ ! -e "$T/$c" ] || ERRS+=("$TAG still exists")
  prev_is ''
  build_ok "$T/$COMPAT_REL/$T8"
  tag_is "$T8"
  runner_is "$T8"
  siblings_untouched
  changed_is "$c" "$c/compatibilitytool.vdf" "$c/files" "$c/files/bin" "$c/files/bin/wine" "$c/proton" "$c/version" home/.local/state/w3c-linux/proton-tag.prev
}

# prev_kept: nothing changed, TAG and proton-tag.prev stand.
prev_kept() {
  build_ok "$T/$COMPAT_REL/$TAG"
  prev_is "$TAG"
  unchanged_games
  changed_is
}

# no_remove_q: no removal question was asked.
no_remove_q() { case $ERR in *'Remove '*) ERRS+=('a removal question was asked') ;; esac; }

t_prev_offer_update() {
  prev_setup
  FEED=$'y\n'
  run "$T" update
  rc_is 0
  err_has "$(prev_question)"
  out_has "Removed $T/$COMPAT_REL/$TAG."
  prev_removed
}

t_prev_default_no() {
  prev_setup
  FEED=$'\n'
  run "$T" update
  rc_is 0
  err_has "$(prev_question)"
  out_has "Kept $TAG; you will be asked again on the next run."
  prev_kept
  run "$T" update
  rc_is 0
  err_has "$(prev_question)"
  prev_kept
}

t_prev_offer_install() {
  prev_setup
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 0
  err_has "$(prev_question)"
  prev_removed
  no_umu
}

t_prev_not_when_used() {
  prev_setup
  other_runner "$T" "$TAG"
  FEED=$'y\n'
  run "$T" update
  rc_is 0
  no_remove_q
  prev_kept
}

t_prev_not_in_switch_run() {
  prev_setup
  mk_release "$T" GE-Proton11-9-W3C
  FEED=$'n\n'
  run "$T" update
  rc_is 0
  err_has "Install GE-Proton11-9-W3C (about 1.1 GB) and switch"
  no_remove_q
  prev_kept
}

t_prev_busy() {
  prev_setup
  add_proc "$T" 4242 Battle.net.exe 'C:\Program Files (x86)\Battle.net\Battle.net.exe'
  mv "$T/fix/procs" "$T/fix/procs.late"
  printf '1\n' > "$T/fix/late-after"
  FEED=$'y\n'
  run "$T" update
  rc_is 1
  err_has "$(prev_question)"
  err_has $'Still running:\n\n    Battle.net'
  out_has "update: something started again (listed above); $TAG was not removed"
  prev_kept
}

t_prev_unsafe() {
  prev_setup
  mkdir "$T/home/.local/share/Steam/x"
  printf '../x\n' > "$T/home/.local/state/w3c-linux/proton-tag.prev"
  FEED=$'y\n'
  run "$T" update
  rc_is 0
  no_remove_q
  [ -d "$T/home/.local/share/Steam/x" ] || ERRS+=('../x was removed')
  changed_is
}

t_prev_missing_dir() {
  prev_setup
  printf 'GE-Proton11-6-W3C\n' > "$T/home/.local/state/w3c-linux/proton-tag.prev"
  FEED=$'y\n'
  run "$T" update
  rc_is 0
  no_remove_q
  changed_is
}

# ---------- revert steps back one W3C build (PRT-05 as amended, D-16) ----------

# back_setup: prev_setup plus the pre-W3C backup.
back_setup() {
  prev_setup
  mk_bak "$T" 20260101-000000-100000 'Proton-GE Latest'
}

# back_question: the step-back question, exactly.
back_question() { printf 'Switch Battle.net back to the previous W3C build %s? (%s stays installed) [Y/n]' "$TAG" "$T8"; }

# phase2_path: revert took the Phase 2 path: the pre-W3C question and no step-back question.
phase2_path() {
  err_has 'back to Proton-GE Latest'
  case $ERR in *'previous W3C build'*) ERRS+=('the step-back question was asked') ;; esac
}

t_back_step() {
  back_setup
  FEED=$'y\n\n'
  run "$T" revert
  rc_is 0
  err_has "$(back_question)"
  case $ERR in *'back to Proton-GE Latest'*) ERRS+=('the Phase 2 question was asked') ;; esac
  runner_is "$TAG"
  tag_is "$TAG"
  prev_is ''
  bak_count 2
  out_has "Kept $T8"
  build_ok "$T/$COMPAT_REL/$T8"
  build_ok "$T/$COMPAT_REL/$TAG"
  siblings_untouched
}

t_back_step_remove_newer() {
  back_setup
  FEED=$'y\ny\n'
  run "$T" revert
  rc_is 0
  runner_is "$TAG"
  tag_is "$TAG"
  prev_is ''
  out_has "Removed $T/$COMPAT_REL/$T8."
  [ ! -e "$T/$COMPAT_REL/$T8" ] || ERRS+=("$T8 still exists")
  build_ok "$T/$COMPAT_REL/$TAG"
  siblings_untouched
}

t_back_declined() {
  back_setup
  FEED=$'n\n'
  run "$T" revert
  rc_is 0
  out_has 'Nothing was changed.'
  case $ERR in *'Remove '* | *'back to Proton-GE Latest'*) ERRS+=('a second question was asked') ;; esac
  runner_is "$T8"
  tag_is "$T8"
  prev_is "$TAG"
  unchanged_games_keep_bak
  changed_is
}

t_back_prev_incomplete() {
  back_setup
  rm "$T/$COMPAT_REL/$TAG/proton"
  FEED=$'y\n\n'
  run "$T" revert
  rc_is 0
  phase2_path
  runner_is 'Proton-GE Latest'
}

t_back_prev_is_runner() {
  back_setup
  printf '%s\n' "$T8" > "$T/home/.local/state/w3c-linux/proton-tag.prev"
  FEED=$'y\n\n'
  run "$T" revert
  rc_is 0
  phase2_path
  runner_is 'Proton-GE Latest'
  build_ok "$T/$COMPAT_REL/$T8"
}

t_back_busy() {
  back_setup
  add_proc "$T" 4242 Battle.net.exe 'C:\Program Files (x86)\Battle.net\Battle.net.exe'
  mv "$T/fix/procs" "$T/fix/procs.late"
  printf '1\n' > "$T/fix/late-after"
  FEED=$'y\n'
  run "$T" revert
  rc_is 1
  err_has "$(back_question)"
  err_has $'Still running:\n\n    Battle.net'
  out_has 'revert: something started again (listed above); games.json was not changed'
  runner_is "$T8"
  tag_is "$T8"
  prev_is "$TAG"
  unchanged_games_keep_bak
  changed_is
}

t_back_chain() {
  back_setup
  FEED=$'y\n\n'
  run "$T" revert
  rc_is 0
  runner_is "$TAG"
  FEED=$'y\n\n'
  run "$T" revert
  rc_is 0
  phase2_path
  runner_is 'Proton-GE Latest'
  build_ok "$T/$COMPAT_REL/$T8"
  build_ok "$T/$COMPAT_REL/$TAG"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
