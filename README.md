# w3c-arch-linux

[![Ko-fi](https://img.shields.io/badge/Ko--fi-Support%20this%20project-FF5E5B?logo=ko-fi&logoColor=white)](https://ko-fi.com/mykytabombela)

`w3c-linux` installs, launches and updates the [W3Champions](https://w3champions.com) launcher on Arch Linux, inside the Battle.net
prefix that [Faugus Launcher](https://github.com/Faugus/faugus-launcher) already manages. There is no second prefix and no second
Battle.net install. The launcher runs in the same Proton build, wineserver and container as Battle.net and Warcraft III, so it can
see the game and submit ladder results.

W3Champions ships no Linux launcher. The current one is a closed-source Windows app (Tauri 2 + WebView2), so the script runs the
stock Windows launcher under Proton. Every step it cannot do for you (the root NAT rule, Blizzard sign-ins, the first Warcraft III
run) is a prompt that shows the exact command or action.

It is a bash script, `w3c-linux.sh`, plus the `lib/` files it loads, with no build step and no daemon. An Arch package installs it as the
`w3c-linux` command, or you run it from a clone as `bash w3c-linux.sh`. Everything it changes is listed under [Files it touches](#files-it-touches).

Below, examples say `w3c-linux`. From a clone, write `bash w3c-linux.sh` instead.

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Commands](#commands)
- [Doctor](#doctor)
- [Known issues](#known-issues)
- [Files it touches](#files-it-touches)
- [Layout](#layout)
- [Tests](#tests)
- [License](#license)

## Requirements

| What | Why |
|---|---|
| Arch Linux (or close), x86_64, a graphical session (X11 or Wayland) | Battle.net and the launcher are GUI apps |
| [Faugus Launcher](https://github.com/Faugus/faugus-launcher), **native package, not Flatpak** | the script reads Faugus's `games.json` and reuses its `umu-run`; it cannot re-enter a Flatpak sandbox |
| A Battle.net entry in Faugus (*Add game → Battle.net*), installed and started at least once | creates the prefix, `umu-run` and the container the launcher joins |
| Warcraft III installed from Battle.net and **started once** | only the game creates `Documents/Warcraft III`, and the launcher refuses to start without it |
| `curl python3 sha256sum tar md5sum pgrep` | required; `doctor` fails without them |
| `setsid flock tail` (util-linux, coreutils) | needed by `launch` and the match monitor |
| `nft` or `iptables`, plus `sudo` | optional; needed for the LAN-test NAT rule (one root command, applied only if you answer y) |
| `zenity`, `notify-send` | optional on a terminal; needed to start `launch` from the app menu (every question is a dialog, errors and status are notifications), and for the lost-result notification |
| `icoextract` and ImageMagick (`magick` or `convert`) | optional; the menu icon is taken from `W3Champions.exe` when both exist, else the shipped icon is used |
| `desktop-file-utils` | optional; `update-desktop-database` refreshes the menu cache after `install` writes the entry |
| `kernel.yama.ptrace_scope` 0 or 1 | 2 or 3 breaks the launcher's game attach (`sudo sysctl kernel.yama.ptrace_scope=1`) |
| About 3 GB free under `~/.local/share/Steam/compatibilitytools.d` | the patched Proton build |

The package declares everything here except Faugus Launcher, which comes from the AUR (see [Installation](#installation)). It lists the optional
tools as optional dependencies.

On Arch: `sudo pacman -S --needed curl python coreutils tar procps-ng util-linux nftables zenity libnotify`

The script installs the patched Proton build [`GE-Proton11-7-W3C`](https://github.com/davex32/proton-ge-w3c) itself. Stock Wine,
GE-Proton and Valve Proton all fail the launcher's kill-on-close job check (`VerifyJob`), so Battle.net has to run on this build.

## Installation

### Package (recommended)

Install Faugus Launcher from the AUR first (the native package, not Flatpak). `makepkg` cannot fetch AUR dependencies, so use your
AUR helper, for example `yay -S faugus-launcher`. Then:

```bash
git clone https://github.com/Nikita-Bombela/w3c-arch-linux
cd w3c-arch-linux/packaging
makepkg -si                  # builds the tagged release the PKGBUILD names (v<pkgver>) and installs it
w3c-linux doctor             # read-only: every row should be pass or warn, no fail
w3c-linux install            # guided setup; ends with "Launch now?"
w3c-linux launch             # every later session
```

Run it from a terminal in your desktop session. Close Battle.net before `install`: the script waits until the prefix is idle before
it changes anything. Running `w3c-linux` with no argument prints the usage, it does not install.

**Updating:** when a new release is tagged, `git pull` and run `makepkg -si` again (or `yay -S w3c-linux` once it is on the AUR, which
it is not yet).

**Removing:** `sudo pacman -R w3c-linux` removes the package files. `~/.local/state/w3c-linux`, `~/.cache/w3c-linux` and a per-user
menu icon stay. Run `w3c-linux revert` first if Faugus's runner should go back.

### From a clone

```bash
git clone https://github.com/Nikita-Bombela/w3c-arch-linux && cd w3c-arch-linux
bash w3c-linux.sh doctor     # read-only: every row should be pass or warn, no fail
bash w3c-linux.sh install    # guided setup; ends with "Launch now?"
bash w3c-linux.sh launch     # every later session
```

To run it from anywhere, symlink `w3c-linux.sh` into your `PATH`; it follows the symlink to find `lib/`, so keep the two together.

### Building an untagged checkout

Before a release is tagged, or to try your own changes, build from a git archive of the checkout. Run this from the repo root; it
writes the tarball the PKGBUILD's `source` expects into `packaging/`:

```bash
v=$(sed -n 's/^pkgver=//p' packaging/PKGBUILD)
git archive --format=tar.gz --prefix=w3c-arch-linux-$v/ -o packaging/w3c-arch-linux-$v.tar.gz HEAD
cd packaging && makepkg -si --skipinteg
```

`--skipinteg` is needed because a local archive does not hash like GitHub's. Uncommitted edits are not in `HEAD`, so commit first.

## Commands

Running it with no argument prints the usage. Everything below is `w3c-linux <command>`.

| Command | What it does |
|---|---|
| [`install`](#install) | Guided setup from a working Faugus Battle.net to a playable W3Champions. Asks every question first, then works unattended. Rerun after a failure: finished steps are skipped. |
| [`launch`](#launch) | Starts W3Champions inside Battle.net's running container (starts Battle.net first if needed) and runs the match monitor. Use it every session. |
| `update` | Checks for a newer launcher (`latest.json`) and a newer patched Proton release, and asks before installing either. The previous Proton build stays installed until you remove it. Prints read-only notes on whether an upstream Wine or GE fix has landed; never switches the runner back by itself. |
| `doctor` | Read-only report ([below](#doctor)). Reads files and makes one GET of `latest.json`; never writes, starts Wine or runs sudo. Exit 0 when no row fails. |
| `revert` | Switches Faugus's Battle.net runner back: to the previous W3C build after an `update`, or to the runner you had before `install`. Backs up `games.json` first. |
| `monitor` | The match monitor on its own (`launch` already starts it). Prints `monitor: already running` and exits 0 if one is running. |
| `version` | Prints `w3c-linux 0.1.0`. `w3c-linux --version` and `-V` do the same. |
| `report` | Read-only and offline: prints a Markdown bug report for the maintainer (distro, kernel, GPU, Vulkan ICDs for x86_64 and i686, w3c-linux, Faugus, umu, Proton, launcher and WebView2 versions, last 40 lines of `wine.log` and of the launcher log). Paths under your home show as `~`; review it before pasting, the launcher log can contain your BattleTag. `W3C_REPORT_LINES=N` changes the line count. |

### `install`

Takes a working Faugus Battle.net to a playable W3Champions setup. It asks every question first, then works unattended:

1. Runs the doctor checks quietly and stops on any `fail`.
2. Shows the detected prefix, runner and Warcraft III build, then asks to continue.
3. Downloads `GE-Proton11-7-W3C` (checksum-verified) into `compatibilitytools.d`.
4. Asks whether to switch Faugus's Battle.net runner to that build. It backs up `games.json` first and writes it atomically.
5. Asks whether to install the WebView2 runtime into the prefix.
6. Asks whether to apply the registry tweaks: WebView2 app version `win7`, prefix set to Windows 10, *Allow Local Files*.
7. Asks whether to install the latest W3Champions launcher (MSI, inside the prefix, through Faugus's `umu-run`).
8. Prints the **LAN-test NAT rule** with its removal lines and asks `Apply ... now with sudo? [y/N]`. If you answer y, sudo shows
   its own password prompt in your terminal and runs exactly the printed command. The rule lasts until reboot. A marker file stops
   the script from asking again during the same boot.
9. Prints firewall and NTP hints, but only when a firewall is active or NTP is off.
10. Sets up the app-menu entry and icon without asking, and only for a complete install. With the package, the entry is the system
    one (`/usr/share/applications/w3c-linux.desktop`): `install` writes no per-user entry, prints `Desktop entry: the system entry
    is used (...)`, and removes a per-user entry that an earlier clone install wrote. It still places the launcher's own icon under
    `~/.local/share/icons` when `icoextract` and ImageMagick exist. From a clone without the package it writes
    `~/.local/share/applications/w3c-linux.desktop` and `~/.local/share/icons/hicolor/256x256/apps/w3c-linux.png`. It prints one
    line and says "already installed" when nothing changed.
11. Asks `Launch now?`.

A failed step stops `install`. Rerun it: finished steps are skipped. `W3C_WEBVIEW_WINVER=win8 w3c-linux install` switches the
WebView2 app version if the launcher window is white or black, or crashes in `ole32`.

### `launch`

Starts W3Champions inside Battle.net's running container.

- If Battle.net is not running, it starts it through Faugus and waits up to 120 s for its container.
- It waits for you to sign in to Battle.net, then starts the launcher with the right environment (`--no-sandbox` WebView2 flag,
  `W3C_SHARED_QUERY=1`).
- It starts the **match monitor** in the background, then waits in the terminal until the launcher exits.
- If the launcher's LAN test fails during the session, it offers the NAT rule once.
- If the launcher restarts itself (for example after the first Bonjour install), it is started again in the same container.

The monitor follows the launcher's daily log and appends one line per event to `~/.local/state/w3c-linux/matches.log`:

```
2026-10-09T23:10:02+03:00 joined target=exe mode=nsenter wv2flags=--no-sandbox
2026-10-09T23:31:47+03:00 game-end target=exe mode=nsenter wv2flags=--no-sandbox
```

A `RESULT-LOST` line means the launcher's frontend crashed at game end and the result was not submitted. You also get a critical
desktop notification naming the newest replay to send to W3Champions support. `JOIN-BUG` counts the "Causing join bug" /
"Left during game creation" cases. Only one monitor runs at a time; `w3c-linux monitor` runs it on its own.

#### From the app menu

The package ships a W3Champions menu entry (`/usr/share/applications/w3c-linux.desktop`); from a clone, `install` writes one per user
instead. Starting it there (or running `w3c-linux launch < /dev/null` from anywhere, which is the same thing) needs no terminal:

- Every question is a `zenity` dialog: the Battle.net sign-in (asked on every start), the separate-container fallback (No is the
  default) and the Warcraft III folder check.
- A stop before the launcher starts is an error dialog that names the log.
- A newer launcher, the first run, a non-zero exit and a launcher that closes right after it starts are desktop notifications.
- Every line the script prints goes to `~/.cache/w3c-linux/launch.log`; the previous start is kept as `launch.log.1`.
- There is no Enter restart. If the launcher closes right away, start Warcraft III once from Battle.net, close it, then start
  W3Champions again from the menu.
- The NAT offer asks in a dialog and then shows a password dialog that names the exact root command it runs (`sudo -A`, through
  `lib/w3c-askpass.sh`). Nothing else runs as root.
- Without `zenity`, or without a graphical session, a critical notification says to install `zenity` or run `launch` from a terminal.

Knobs for one run: `W3C_LAUNCH_BAT=1` starts through `W3Champions.bat`, which restarts Bonjour (helps a LAN test that fails on a
second start). `W3C_WRAPPER_WEBVIEW_FLAGS=0` drops `--no-sandbox`, and `W3C_BUS_WAIT_SECS=N` changes the Battle.net wait.

## Doctor

Sample output on a working setup (paths shortened to `/home/you`):

```
$ w3c-linux doctor
pass  version           w3c-linux 0.1.0
pass  faugus version    2.4.2
pass  games.json        /home/you/.local/share/faugus-launcher/games.json
pass  battlenet         found
pass  prefix            /home/you/Faugus/battlenet
pass  runner            GE-Proton11-7-W3C
pass  launch_arguments  WINE_SIMULATE_WRITECOPY=1 PROTON_ENABLE_WAYLAND=0
pass  path              /home/you/Faugus/battlenet/drive_c/Program Files (x86)/Battle.net/Battle.net.exe
pass  PREFIX            /home/you/Faugus/battlenet
pass  APPID             6e48d1d0c0af33aac57ad5b171999cdb
pass  W3C_EXE           /home/you/Faugus/battlenet/drive_c/Program Files/W3Champions/W3Champions.exe
pass  launch-client     present: /home/you/.local/share/umu/steamrt4/pressure-vessel/bin/steam-runtime-launch-client
pass  umu-run           /home/you/.local/share/faugus-launcher/umu-run
pass  umu version       1.4.4-patch
pass  system.reg        /home/you/Faugus/battlenet/system.reg
pass  Battle.net.exe    /home/you/Faugus/battlenet/drive_c/Program Files (x86)/Battle.net/Battle.net.exe
pass  wc3 dir           /home/you/Faugus/battlenet/drive_c/Program Files (x86)/Warcraft III
pass  wc3 exe           /home/you/Faugus/battlenet/drive_c/Program Files (x86)/Warcraft III/_retail_/x86_64/Warcraft III.exe
pass  wc3 build         3.0.0.24268
pass  wc3 user data     /home/you/Faugus/battlenet/drive_c/users/steamuser/Documents/Warcraft III
pass  required tools    curl python3 sha256sum tar md5sum pgrep
pass  optional tool     zenity present
pass  optional tool     nft present
pass  optional tool     iptables present
pass  optional tool     sudo present
pass  optional tool     notify-send present
pass  ptrace_scope      1
pass  compat tools      present: /home/you/.local/share/Steam/compatibilitytools.d
pass  config.json       /home/you/.config/faugus-launcher/config.json
pass  envar.json        /home/you/.config/faugus-launcher/envar.json
pass  faugus env        (none)
pass  launch env        WINE_SIMULATE_WRITECOPY=1
pass  launch env        PROTON_ENABLE_WAYLAND=0
pass  w3c build         GE-Proton11-7-W3C (recorded)
pass  runner build      GE-Proton11-7-W3C
pass  runner dir        /home/you/.local/share/Steam/compatibilitytools.d/GE-Proton11-7-W3C
pass  prefix version    GE-Proton11-7 (Proton prefix format, same for stock and W3C builds)
pass  prefix runner     GE-Proton11-7-W3C (config_info line 3)
pass  webview2          154.0.4258.62 (/home/you/Faugus/battlenet/drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application/154.0.4258.62/msedgewebview2.exe)
pass  webview2 winver   win7 (white or black launcher window or ole32 crash: W3C_WEBVIEW_WINVER=win8 w3c-linux install)
pass  local files       Allow Local Files dword:00000001
pass  windows version   Windows 10 (build 19045)
pass  launcher          /home/you/Faugus/battlenet/drive_c/Program Files/W3Champions/W3Champions.exe
pass  launcher version  1.6.18 (installed 1.6.18, recorded 1.6.18, latest 1.6.18)
pass  desktop entry     /usr/share/applications/w3c-linux.desktop (system)
```

Before `install`, the rows from `w3c build` down are mostly `warn ... run w3c-linux install`. That is expected.

**Statuses:**
- `pass`: fine.
- `warn`: works, but something is missing or outdated. The row says what to run.
- `fail`: `install`, `update` and `launch` refuse to run until it is fixed.
- `skip`: not checked, because an earlier row failed (`needs: <what>`).

### What each row means

**Faugus and the Battle.net entry**

| Row | Meaning | If not pass |
|---|---|---|
| `version` | this tool's own version, the same string as `w3c-linux --version` (always the first row) | |
| `faugus version` | Faugus's own version, read from the installed package (pacman as fallback); 2.x is the tested format | warn `untested Faugus major N` (`games.json` or `envar.json` may differ) or `unknown`; it never blocks `install`, `launch` or `update`. |
| `games.json` | Faugus's game list | Install Faugus and add Battle.net. A Flatpak Faugus is reported and unsupported. |
| `battlenet` | exactly one entry with `gameid` battlenet | Add Battle.net in Faugus, or remove the duplicate. |
| `prefix` `runner` `launch_arguments` `path` | that entry's fields, as stored | `prefix` must be set; the others are shown for reference. |
| `PREFIX` | the prefix path resolved the way Faugus does (`~`, `$VAR`, symlinks) | |
| `APPID` | md5 of `PREFIX`; umu names Battle.net's container `com.steampowered.App<APPID>` | |
| `W3C_EXE` | where the launcher is (or will be) installed | |
| `launch-client` | umu's tool for entering a running container | warn: launch Battle.net once in Faugus so umu downloads it. |
| `umu-run`, `umu version` | Faugus's bundled umu | Launch any game once in Faugus. |

**Prefix and game**

| Row | Meaning | If not pass |
|---|---|---|
| `system.reg`, `Battle.net.exe` | the prefix really holds Battle.net | Install Battle.net in that prefix through Faugus. |
| `wc3 dir`, `wc3 exe`, `wc3 build` | Warcraft III's install and build (from the registry and `.build.info`) | Install Warcraft III from Battle.net and start it once. |
| `wc3 user data` | `Documents/Warcraft III` exists | warn: start Warcraft III once from Battle.net, then close it. The launcher refuses to start without it. |

**Host**

| Row | Meaning | If not pass |
|---|---|---|
| `required tools` | `curl python3 sha256sum tar md5sum pgrep` | Install the missing ones. |
| `optional tool` | `zenity nft iptables sudo notify-send`, present or absent (always pass) | Install `nft` or `iptables` + `sudo` for the NAT step. |
| `ptrace_scope` | Yama ptrace level | fail on 2 or 3: `sudo sysctl kernel.yama.ptrace_scope=1`. |
| `compat tools` | `~/.local/share/Steam/compatibilitytools.d`, where Proton builds go | Created by `install` if absent. |

**Environment**

| Row | Meaning | If not pass |
|---|---|---|
| `config.json`, `envar.json` | Faugus's global toggles and extra env vars, read the way Faugus reads them | warn: the file is unreadable, so it is ignored. |
| `faugus env` | the global env Faugus would add | |
| `launch env` | `VAR=value` pairs from the Battle.net entry's launch arguments; the launcher gets the same | warn: an unbalanced quote, so none are used. |

**Patched Proton**

| Row | Meaning | If not pass |
|---|---|---|
| `w3c build` | the W3C build `install` recorded | warn: run `install`. |
| `runner build` | Battle.net's runner equals that build | warn: run `install` to switch back (for example after you changed it in Faugus). |
| `runner dir` | the runner's directory is complete | warn: rerun `install`. Otherwise Faugus shows "was not found". |
| `prefix version` | Proton's prefix format (information only) | warn: start Battle.net once via Faugus. |
| `prefix runner` | the build that last touched the prefix (`config_info`) | warn: start Battle.net once via Faugus after switching. |

**W3Champions setup**

| Row | Meaning | If not pass |
|---|---|---|
| `webview2` | WebView2 runtime version in the prefix | warn: run `install`. |
| `webview2 winver` | Windows version Wine reports to `msedgewebview2.exe` (`win7` default, `win8` alternative) | White/black window or `ole32` crash: `W3C_WEBVIEW_WINVER=win8 w3c-linux install`. |
| `local files` | Warcraft III *Allow Local Files* = 1 | warn: run `install`. |
| `windows version` | the prefix reports Windows 10 | warn on Windows 11 or unknown: run `install`. |
| `launcher` | `W3Champions.exe` is installed | warn: run `install`. |
| `launcher version` | installed vs recorded vs latest version | warn: run `update` when a newer one exists; `unknown: offline` when GitHub was unreachable. |
| `desktop entry` | the app-menu entry exists. Three shapes: the packaged system entry (`/usr/share/applications/w3c-linux.desktop (system)`, pass); a per-user file that hides the system entry; or, from a clone, the per-user entry whose `Exec` names a script that exists | warn `<user file> hides the system entry`: run `w3c-linux install`, or delete it. Clone: warn `absent` or `points at a missing script` (the clone moved): run `install`. |

## Known issues

| Symptom | Cause | What to do |
|---|---|---|
| Launcher says `VerifyJob` / "kill-on-close game job required" | Battle.net is not running on the W3C build | `doctor`; `runner build` must pass. Close everything and start Battle.net again through Faugus. |
| "WC3 NOT READY", `searchLanGame timed out` | The LAN test's UDP 16000 broadcast is not looped back | Apply the NAT rule (`install` or `launch` offers it). On a second start, try `W3C_LAUNCH_BAT=1 w3c-linux launch`. |
| Launcher window white or black, or `ole32` crash at sign-in | WebView2 / Windows-version mismatch | `W3C_WEBVIEW_WINVER=win8 w3c-linux install`, or back to `win7`. |
| "cannot find the Warcraft III user data folder" | Warcraft III never started in this prefix | Start it once from Battle.net and close it. `launch` waits for this. |
| Match played, no result on the site; `RESULT-LOST` in `matches.log` | The launcher's WebView2 frontend crashes at game end before it submits ([w3champions-issues #52](https://github.com/w3champions/w3champions-issues/issues)); launcher-side, no local fix | Send the replay the notification names to W3Champions support. The tally shows how often it happens. |
| "Causing join bug, restart launcher" / "Left during game creation" | Unknown; reported on Wine and on macOS | Rerun `launch` (Battle.net stays up). `JOIN-BUG` lines count it. |
| Cursor disappears after a game | Wine/WebView2 cursor bug | Alt+R or switch workspace. |
| 1 s stutter about every 10 s | Launcher memory scans going through wineserver | `launch` already sets `W3C_SHARED_QUERY=1` on the W3C build. Report it if it persists. |
| Warcraft III crashes at start in `RtlLeaveCriticalSection` | [GE issue #824](https://github.com/GloriousEggroll/proton-ge-custom/issues/824) on GE-Proton11-7 | No fix yet; report with logs. |
| `GE-Proton11-7-W3C` lags newer GE releases | A community fork, rebased by hand | `update` prints the options: stay, wait for a rebase, or rebuild from the fork. |
| Real LAN games with other machines are not announced | Side effect of the NAT rule (inferred) | Remove it with the printed lines (`sudo nft delete table ip w3c`, then `rm -f` the marker) or reboot. |
| Warcraft III opens as a half-width tile on niri (and other tiling compositors) | umu gives every window the app-id `steam_app_default`, so the game is tiled like any other window | Add a title-matched rule to `~/.config/niri/config.kdl`: `window-rule { match app-id="^steam_app_default$" title="^Warcraft III$"; open-fullscreen true }`. Other compositors: match the title the same way. |
| Microphone indicator flicks on and off at launcher start, game start and after a game | Wine's PulseAudio driver opens a short `format test stream` on the default source every time a Windows process first touches audio; the suspended USB mic wakes and sleeps again. Nothing records | Harmless. If it bothers you, a WirePlumber rule routing streams named `format test stream` to a null source stops the wake-ups. |
| NAT rule gone after reboot | It is not persisted on purpose | `install` prints optional persistence steps. Warning: Arch's stock `nftables.conf` is default-drop. |

Logs: Wine output goes to `~/.cache/w3c-linux/wine.log`. The launcher's own log is
`<prefix>/drive_c/users/steamuser/W3Champions/logs/w3champions.<UTC date>.log`. When filing a bug, paste the output of
`w3c-linux report` (for example `w3c-linux report | wl-copy`) into the issue.

## Files it touches

| Path | What |
|---|---|
| `/usr/bin/w3c-linux`, `/usr/lib/w3c-linux/` | the package's command (a symlink) and the script with its `lib/`; pacman owns them, `w3c-linux` never writes there |
| `/usr/share/applications/w3c-linux.desktop`, `/usr/share/icons/hicolor/256x256/apps/w3c-linux.png` | the package's menu entry and icon; pacman owns them |
| `~/.local/share/faugus-launcher/games.json` | the Battle.net runner field only, with a timestamped backup in `~/.local/state/w3c-linux/` |
| `~/.local/share/Steam/compatibilitytools.d/GE-Proton11-7-W3C` | the patched Proton build |
| the Battle.net prefix | WebView2, registry tweaks, the W3Champions launcher, `W3Champions.bat` |
| `~/.local/state/w3c-linux/` | recorded versions, `nat-applied` marker, `matches.log`, locks, `games.json` backups |
| `~/.cache/w3c-linux/` | downloads, `wine.log` and `launch.log` (what `launch` printed when started from the menu) |
| `~/.local/share/applications/w3c-linux.desktop` | the app-menu entry a clone's `install` writes (not written when the package's system entry exists) |
| `~/.local/share/icons/hicolor/256x256/apps/w3c-linux.png` | the per-user icon `install` writes (also with the package, when `icoextract` and ImageMagick exist) |

To undo: `w3c-linux revert` restores the runner and, when it goes back to a non-W3C runner, removes the per-user menu entry and icon
(stepping back to an earlier W3C build keeps them). It never touches `/usr`; `sudo pacman -R w3c-linux` removes the package. Then uninstall W3Champions from inside the prefix, or keep it, and
remove the NAT rule with the printed lines.

## Layout

| Path | What |
|---|---|
| `w3c-linux.sh` | the entry: finds `lib/`, loads it, runs the subcommand |
| `lib/common.sh` | colours, output helpers, paths, prompts, state records, the run lock |
| `lib/faugus.sh` | everything that knows Faugus: `faugus_backend`, the only reader of Faugus's files and the contract it sets; the Faugus doctor rows and version check; the runner switch and backups; the Battle.net start; the idle check's Faugus processes |
| `lib/checks.sh` | the prefix, Warcraft III, host and Proton rows and `run_checks`, shared by `doctor`, `install`, `update`, `launch` and `report` |
| `lib/proton.sh` | patched Proton download, idle wait, removal of a replaced build |
| `lib/prefix.sh` | launcher version lookup and the in-prefix steps (WebView2, registry, launcher MSI) |
| `lib/nat.sh` | NAT rule text, apply and offer |
| `lib/doctor.sh`, `lib/install.sh`, `lib/revert.sh`, `lib/update.sh`, `lib/launch.sh`, `lib/monitor.sh`, `lib/report.sh` | one subcommand each |
| `lib/w3c-askpass.sh` | the password dialog `sudo -A` runs for the NAT rule when there is no terminal |
| `share/` | the shipped `.desktop` entry and icon that `install` places under `~/.local/share` |
| `lib/w3c_helper.py` | the Python JSON parsers, run as `python3 -I -B` |
| `packaging/PKGBUILD` | the Arch package recipe: installs this layout under `/usr/lib/w3c-linux` with `/usr/bin/w3c-linux` as a symlink |
| `LICENSE` | GPL-3.0 text |
| `tests/phaseN.sh` | the fixture suites, one per phase |
| `DESIGN.md` | what the planning IDs once cited in comments mean, and the backend contract |
| `docs/ARCHITECTURE.md` | Mermaid flow charts of every subcommand, each decision tagged with its DESIGN.md ID |

## Tests

```bash
for i in 1 2 3 4 5 6 7; do bash tests/phase$i.sh; done
shellcheck -x w3c-linux.sh lib/*.sh tests/phase*.sh
```

Phase 7 builds the real package, so it needs `makepkg`, `fakeroot`, `bsdtar` and `git`, and must run as a non-root user.

The fixture suites cover the script's pure logic. umu, Wine and Battle.net are never mocked; those parts are verified by hand on a
real machine.

## License

GPL-3.0-or-later. The text is in [LICENSE](LICENSE).
