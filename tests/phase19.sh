#!/usr/bin/env bash
# Phase 19 fixture check: install, update and revert under the Steam backend (STEAM-06, STEAM-07, STEAM-08). It runs on the harness of
# tests/phase18.sh, so the same fake HOME, shims and invariants apply. The shortcut's tool is a recording `proton` shim: argv in marks/proton,
# its environment in marks/proton.env, and T/fix/on-proton.sh (when a case writes one) plays the file effects of Wine inside the prefix.
# No case runs Steam, a real Proton or a network call.
# Usage: bash tests/phase19.sh [GLOB]   (GLOB filters on display names such as steam-install-tracer)
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=phase18.sh
source "$(dirname "${BASH_SOURCE[0]}")/phase18.sh"

# this suite has its own cases only
mapfile -t P18_CASES < <(compgen -A function t_)
unset -f "${P18_CASES[@]}"

# pgrep (the idle checks) and pkill (the Edge updater) are expected here; Wine, Steam and umu must never run
FORBIDDEN=(wine wineserver faugus-launcher steam-runtime-launch-client sudo umu-run nft iptables notify-send steam)

# the Steam prefix relative to T, for ALLOW_EXTRA
SP_REL=home/.local/share/Steam/steamapps/compatdata/3389133332/pfx

# the Phase 3 allow lists with the Faugus prefix swapped for the Steam one
WV2_ALLOW_S=("${WV2_ALLOW[@]//home\/Faugus\/battlenet/$SP_REL}")
REG_ALLOW_S=("${REG_ALLOW[@]//home\/Faugus\/battlenet/$SP_REL}")

# ---------- helpers ----------

# fill_build DIR TAG: the four entries of a complete build, as tests/phase2.sh has them, except that `proton` records what Steam's Proton would
# be asked: argv to marks/proton, the environment to marks/proton.env, then the effects of $FIX/on-proton.sh with the leading `run` dropped and
# WINEPREFIX set the way Proton sets it. mk_steam, mk_installed and mk_release call this at run time, so every build in this suite carries it.
fill_build() {
  mkdir -p "$1/files/bin"
  cat > "$1/proton" <<'SH'
#!/bin/sh
printf '%s\n' "$0 $*" >> "$MARK/proton"
{ echo '== call =='; env; } >> "$MARK/proton.env"
[ "${1-}" != run ] || shift
WINEPREFIX=$STEAM_COMPAT_DATA_PATH/pfx
export WINEPREFIX
[ -f "$FIX/on-proton.sh" ] && . "$FIX/on-proton.sh"
exit 0
SH
  chmod +x "$1/proton"
  printf '"compatibilitytools"\n{\n}\n' > "$1/compatibilitytool.vdf"
  printf '1700000000 %s\n' "$2" > "$1/version"
  : > "$1/files/bin/wine"
}

# steam_tree: mk_steam with the real four-line config_info (line 4 is the client path Steam stamped: the root's realpath) and the root's steam.sh.
steam_tree() {
  mk_steam
  printf '%s\n' "$SR" >> "$SR/steamapps/compatdata/3389133332/config_info"
  : > "$SR/steam.sh"
}

# proton_hook TEXT: what the proton shim sources when it runs (the file effects of Wine).
proton_hook() { printf '%s\n' "$1" > "$T/fix/on-proton.sh"; }

# proton_count N: proton ran exactly N times.
proton_count() {
  local n=0
  [ ! -f "$T/marks/proton" ] || n=$(wc -l < "$T/marks/proton")
  [ "$n" = "$1" ] || ERRS+=("proton calls: want $1 got $n")
}

# proton_env_has KV: some call's environment holds exactly the line KV.
proton_env_has() { grep -qxF -- "$1" "$T/marks/proton.env" 2> /dev/null || ERRS+=("proton env lacks: $1"); }

# steam_pfx_server_name: the server dir name Wine derives from the Steam prefix's device and inode, computed here without the script.
steam_pfx_server_name() {
  python3 -c 'import os, sys; st = os.stat(sys.argv[1]); print("server-%x-%x" % (st.st_dev, st.st_ino))' "$SR/steamapps/compatdata/3389133332/pfx"
}

# steam_ci4 TEXT: config_info's line 4 (the client path Steam stamped) becomes TEXT; the first three lines stay as mk_steam wrote them.
steam_ci4() {
  printf 'x\nx\n%s/compatibilitytools.d/%s/files/lib/\n%s\n' "$SR" "$TAG" "$1" > "$SR/steamapps/compatdata/3389133332/config_info"
}

# msi_steam_setup: the launcher is the only thing missing from a complete shortcut; a hook installs it and the two prefix paths it writes are allowed.
msi_steam_setup() {
  no_launcher "$T"
  steam_tree
  steam_on
  mk_release "$T"
  proton_hook "$MSI_HOOK"
  ALLOW_EXTRA+=("$SP_REL/system.reg" "$SP_REL/drive_c/Program Files/W3Champions/W3Champions.exe")
}

# ---------- STEAM-07: install provisions the shortcut's own prefix ----------

# The tracer: a complete shortcut whose prefix lacks the launcher. install takes the launcher from latest.json to the recorded version through
# one host-side `proton run` with Steam's environment; doctor then reads it at the latest.
t_steam_install_tracer() {
  local msi=$T/home/.cache/w3c-linux/launcher/W3Champions_1.6.16_x64_en-US.msi cdp v
  no_launcher "$T"
  steam_tree
  cdp=$SR/steamapps/compatdata/3389133332
  steam_on
  mk_release "$T"
  proton_hook "$MSI_HOOK"
  ALLOW_EXTRA+=("$SP_REL/system.reg" "$SP_REL/drive_c/Program Files/W3Champions/W3Champions.exe")
  FEED=$'y\n'
  run "$T" install
  rc_is 0
  err_has 'Install W3Champions 1.6.16 (latest)? [Y/n]'
  proton_count 1
  case $(cat "$T/marks/proton" 2> /dev/null) in
    "$SR/compatibilitytools.d/$TAG/proton run msiexec /i $(zpath "$msi") /qn") ;;
    *) ERRS+=("proton argv: $(cat "$T/marks/proton" 2> /dev/null)") ;;
  esac
  for v in "STEAM_COMPAT_DATA_PATH=$cdp" "STEAM_COMPAT_CLIENT_INSTALL_PATH=$SR" STEAM_COMPAT_APP_ID=3389133332 SteamAppId=3389133332 SteamGameId=3389133332; do
    proton_env_has "$v"
  done
  [ ! -e "$cdp/pfx/pfx" ] || ERRS+=('a nested pfx/pfx appeared')
  [ "$(find "$SR/steamapps/compatdata" -mindepth 1 -maxdepth 1 -printf '%f\n')" = 3389133332 ] || ERRS+=('compatdata holds more than the shortcut directory')
  [ "$(launcher_rec)" = 1.6.16 ] || ERRS+=("launcher record is $(launcher_rec)")
  out_has 'Next: press Play on the shortcut in Steam.'
  err_has 'Launch now? Steam starts the shortcut [Y/n]'   # EOF answers No
  [ -e "$T/home/.local/share/applications/w3c-linux.desktop" ] || ERRS+=('no desktop entry was written')
  unset FEED
  run "$T" doctor
  has_line pass 'launcher version' '1.6.16 (installed 1.6.16, recorded 1.6.16, latest 1.6.16)'
  changed_is
}

# WebView2, the registry and the launcher all missing: install runs the four steps through the same executor, each with Steam's environment and
# nothing of umu's, and no nested pfx/pfx appears.
t_steam_exec_env() {
  local cdp tool inst=$T/home/.cache/w3c-linux/webview2/$WV2_INSTALLER msi=$T/home/.cache/w3c-linux/launcher/W3Champions_1.6.16_x64_en-US.msi
  local -a got=() want=()
  local i
  no_wv2 "$T"
  reg_drop "$T" 'Allow Local Files'
  no_launcher "$T"
  steam_tree
  cdp=$SR/steamapps/compatdata/3389133332
  tool=$SR/compatibilitytools.d/$TAG/proton
  steam_on
  mk_release "$T"
  proton_hook "$WV2_HOOK"$'\n'"$REG_HOOK"$'\n'"$MSI_HOOK"
  ALLOW_EXTRA+=("${WV2_ALLOW_S[@]}" "${REG_ALLOW_S[@]}" "$SP_REL/drive_c/Program Files/W3Champions/W3Champions.exe")
  FEED=$'y\ny\ny\n'
  run "$T" install
  rc_is 0
  proton_count 4
  mapfile -t got < "$T/marks/proton"
  want=("$tool run $(zpath "$inst") /silent /install" "$tool run regedit /S $(zpath "$T/home/.cache/w3c-linux/w3c.reg")" "$tool run winecfg -v win10"
    "$tool run msiexec /i $(zpath "$msi") /qn")
  for i in 0 1 2 3; do
    [ "${got[i]-}" = "${want[i]}" ] || ERRS+=("proton call $((i + 1)): want [${want[i]}] got [${got[i]-}]")
  done
  [ "$(grep -cxF "STEAM_COMPAT_DATA_PATH=$cdp" "$T/marks/proton.env")" = 4 ] || ERRS+=('not every call carries STEAM_COMPAT_DATA_PATH')
  ! grep -qE '^(WINEPREFIX|PROTONPATH|PROTON_VERB)=' "$T/marks/proton.env" || ERRS+=("a call carries an umu variable")
  [ ! -e "$cdp/pfx/pfx" ] || ERRS+=('a nested pfx/pfx appeared')
  out_has 'Install complete: the Steam shortcut runs on '
}

# the client path is Steam's own string: config_info line 4 as written, even when it is a symlink spelling of the root
t_steam_exec_client_link() {
  msi_steam_setup
  steam_ci4 "$T/home/.steam/root"
  FEED=$'y\n'
  run "$T" install
  rc_is 0
  proton_count 1
  proton_env_has "STEAM_COMPAT_CLIENT_INSTALL_PATH=$T/home/.steam/root"
}

# a line 4 that names a directory without steam.sh is not trusted: the found root is used
t_steam_exec_client_fallback() {
  msi_steam_setup
  steam_ci4 "$T/home/.local/share"
  FEED=$'y\n'
  run "$T" install
  rc_is 0
  proton_count 1
  proton_env_has "STEAM_COMPAT_CLIENT_INSTALL_PATH=$SR"
}

# D-11: the mapping moves to proton_9 while the WebView2 step runs, so the next step refuses and nothing more runs
t_steam_exec_remap() {
  no_wv2 "$T"
  reg_drop "$T" 'Allow Local Files'
  steam_tree
  steam_on
  mk_release "$T"
  proton_hook "$WV2_HOOK"$'\n'"sed -i 's/\"$TAG\"/\"proton_9\"/' \"\$HOME/.local/share/Steam/config/config.vdf\""
  ALLOW_EXTRA+=("${WV2_ALLOW_S[@]}" home/.local/share/Steam/config/config.vdf)
  FEED=$'y\ny\n'
  run "$T" install
  rc_is 1
  proton_count 1
  out_has 'in-prefix step refused: the Steam shortcut runs on proton_9, not an installed W3C build; nothing was run in the prefix'
}

# ---------- STEAM-07: the idle gate's Steam arm ----------

# the shortcut's own processes block provisioning: the install with the MSI wanted stops at the wait on q, before any Proton call
t_steam_idle_busy() {
  local c label
  msi_steam_setup
  for c in reaper w3c wc3 bnet wineserver; do
    : > "$T/fix/procs"
    rm -f "$T/marks/"*
    case $c in
      reaper) label='the Steam shortcut (appid 3389133332)'; add_proc "$T" 4001 reaper 'reaper SteamLaunch AppId=3389133332 -- /x/proton waitforexitandrun /x/y.exe' ;;
      w3c) label=W3Champions; add_proc "$T" 4001 W3Champions.exe 'C:\Program Files\W3Champions\W3Champions.exe' ;;
      wc3) label='Warcraft III'; add_proc "$T" 4001 'Warcraft III.exe' 'C:\Program Files (x86)\Warcraft III\_retail_\x86_64\Warcraft III.exe' ;;
      bnet) label=Battle.net; add_proc "$T" 4001 Battle.net.exe 'Z:\x\Battle.net.exe' ;;
      wineserver) label='a Wine process in the Battle.net prefix is still running (wineserver)'; add_wineserver "$T" 4001 "$(steam_pfx_server_name)" ;;
    esac
    FEED=$'y\nq\n'
    run "$T" install
    rc_is 1
    err_has "    $label"
    proton_count 0
    out_has 'Stopped while waiting; the prefix was not changed.'
    lacks_text games.json
  done
}

# Steam itself, another appid with the same leading digits and Faugus's processes and running state never block it
t_steam_idle_not_busy() {
  msi_steam_setup
  add_proc "$T" 4001 reaper 'reaper SteamLaunch AppId=33891333320 -- /x/proton waitforexitandrun /x/y.exe'
  add_proc "$T" 4002 steam '/x/ubuntu12_32/steam'
  add_proc "$T" 4003 python3 'python3 -m faugus.tray_only'
  set_running_games "$T" '{"battlenet": {"pid": 4242}}'
  FEED=$'y\n'
  run "$T" install
  rc_is 0
  proton_count 1
}

# ---------- STEAM-06: the guided checklist ----------

# the six checklist labels, as steam_steps words them
LBL=('' 'Add the Battle.net shortcut' "Select $TAG as its compatibility tool" 'Play once: Battle.net installs into the new prefix'
  'Point the shortcut at Battle.net.exe' 'Sign in, install Warcraft III, start it once, exit Battle.net' 'Point the shortcut at W3Champions.exe')

# sprep: a complete Steam shortcut with the backend selected and the release served; cases then break one thing.
sprep() {
  steam_tree
  steam_on
  mk_release "$T"
}

# out_line TEXT: stdout holds TEXT as a whole line.
out_line() { grep -qxF -- "$1" <<< "$OUT" || ERRS+=("output lacks the line: $1"); }

# ck_marks MARKS: the checklist header and the six lines, MARKS is six characters, x (done) or a space (not done); the prompt is on stderr.
ck_marks() {
  local i
  out_line "Steam steps (checked from Steam's files; [x] done):"
  for i in 1 2 3 4 5 6; do out_line "  [${1:i-1:1}] $i. ${LBL[i]}"; done
  err_has 'press Enter to check again (q to quit): '
  case $OUT$ERR in *'Remove non-Steam'* | *'Remove from library'*) ERRS+=('the text offers removing the shortcut') ;; esac
}

# the click-path lines of a retarget step, four spaces in: Target, Start In and Launch Options
ck_retarget() {
  out_line "    Target: \"$1/$2\""
  out_line "    Start In: \"$1/\""
  out_line "    Launch Options: $3"
}

# D-03: the mapping names another tool; the click path says restart Steam and pick the build, and the prior tool is kept for revert
t_steam_checklist_select() {
  sprep
  mk_mapping 3389133332:proton_experimental
  run "$T" install
  rc_is 1
  ck_marks 'x xxxx'
  out_line "Step 2: ${LBL[2]}"
  out_line '    Steam is not running: start Steam first.'
  out_line '    Restart Steam (Steam menu > Exit, then start Steam again): Steam lists a new compatibility tool only after a restart.'
  out_line "    Then right-click the shortcut > Properties > Compatibility > turn on \"Show all compatibility tools\" > Select compatibility tool > $TAG"
  out_line "Stopped; rerun w3c-linux.sh install to continue."
  [ "$(cat "$T/home/.local/state/w3c-linux/steam-prev-tool" 2> /dev/null)" = proton_experimental ] || ERRS+=('steam-prev-tool is not proton_experimental')
  changed_is home/.local/state/w3c-linux/steam-prev-tool
  # Steam running: no start-Steam line; the saved name is not overwritten
  mkdir -p "$T/proc/4242"
  printf 'steam\n' > "$T/proc/4242/comm"
  printf '4242\n' > "$T/home/.steam/steam.pid"
  mk_mapping 3389133332:proton_9
  run "$T" install
  rc_is 1
  lacks_text 'Steam is not running'
  [ "$(cat "$T/home/.local/state/w3c-linux/steam-prev-tool" 2> /dev/null)" = proton_experimental ] || ERRS+=('steam-prev-tool was overwritten')
  changed_is
}

t_steam_checklist_prefix() {
  sprep
  rm -r "$SR/steamapps/compatdata/3389133332/pfx"
  run "$T" install
  rc_is 1
  ck_marks 'xx   x'
  out_line "Step 3: ${LBL[3]}"
  out_line '    Press Play on the shortcut: the Battle.net installer runs in the new prefix; keep its default install location.'
}

t_steam_checklist_bnet() {
  local pfx
  sprep
  pfx=$SR/steamapps/compatdata/3389133332/pfx
  sc_edit "$SR/userdata/12345678/config/shortcuts.vdf" set 3389133332 Exe '"/x/Battle.net-Setup.exe"'
  rm -r "$pfx/drive_c/users/steamuser/Documents/Warcraft III"
  run "$T" install
  rc_is 1
  ck_marks 'xxx   '
  out_line "Step 4: ${LBL[4]}"
  out_line '    Right-click the shortcut > Properties > Shortcut, and set:'
  ck_retarget "$pfx/drive_c/Program Files (x86)/Battle.net" Battle.net.exe 'WINE_SIMULATE_WRITECOPY=1 PROTON_ENABLE_WAYLAND=0 %command%'
}

t_steam_checklist_wc3() {
  sprep
  sc_edit "$SR/userdata/12345678/config/shortcuts.vdf" set 3389133332 Exe '"/x/Battle.net.exe"'
  rm -r "$SR/steamapps/compatdata/3389133332/pfx/drive_c/users/steamuser/Documents/Warcraft III"
  run "$T" install
  rc_is 1
  ck_marks 'xxxx  '
  out_line "Step 5: ${LBL[5]}"
  out_line '    Press Play, sign in to Battle.net and install Warcraft III at its default location.'
  out_line '    Start Warcraft III once (Battle.net > Warcraft III > Play), close it, then quit Battle.net (its menu > Exit).'
}

# everything provisioned and the shortcut on Battle.net.exe: no question, the last click is the W3Champions.exe retarget
t_steam_checklist_last() {
  local pfx
  sprep
  pfx=$SR/steamapps/compatdata/3389133332/pfx
  sc_edit "$SR/userdata/12345678/config/shortcuts.vdf" set 3389133332 Exe '"/x/Battle.net.exe"'
  run "$T" install
  rc_is 1
  ck_marks 'xxxxx '
  case $ERR in *'[Y/n]'* | *'[y/N]'*) ERRS+=('a question was asked') ;; esac
  out_line "Step 6: ${LBL[6]}"
  ck_retarget "$pfx/drive_c/Program Files/W3Champions" W3Champions.exe "$(default_opts)"
}

# ---------- STEAM-06: the wait loop ----------

# Enter re-reads Steam's files: the user maps the tool while install waits, and the walk goes on
t_steam_install_recheck() {
  sprep
  mk_mapping 1000000:proton_9
  ALLOW_EXTRA+=(home/.local/share/Steam/config/config.vdf)
  run_fifo "$T" install
  wait_err 'press Enter to check again'
  mk_mapping "3389133332:$TAG"
  send $'\n'
  finish
  rc_is 0
  out_has 'Install complete'
  [ "$(grep -c '^Step 2:' <<< "$OUT")" = 1 ] || ERRS+=('Step 2 was not printed exactly once')
}

t_steam_install_quit() {
  sprep
  mk_mapping 1000000:proton_9
  FEED=$'q\n'
  run "$T" install
  rc_is 1
  out_line 'Stopped; rerun w3c-linux.sh install to continue.'
  lacks_text 'Install complete'
  case $ERR in *'no answer'*) ERRS+=('q was reported as no answer') ;; esac
  changed_is
  # D-19: EOF at the prompt says so on stderr, then stops the same way
  unset FEED
  run "$T" install
  rc_is 1
  err_has 'no answer (stdin closed); run in a terminal'
  out_line 'Stopped; rerun w3c-linux.sh install to continue.'
}

# a stopped run resumes at the first step not done and says nothing about the done ones
t_steam_install_rerun() {
  sprep
  mk_mapping 1000000:proton_9
  run "$T" install
  rc_is 1
  out_has 'Step 2: '
  mk_mapping "3389133332:$TAG"
  ALLOW_EXTRA+=(home/.local/share/Steam/config/config.vdf)
  run "$T" install
  rc_is 0
  out_has 'Install complete'
  ! grep -q '^Step ' <<< "$OUT" || ERRS+=('the rerun printed a Step line')
}

# hard stops: one reason line, no wait, no download
no_wait_no_curl() {
  case $ERR in *'press Enter'*) ERRS+=('install waited') ;; esac
  [ ! -e "$T/marks/curl" ] || ERRS+=('curl ran')
}

t_steam_install_stop_several() {
  sprep
  sc_edit "$SR/userdata/12345678/config/shortcuts.vdf" add 'Battle.net 2' 4000000001 '"/x/Battle.net.exe"'
  run "$T" install
  rc_is 1
  out_line 'install: more than one shortcut matches: set W3C_STEAM_APPID=<appid> to pick one (w3c-linux.sh doctor shows every check)'
  no_wait_no_curl
}

t_steam_install_stop_noaccount() {
  sprep
  rm "$SR/config/loginusers.vdf"
  run "$T" install
  rc_is 1
  out_has 'start Steam and sign in once (w3c-linux.sh doctor shows every check)'
  no_wait_no_curl
}

t_steam_install_stop_badvdf() {
  sprep
  sc_edit "$SR/userdata/12345678/config/shortcuts.vdf" badtype
  run "$T" install
  rc_is 1
  out_has 'install: shortcuts.vdf is unreadable or malformed: '
  no_wait_no_curl
}

t_steam_install_stop_override() {
  sprep
  CASE_ENV=(W3C_STEAM_APPID=12x)
  run "$T" install
  rc_is 1
  out_line 'install: W3C_STEAM_APPID is not an appid (digits only, at most 4294967295) (w3c-linux.sh doctor shows every check)'
  no_wait_no_curl
  CASE_ENV=(W3C_STEAM_APPID=999)
  run "$T" install
  rc_is 1
  out_line 'install: W3C_STEAM_APPID=999 names no shortcut in shortcuts.vdf (w3c-linux.sh doctor shows every check)'
  no_wait_no_curl
}

# ---------- STEAM-06: from scratch, the Battle.net installer ----------

BN_URL='https://www.battle.net/download/getInstallerForGame?os=win&version=LIVE&gameProgram=BATTLENET_APP'

# steam_hashes: the hashes of the four Steam files install must never write, run from the Steam root.
steam_hashes() {
  (cd "$SR" && sha256sum userdata/*/config/shortcuts.vdf config/config.vdf config/loginusers.vdf steamapps/libraryfolders.vdf)
}

# bn_serve TEXT: the installer Blizzard's URL answers with.
bn_serve() { printf '%s' "$1" > "$T/fix/${BN_URL##*/}"; }

# no shortcut at all: install downloads the installer to ~/Downloads with one https-only curl and step 1 names that file
t_steam_install_none() {
  local f=$T/home/Downloads/Battle.net-Setup.exe
  sprep
  rm "$SR/userdata/12345678/config/shortcuts.vdf"
  bn_serve 'MZ fake installer'
  ALLOW_EXTRA+=(home/Downloads home/Downloads/Battle.net-Setup.exe)
  run "$T" install
  rc_is 1
  [ "$(cat "$f" 2> /dev/null)" = 'MZ fake installer' ] || ERRS+=('the installer is not in ~/Downloads')
  grep -F -e "$BN_URL" "$T/marks/curl" | grep -qF -e '--proto =https --proto-redir =https' || ERRS+=('no https-only curl of the Battle.net URL')
  ck_marks '      '
  out_line "Step 1: ${LBL[1]}"
  out_line '    Steam: Games > Add a Non-Steam Game to My Library > Browse...'
  out_line "    In the file picker press Ctrl+L, paste $f, set the All Files filter, then Select > Add Selected Programs"
  [ -z "$(find "$T/home/Downloads" -name '.Battle.net-Setup.exe.*' 2> /dev/null)" ] || ERRS+=('a temp file is left')
}

# XDG_DOWNLOAD_DIR is read as data: the quoted $HOME is expanded by the script, and the command in another line never runs
t_steam_install_xdg_download() {
  sprep
  rm "$SR/userdata/12345678/config/shortcuts.vdf"
  bn_serve 'MZ fake installer'
  mkdir -p "$T/home/Dl"
  printf '%s\n' "XDG_DOWNLOAD_DIR=\"\$HOME/Dl\"" "XDG_MUSIC_DIR=\"\$(mkdir \$HOME/pwned)\"" > "$T/home/.config/user-dirs.dirs"
  ALLOW_EXTRA+=(home/Dl/Battle.net-Setup.exe)
  run "$T" install
  rc_is 1
  [ -f "$T/home/Dl/Battle.net-Setup.exe" ] || ERRS+=('the installer is not in the XDG download directory')
  [ ! -e "$T/home/pwned" ] || ERRS+=('a command in user-dirs.dirs ran')
  [ ! -e "$T/home/Downloads" ] || ERRS+=('the default download directory was created')
}

# XDG_DOWNLOAD_DIR="$HOME/" is the xdg-user-dirs "disabled" value: the installer goes to ~/Downloads, not into the home directory
t_steam_install_xdg_disabled() {
  sprep
  rm "$SR/userdata/12345678/config/shortcuts.vdf"
  bn_serve 'MZ fake installer'
  printf '%s\n' "XDG_DOWNLOAD_DIR=\"\$HOME/\"" > "$T/home/.config/user-dirs.dirs"
  ALLOW_EXTRA+=(home/Downloads home/Downloads/Battle.net-Setup.exe)
  run "$T" install
  rc_is 1
  [ -f "$T/home/Downloads/Battle.net-Setup.exe" ] || ERRS+=('the installer is not in ~/Downloads')
  [ ! -e "$T/home/Battle.net-Setup.exe" ] || ERRS+=('the installer landed in the home directory')
}

# a body without MZ, or a failed curl: nothing stays in the download directory and install does not wait
t_steam_install_setup_bad() {
  local d=$T/home/Downloads
  sprep
  rm "$SR/userdata/12345678/config/shortcuts.vdf"
  bn_serve 'not an executable'
  ALLOW_EXTRA+=(home/Downloads)
  run "$T" install
  rc_is 1
  out_line "install: Battle.net installer download failed ($BN_URL); nothing was saved in $d"
  [ -z "$(find "$d" -type f 2> /dev/null)" ] || ERRS+=("the download directory holds: $(find "$d" -type f 2> /dev/null)")
  case $ERR in *'press Enter'*) ERRS+=('install waited') ;; esac
  rm "$T/fix/${BN_URL##*/}"
  run "$T" install
  rc_is 1
  out_line "install: Battle.net installer download failed ($BN_URL); nothing was saved in $d"
  [ -z "$(find "$d" -type f 2> /dev/null)" ] || ERRS+=("the download directory holds after a curl failure: $(find "$d" -type f 2> /dev/null)")
}

t_steam_install_setup_kept() {
  local f=$T/home/Downloads/Battle.net-Setup.exe
  sprep
  rm "$SR/userdata/12345678/config/shortcuts.vdf"
  mkdir -p "$T/home/Downloads"
  printf 'MZ kept' > "$f"
  run "$T" install
  rc_is 1
  out_line "Battle.net installer: $f (already downloaded)"
  out_has "paste $f,"
  [ "$(cat "$f")" = 'MZ kept' ] || ERRS+=('the kept installer changed')
  ! grep -qF getInstallerForGame "$T/marks/curl" 2> /dev/null || ERRS+=('the installer was downloaded again')
  changed_is
}

# a corrupted SHA256SUMS: no build, no record, no cache file, no staging directory, and no wait
t_steam_install_sha() {
  local c
  sprep
  c=$SR/compatibilitytools.d
  rm -rf "${c:?}/$TAG" "$T/home/.local/state/w3c-linux/proton-tag"
  printf '%s  %s.tar.gz\n' "$(printf '0%.0s' {1..64})" "$TAG" > "$T/fix/SHA256SUMS"
  FEED=$'y\n'
  run "$T" install
  rc_is 1
  out_has "install: SHA256 mismatch for $TAG.tar.gz"
  [ ! -e "$c/$TAG" ] || ERRS+=('the build directory exists')
  [ ! -e "$T/home/.local/state/w3c-linux/proton-tag" ] || ERRS+=('proton-tag exists')
  ! compgen -G "$c/.w3c-staging.*" > /dev/null || ERRS+=('a staging directory is left')
  cache_empty
  case $ERR in *'press Enter'*) ERRS+=('install waited') ;; esac
}

t_steam_install_lock() {
  local fd
  sprep
  mkdir -p "$T/home/.local/state/w3c-linux"
  exec {fd}> "$T/home/.local/state/w3c-linux/lock"
  flock -n "$fd"
  run "$T" install
  exec {fd}>&-
  rc_is 1
  out_has 'another w3c-linux.sh run is in progress'
  ! grep -q '^Step ' <<< "$OUT" || ERRS+=('a Step line was printed')
}

# a complete shortcut: nothing to ask (but the closing launch offer, Phase 20), nothing to run, nothing to change, twice
t_steam_install_twice() {
  local i e
  sprep
  for i in 1 2; do
    run "$T" install
    rc_is 0
    out_has 'Install complete'
    e=${ERR//'Launch now? Steam starts the shortcut [Y/n]'/}
    case $e in *'[Y/n]'* | *'[y/N]'*) ERRS+=("run $i asked a question") ;; esac
    proton_count 0
    changed_is
  done
}

# ---------- STEAM-06: install never writes Steam's files ----------

t_steam_nowrite_install() {
  local before after p
  msi_steam_setup
  before=$(steam_hashes)
  FEED=$'y\n'
  run "$T" install
  rc_is 0
  out_has 'Install complete'
  after=$(steam_hashes)
  [ "$before" = "$after" ] || ERRS+=('a Steam file changed')
  for p in "${CHANGED[@]}"; do
    case $p in
      home/.local/share/Steam/compatibilitytools.d | home/.local/share/Steam/compatibilitytools.d/* | "$SP_REL" | "$SP_REL"/*) ;;
      home/.local/share/Steam | home/.local/share/Steam/*) ERRS+=("a path under the Steam root changed: $p") ;;
    esac
  done
}

# update never writes Steam's files: a launcher update and a new-build update leave the four hash the same and change nothing under the Steam
# root but the build directories and the prefix
t_steam_nowrite_update() {
  local before p run_n
  supd_setup 1.6.15
  for run_n in 1 2; do
    if [ "$run_n" = 2 ]; then
      mk_mapping 3389133332:proton_9
      mk_release "$T" "$T8"
    fi
    before=$(steam_hashes)
    FEED=$'y\n'
    run "$T" update
    rc_is 0
    [ "$before" = "$(steam_hashes)" ] || ERRS+=("a Steam file changed in run $run_n")
    for p in "${CHANGED[@]}"; do
      case $p in
        home/.local/share/Steam/compatibilitytools.d | home/.local/share/Steam/compatibilitytools.d/* | "$SP_REL" | "$SP_REL"/*) ;;
        home/.local/share/Steam | home/.local/share/Steam/*) ERRS+=("a path under the Steam root changed in run $run_n: $p") ;;
      esac
    done
  done
  tag_is "$T8"
}

# lib/steam_setup.sh never names a Steam config file; the grep is shown to see a planted line (it is not vacuous)
t_steam_nowrite_setup_static() {
  local pat='shortcuts\.vdf|config\.vdf|loginusers\.vdf|libraryfolders\.vdf|registry\.vdf|localconfig|userdata|steamapps' hits
  hits=$(grep -vE '^[[:space:]]*#' "$ROOT/lib/steam_setup.sh" | grep -E "$pat")
  [ -z "$hits" ] || ERRS+=("lib/steam_setup.sh names a Steam file: $hits")
  { cat "$ROOT/lib/steam_setup.sh"; printf '%s\n' "x=\$SR/config/localconfig.vdf"; } > "$T/planted.sh"
  grep -vE '^[[:space:]]*#' "$T/planted.sh" | grep -qE "$pat" || ERRS+=('the check did not report a planted line')
}

# ---------- STEAM-08: update ----------

# supd_setup V [TAG]: a complete shortcut whose launcher is V (DisplayVersion and record), latest launcher 1.6.16, the fork's latest build TAG
# (default: the installed one), msiexec upgrades the launcher. The launcher edits come before steam_tree, which copies the Faugus prefix.
supd_setup() {
  set_dispver "$T" "$1"
  rec_set "$T" "$1"
  steam_tree
  steam_on
  mk_release "$T" "${2:-$TAG}"
  proton_hook "$UPD_HOOK"
  ALLOW_EXTRA+=("$SP_REL/system.reg")
}

# warn_runner_rows N: stdout holds exactly N runner warn rows.
warn_runner_rows() {
  local n
  n=$(grep -c '^warn  runner ' <<< "$OUT")
  [ "$n" = "$1" ] || ERRS+=("runner warn rows: want $1 got $n")
}

# no_question: stderr holds no question and no wait prompt.
no_question() {
  case $ERR in *'[Y/n]'* | *'[y/N]'* | *'press Enter'*) ERRS+=("a question or wait was shown: $ERR") ;; esac
}

# the launcher on the mapped tool: one question, one proton call through the Steam executor, the record moves on
t_steam_update_launcher() {
  local msi=$T/home/.cache/w3c-linux/launcher/W3Champions_1.6.16_x64_en-US.msi
  supd_setup 1.6.15
  FEED=$'y\n'
  run "$T" update
  rc_is 0
  err_has 'Update W3Champions 1.6.15 -> 1.6.16? [Y/n]'
  proton_count 1
  case $(cat "$T/marks/proton" 2> /dev/null) in
    "$SR/compatibilitytools.d/$TAG/proton run msiexec /i $(zpath "$msi") /qn") ;;
    *) ERRS+=("proton argv: $(cat "$T/marks/proton" 2> /dev/null)") ;;
  esac
  [ "$(launcher_rec)" = 1.6.16 ] || ERRS+=("launcher record is $(launcher_rec)")
  out_line "patched Proton $TAG up to date"
  out_line 'Update finished.'
}

# D-13: the shortcut runs on another tool: one warn row, the MSI skip line, no question, no wait, no change
t_steam_update_other_tool() {
  supd_setup 1.6.15
  mk_mapping 3389133332:proton_9
  run "$T" update
  rc_is 0
  warn_runner_rows 1
  out_line "$(printf 'warn  %-16s  %s' runner "CompatToolMapping for appid 3389133332 names proton_9, not the W3C build $TAG: update changes nothing in Steam; w3c-linux.sh install walks you back to the W3C build")"
  out_line 'launcher update needs Battle.net on a W3C build: run w3c-linux.sh install'
  no_question
  proton_count 0
  changed_is
}

t_steam_update_uptodate() {
  supd_setup 1.6.16
  run "$T" update
  rc_is 0
  out_line "patched Proton $TAG up to date"
  out_line 'launcher 1.6.16 up to date'
  warn_runner_rows 0
  no_question
  proton_count 0
  changed_is
}

# D-11: the new build is downloaded and verified into its own directory, then the select step waits; quitting records nothing
t_steam_update_select_stop() {
  supd_setup 1.6.16 "$T8"
  FEED=$'y\n'
  run "$T" update
  rc_is 1
  err_has "Install $T8 (about 1.1 GB) and use it for the Steam shortcut? You select it in Steam after a restart; $TAG stays installed. [Y/n]"
  [ -f "$SR/compatibilitytools.d/$T8/proton" ] && [ -d "$SR/compatibilitytools.d/$T8/files" ] || ERRS+=("$T8 is not complete in the Steam root")
  tag_is "$TAG"
  prev_is ''
  out_line "Step 1: Select $T8 as its compatibility tool"
  out_has 'Restart Steam (Steam menu > Exit, then start Steam again)'
  out_has "Select compatibility tool > $T8"
  out_line 'Stopped; rerun w3c-linux.sh update to continue.'
}

# the user selects the build while update waits: Enter re-reads CompatToolMapping and the records move to the new build
t_steam_update_select_observed() {
  supd_setup 1.6.16 "$T8"
  ALLOW_EXTRA+=(home/.local/share/Steam/config/config.vdf)
  run_fifo "$T" update
  send $'y\n'
  wait_err 'press Enter to check again'
  mk_mapping "3389133332:$T8"
  send $'\n'
  finish
  rc_is 0
  tag_is "$T8"
  prev_is "$TAG"
  out_line "Recorded $T8; the previous W3C build $TAG stays installed (w3c-linux.sh revert switches back to it)"
  out_line 'Update finished.'
}

# the shortcut already uses the new complete build (an earlier run stopped at the wait): only the records are missing, no question, no wait
t_steam_update_mapped_new() {
  supd_setup 1.6.16 "$T8"
  fill_build "$SR/compatibilitytools.d/$T8" "$T8"
  mk_mapping "3389133332:$T8"
  run "$T" update
  rc_is 0
  no_question
  warn_runner_rows 0
  tag_is "$T8"
  prev_is "$TAG"
  out_line "Recorded $T8; the previous W3C build $TAG stays installed (w3c-linux.sh revert switches back to it)"
}

# the launcher is upgraded on the NEW build: the select step comes first, then the one proton call runs from the new build's directory
t_steam_update_msi_after_switch() {
  supd_setup 1.6.16 "$T8"
  latest_17 "$T"
  proton_hook "$UPD17_HOOK"
  ALLOW_EXTRA+=(home/.local/share/Steam/config/config.vdf)
  run_fifo "$T" update
  send $'y\ny\n'
  wait_err 'press Enter to check again'
  proton_count 0
  mk_mapping "3389133332:$T8"
  send $'\n'
  finish
  rc_is 0
  err_has 'Update W3Champions 1.6.16 -> 1.6.17? [Y/n]'
  proton_count 1
  case $(cat "$T/marks/proton" 2> /dev/null) in
    "$SR/compatibilitytools.d/$T8/proton run msiexec "*) ;;
    *) ERRS+=("proton argv: $(cat "$T/marks/proton" 2> /dev/null)") ;;
  esac
  [ "$(launcher_rec)" = 1.6.17 ] || ERRS+=("launcher record is $(launcher_rec)")
  tag_is "$T8"
  out_line 'Update finished.'
}

# D-13 with a download: the shortcut stays on proton_9 by choice, the new build is fetched and recorded, nothing waits and no Steam file changes
t_steam_update_other_tool_proton() {
  local before
  supd_setup 1.6.16 "$T8"
  mk_mapping 3389133332:proton_9
  before=$(steam_hashes)
  FEED=$'y\n'
  run "$T" update
  rc_is 0
  [ -f "$SR/compatibilitytools.d/$T8/proton" ] || ERRS+=("$T8 was not downloaded")
  tag_is "$T8"
  prev_is "$TAG"
  out_line "Recorded $T8; the shortcut runs on proton_9: w3c-linux.sh install walks you to $T8"
  warn_runner_rows 1
  case $ERR in *'press Enter'*) ERRS+=('update waited at the select step') ;; esac
  [ "$before" = "$(steam_hashes)" ] || ERRS+=('a Steam file changed')
}

# names are exact strings: a lower-case spelling of the W3C build is another tool and is reported as stored
t_steam_update_case() {
  supd_setup 1.6.15
  mk_mapping 3389133332:ge-proton11-7-w3c
  run "$T" update
  rc_is 0
  warn_runner_rows 1
  out_has "names ge-proton11-7-w3c, not the W3C build $TAG:"
  out_line 'launcher update needs Battle.net on a W3C build: run w3c-linux.sh install'
  no_question
  proton_count 0
}

# no proton-tag: the no-record line, and a shortcut on a *-W3C build is not warned about
t_steam_update_no_record() {
  supd_setup 1.6.16
  rm "$T/home/.local/state/w3c-linux/proton-tag"
  run "$T" update
  rc_is 0
  out_line 'patched Proton: no complete W3C build recorded; run w3c-linux.sh install'
  warn_runner_rows 0
  no_question
  changed_is
}

t_steam_update_twice() {
  local i
  supd_setup 1.6.16
  for i in 1 2; do
    run "$T" update
    rc_is 0
    out_line "patched Proton $TAG up to date"
    out_line 'launcher 1.6.16 up to date'
    no_question
    proton_count 0
    changed_is
  done
}

# an update stopped at the select wait changed no record; once the user has selected the build, the next update only records
t_steam_update_resume() {
  supd_setup 1.6.16 "$T8"
  FEED=$'y\n'
  run "$T" update
  rc_is 1
  tag_is "$TAG"
  prev_is ''
  [ -f "$SR/compatibilitytools.d/$T8/proton" ] || ERRS+=("$T8 was not installed")
  mk_mapping "3389133332:$T8"
  unset FEED
  run "$T" update
  rc_is 0
  case $ERR in *Install* | *Use*) ERRS+=("the rerun asked about the build: $ERR") ;; esac
  no_question
  tag_is "$T8"
  prev_is "$TAG"
  out_line "Recorded $T8; the previous W3C build $TAG stays installed (w3c-linux.sh revert switches back to it)"
}

# ---------- STEAM-08: the replaced build is offered for removal only when nothing still runs on it (D-12) ----------

# steam_prev_setup [APPID:NAME...]: the state after an update moved the shortcut from TAG to T8: both builds complete, proton-tag on T8,
# proton-tag.prev on TAG, the launcher current, and the mapping naming T8 for the shortcut plus the given entries.
steam_prev_setup() {
  supd_setup 1.6.16 "$T8"
  fill_build "$SR/compatibilitytools.d/$T8" "$T8"
  seed_tag "$T" "$T8"
  printf '%s\n' "$TAG" > "$T/home/.local/state/w3c-linux/proton-tag.prev"
  mk_mapping "3389133332:$T8" "$@"
}

# steam_prev_question: the removal question for TAG (replaced by T8), exactly.
steam_prev_question() { printf 'Remove %s (about 1.5 GB)? Only if a ladder match on %s worked. [y/N]' "$TAG" "$T8"; }

# steam_prev_kept: TAG and its record stand and nothing changed; the question was not asked.
steam_prev_kept() {
  build_ok "$SR/compatibilitytools.d/$TAG"
  prev_is "$TAG"
  changed_is
}

# steam_prev_not_offered: no removal question and nothing removed.
steam_prev_not_offered() {
  case $ERR in *'Remove '*) ERRS+=('a removal question was asked') ;; esac
  steam_prev_kept
}

# the helper lists every CompatToolMapping name, whatever the appid, and fails closed on a file it cannot read
t_steam_tools_helper() {
  local -a E=()
  local h=$ROOT/lib/w3c_helper.py f
  steam_tree
  f=$SR/config/config.vdf
  mapfile -d '' -t E < <(python3 -I -B "$h" steam-tools "$SR")
  [ "$(printf '%s|' "${E[@]}")" = "ok|proton_9|$TAG|$TAG|" ] || ERRS+=("fixture: $(printf '%s|' "${E[@]}")")
  rm "$f"
  mapfile -d '' -t E < <(python3 -I -B "$h" steam-tools "$SR")
  [ "$(printf '%s|' "${E[@]}")" = 'ok|' ] || ERRS+=("no file: $(printf '%s|' "${E[@]}")")
  printf 'not vdf {{{' > "$f"
  mapfile -d '' -t E < <(python3 -I -B "$h" steam-tools "$SR")
  [ "$(printf '%s|' "${E[@]}")" = "bad|config.vdf|$f|" ] || ERRS+=("garbage: $(printf '%s|' "${E[@]}")")
  mk_mapping $'1000000:a\001b'
  mapfile -d '' -t E < <(python3 -I -B "$h" steam-tools "$SR")
  [ "$(printf '%s|' "${E[@]}")" = 'ok|a?b|' ] || ERRS+=("control byte: $(printf '%s|' "${E[@]}")")
}

# the shortcut runs on T8 and nothing else names TAG: the offer, a yes removes exactly TAG and its record
t_steam_update_prev_offer() {
  local c=home/.local/share/Steam/compatibilitytools.d/$TAG
  steam_prev_setup
  FEED=$'y\n'
  run "$T" update
  rc_is 0
  err_has "$(steam_prev_question)"
  out_line "Removed $SR/compatibilitytools.d/$TAG."
  out_line 'Update finished.'
  [ ! -e "$SR/compatibilitytools.d/$TAG" ] || ERRS+=("$TAG still exists")
  build_ok "$SR/compatibilitytools.d/$T8"
  prev_is ''
  tag_is "$T8"
  proton_count 0
  changed_is "$c" "$c/compatibilitytool.vdf" "$c/files" "$c/files/bin" "$c/files/bin/wine" "$c/proton" "$c/version" "$c/toolmanifest.vdf" \
    home/.local/state/w3c-linux/proton-tag.prev
}

# another appid still maps TAG: no offer, TAG stays
t_steam_update_prev_other_appid() {
  steam_prev_setup "1000000:$TAG"
  FEED=$'y\n'
  run "$T" update
  rc_is 0
  steam_prev_not_offered
}

# a Faugus entry still runs on TAG: no offer, TAG stays
t_steam_update_prev_faugus() {
  steam_prev_setup
  bn_set4 "$T" runner "$TAG"
  FEED=$'y\n'
  run "$T" update
  rc_is 0
  steam_prev_not_offered
}

# an unreadable games.json counts as used
t_steam_update_prev_faugus_bad() {
  steam_prev_setup
  printf 'not json' > "$T/home/.local/share/faugus-launcher/games.json"
  FEED=$'y\n'
  run "$T" update
  rc_is 0
  steam_prev_not_offered
}

# ---------- D-21: the Faugus side asks the same rule ----------

# steam_min APPID:NAME...: a native Steam root with only steamapps and the CompatToolMapping entries given (what steam_root needs and nothing
# else), beside a Faugus tree. Sets SR.
steam_min() {
  local r=$T/home/.local/share/Steam
  mkdir -p "$r/steamapps" "$r/config"
  SR=$(realpath "$r")
  mk_mapping "$@"
}

# Faugus backend, the replaced build TAG is mapped by a Steam shortcut: update asks no removal question and TAG stays
t_faugus_prev_steam_mapped() {
  prev_setup
  steam_min "3389133332:$TAG"
  FEED=$'y\n'
  run "$T" update
  rc_is 0
  no_remove_q
  prev_kept
}

# the Steam mapping names another build: the offer is made as before and a yes removes TAG
t_faugus_prev_steam_other() {
  prev_setup
  steam_min "3389133332:$T8"
  FEED=$'y\n'
  run "$T" update
  rc_is 0
  err_has "$(prev_question)"
  out_has "Removed $T/$COMPAT_REL/$TAG."
  prev_removed
}

# an unreadable config.vdf counts as used
t_faugus_prev_steam_bad() {
  prev_setup
  steam_min "3389133332:$TAG"
  printf 'not vdf {{{' > "$SR/config/config.vdf"
  FEED=$'y\n'
  run "$T" update
  rc_is 0
  no_remove_q
  prev_kept
}

# revert switches the Faugus runner back and does not offer a build a Steam shortcut still runs on
t_faugus_revert_steam_mapped() {
  local c=$T/home/.local/share/Steam/compatibilitytools.d
  w3c_on
  steam_min "3389133332:$TAG"
  FEED=$'y\n'
  run "$T" revert
  rc_is 0
  runner_is 'Proton-GE Latest'
  case $ERR in *"Remove $TAG from"*) ERRS+=('the removal offer was shown while a Steam mapping names the build') ;; esac
  build_ok "$c/$TAG"
  tag_is "$TAG"
}

# ---------- STEAM-08: revert ----------

# srev_clean: nothing in the text offers removing the shortcut from the library.
srev_clean() {
  case $OUT$ERR in *'Remove non-Steam'* | *'Remove from library'*) ERRS+=('revert text offers removing the shortcut') ;; esac
}

# srev_full [TOOL]: the shortcut runs on TAG, no earlier W3C build is recorded, it targets W3Champions.exe, and TOOL (when given) is the tool
# Steam had for it before w3c-linux. Only TAG maps the shortcut's appid, and nothing else maps TAG.
srev_full() {
  supd_setup 1.6.16
  mk_mapping "3389133332:$TAG"
  sc_edit "$SR/userdata/12345678/config/shortcuts.vdf" set 3389133332 Exe '"/x/W3Champions.exe"'
  [ -z "${1-}" ] || printf '%s\n' "$1" > "$T/home/.local/state/w3c-linux/steam-prev-tool"
  ALLOW_EXTRA+=(home/.local/share/Steam/config/config.vdf)
}

# D-08, D-10: with a complete previous W3C build recorded, revert prints the select step for it, waits for the mapping to move, records it, and
# only then offers the build it left (default No)
t_steam_revert_step_back() {
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
  out_line "Step 1: Select $TAG as its compatibility tool"
  out_has 'Restart Steam (Steam menu > Exit, then start Steam again)'
  out_has "Select compatibility tool > $TAG"
  lacks_text 'Step 2:'
  tag_is "$TAG"
  prev_is ''
  out_line "The shortcut runs on $TAG again; $T8 stays installed."
  err_has "Remove $T8 from $SR/compatibilitytools.d (about 1.5 GB)? w3c-linux.sh update downloads it again. [y/N]"
  out_has "Kept $T8"
  build_ok "$SR/compatibilitytools.d/$T8"
  build_ok "$SR/compatibilitytools.d/$TAG"
  srev_clean
}

# D-09: without a previous W3C build, the click path goes back to the tool saved before install and retargets to Battle.net.exe; the removal
# offer for the build left comes after, and a yes removes the build and its record
t_steam_revert_full_saved() {
  local pfx opts='WINE_SIMULATE_WRITECOPY=1 PROTON_ENABLE_WAYLAND=0 %command%'
  srev_full proton_experimental
  pfx=$SR/steamapps/compatdata/3389133332/pfx
  run_fifo "$T" revert
  wait_err 'press Enter to check again'
  mk_mapping 3389133332:proton_experimental
  send $'\n'
  wait_err '[y/N]'
  send $'y\n'
  finish
  rc_is 0
  out_line 'Step 1: Select proton_experimental as its compatibility tool'
  out_line 'Step 2: Point the shortcut back at Battle.net.exe'
  ck_retarget "$pfx/drive_c/Program Files (x86)/Battle.net" Battle.net.exe "$opts"
  [ ! -e "$T/home/.local/state/w3c-linux/steam-prev-tool" ] || ERRS+=('steam-prev-tool was not removed')
  out_line 'The shortcut now runs on proton_experimental.'
  err_has "Remove $TAG from $SR/compatibilitytools.d (about 1.5 GB)? w3c-linux.sh install downloads it again. [y/N]"
  out_line "Removed $SR/compatibilitytools.d/$TAG and the recorded build."
  [ ! -e "$SR/compatibilitytools.d/$TAG" ] || ERRS+=("$TAG still exists")
  [ ! -e "$T/home/.local/state/w3c-linux/proton-tag" ] || ERRS+=('proton-tag still exists')
  srev_clean
}

# the shortcut is deleted while revert waits: that is a stop, not "the mapping moved"; the saved tool and the build stay
t_steam_revert_gone_in_wait() {
  srev_full proton_experimental
  run_fifo "$T" revert
  wait_err 'press Enter to check again'
  rm "$SR/userdata/12345678/config/shortcuts.vdf"
  ALLOW_EXTRA+=(home/.local/share/Steam/userdata/12345678/config/shortcuts.vdf)   # the test itself deletes it
  send $'\n'
  finish
  rc_is 1
  out_line 'revert: the Battle.net shortcut is gone from Steam; stopping'
  [ "$(cat "$T/home/.local/state/w3c-linux/steam-prev-tool" 2> /dev/null)" = proton_experimental ] || ERRS+=('steam-prev-tool was lost')
  case $ERR in *'Remove '*) ERRS+=('a removal question was asked') ;; esac
  tag_is "$TAG"
  build_ok "$SR/compatibilitytools.d/$TAG"
}

# the shortcut moves to another W3C build instead of the saved tool: the saved tool is kept for the next revert
t_steam_revert_full_other_w3c() {
  srev_full proton_experimental
  run_fifo "$T" revert
  wait_err 'press Enter to check again'
  mk_mapping 3389133332:Other-W3C
  send $'\n'
  wait_err '[y/N]'
  send $'\n'
  finish
  rc_is 0
  [ "$(cat "$T/home/.local/state/w3c-linux/steam-prev-tool" 2> /dev/null)" = proton_experimental ] || ERRS+=('steam-prev-tool was lost')
}

# nothing saved: the select step names a Proton of the user's choice; EOF at the wait stops with nothing changed
t_steam_revert_full_free() {
  srev_full
  run "$T" revert
  rc_is 1
  out_line 'Step 1: Select a Proton of your choice, e.g. Proton Experimental as its compatibility tool'
  out_line 'Stopped; rerun w3c-linux.sh revert to continue.'
  tag_is "$TAG"
  prev_is ''
  build_ok "$SR/compatibilitytools.d/$TAG"
  changed_is
  srev_clean
}

# D-18: the shortcut already runs on a tool the user chose: one line says so, the retarget to Battle.net.exe is still shown (the shortcut targets
# W3Champions.exe), nothing waits, and the recorded build is offered for removal as it is unused
t_steam_revert_already_off() {
  local pfx opts='WINE_SIMULATE_WRITECOPY=1 PROTON_ENABLE_WAYLAND=0 %command%'
  srev_full
  mk_mapping 3389133332:proton_9
  pfx=$SR/steamapps/compatdata/3389133332/pfx
  FEED=$'\n'
  run "$T" revert
  rc_is 0
  out_line 'revert: the shortcut already runs on proton_9, not a W3C build'
  out_line 'Point the shortcut back at Battle.net.exe (W3Champions.exe fails on a stock Proton):'
  ck_retarget "$pfx/drive_c/Program Files (x86)/Battle.net" Battle.net.exe "$opts"
  err_has "Remove $TAG from $SR/compatibilitytools.d (about 1.5 GB)? w3c-linux.sh install downloads it again. [y/N]"
  out_has "Kept $TAG"
  case $ERR in *'press Enter'*) ERRS+=('revert waited') ;; esac
  build_ok "$SR/compatibilitytools.d/$TAG"
  tag_is "$TAG"
  changed_is
  srev_clean
}

# another appid still maps the recorded build: it is never offered for removal
t_steam_revert_other_appid_keeps() {
  srev_full
  mk_mapping 3389133332:proton_9 "3737374814:$TAG"
  FEED=$'y\n'
  run "$T" revert
  rc_is 0
  out_line 'revert: the shortcut already runs on proton_9, not a W3C build'
  case $ERR in *'Remove '*) ERRS+=('a removal question was asked') ;; esac
  build_ok "$SR/compatibilitytools.d/$TAG"
  tag_is "$TAG"
  changed_is
}

# q at revert's wait leaves every record and build as it was
t_steam_revert_quit() {
  steam_prev_setup
  FEED=$'q\n'
  run "$T" revert
  rc_is 1
  out_line 'Stopped; rerun w3c-linux.sh revert to continue.'
  tag_is "$T8"
  prev_is "$TAG"
  build_ok "$SR/compatibilitytools.d/$TAG"
  build_ok "$SR/compatibilitytools.d/$T8"
  changed_is
  srev_clean
}

t_steam_revert_no_shortcut() {
  steam_prev_setup
  rm "$SR/userdata/12345678/config/shortcuts.vdf"
  run "$T" revert
  rc_is 1
  out_line 'revert: no Battle.net shortcut in Steam; nothing to revert'
  case $ERR in *'press Enter'*) ERRS+=('revert waited') ;; esac
  tag_is "$T8"
  prev_is "$TAG"
  changed_is
}

# a completed full revert, then a second revert: the already-off path, no wait, nothing recorded
t_steam_revert_twice() {
  srev_full proton_experimental
  run_fifo "$T" revert
  wait_err 'press Enter to check again'
  mk_mapping 3389133332:proton_experimental
  send $'\n'
  wait_err '[y/N]'
  send $'\n'
  finish
  rc_is 0
  out_has "Kept $TAG"
  [ ! -e "$T/home/.local/state/w3c-linux/steam-prev-tool" ] || ERRS+=('steam-prev-tool exists after the first revert')
  FEED=$'\n'
  run "$T" revert
  rc_is 0
  out_line 'revert: the shortcut already runs on proton_experimental, not a W3C build'
  case $ERR in *'press Enter'*) ERRS+=('the second revert waited') ;; esac
  [ ! -e "$T/home/.local/state/w3c-linux/steam-prev-tool" ] || ERRS+=('steam-prev-tool exists after the second revert')
  tag_is "$TAG"
  prev_is ''
  changed_is
}

# T-19-21: the saved name is printed as stored, spaces kept, control bytes as ?; it is never used as a path
t_steam_revert_name_text() {
  srev_full 'Proton-GE Latest'
  run "$T" revert
  rc_is 1
  out_line 'Step 1: Select Proton-GE Latest as its compatibility tool'
  out_has 'Select compatibility tool > Proton-GE Latest'
  printf 'bad\033name\n' > "$T/home/.local/state/w3c-linux/steam-prev-tool"
  run "$T" revert
  rc_is 1
  out_line 'Step 1: Select bad?name as its compatibility tool'
  case $OUT$ERR in *$'\033'*) ERRS+=('an ESC byte reached the terminal') ;; esac
}

# the way back to W3C goes through install: steps 1, 3, 4 and 5 read done, only the select step is printed, and the prior tool is saved again
t_steam_revert_then_install() {
  sprep
  mk_mapping 3389133332:proton_experimental
  sc_edit "$SR/userdata/12345678/config/shortcuts.vdf" set 3389133332 Exe '"/x/Battle.net.exe"'
  run "$T" install
  rc_is 1
  ck_marks 'x xxx '
  out_line "Step 2: ${LBL[2]}"
  out_has 'Restart Steam (Steam menu > Exit, then start Steam again)'
  case $ERR in *'[Y/n]'* | *'[y/N]'*) ERRS+=('a question was asked') ;; esac
  [ "$(cat "$T/home/.local/state/w3c-linux/steam-prev-tool" 2> /dev/null)" = proton_experimental ] || ERRS+=('steam-prev-tool is not proton_experimental')
}

# revert never writes Steam's files: an already-off run and a quit run leave the four hash the same and change nothing under the Steam root
# but the build directories
t_steam_nowrite_revert() {
  local before p run_n
  steam_prev_setup
  for run_n in 1 2; do
    if [ "$run_n" = 1 ]; then
      mk_mapping 3389133332:proton_9
      FEED=$'\n'
    else
      mk_mapping "3389133332:$T8"
      FEED=$'q\n'
    fi
    before=$(steam_hashes)
    run "$T" revert
    [ "$before" = "$(steam_hashes)" ] || ERRS+=("a Steam file changed in run $run_n")
    for p in "${CHANGED[@]}"; do
      case $p in
        home/.local/share/Steam/compatibilitytools.d | home/.local/share/Steam/compatibilitytools.d/*) ;;
        home/.local/share/Steam | home/.local/share/Steam/*) ERRS+=("a path under the Steam root changed in run $run_n: $p") ;;
      esac
    done
  done
  rc_is 1
}

# ---------- main ----------

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
