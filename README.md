# w3c-arch-linux

[![Ko-fi](https://img.shields.io/badge/Ko--fi-Support%20this%20project-FF5E5B?logo=ko-fi&logoColor=white)](https://ko-fi.com/mykytabombela)

`w3c-linux` installs, launches and updates the [W3Champions](https://w3champions.com) launcher on Linux (Arch, Fedora, Debian/Ubuntu and their derivatives), inside the Battle.net
prefix that [Faugus Launcher](https://github.com/Faugus/faugus-launcher) already manages. There is no second prefix and no second
Battle.net install. The launcher runs in the same Proton build, wineserver and container as Battle.net and Warcraft III, so it can
see the game and submit ladder results.

W3Champions ships no Linux launcher. The current one is a closed-source Windows app (Tauri 2 + WebView2), so the script runs the
stock Windows launcher under Proton. Every step it cannot do for you (the root NAT rule, Blizzard sign-ins, the first Warcraft III
run) is a prompt that shows the exact command or action.

It is a bash script, `w3c-linux.sh`, plus the `lib/` files it loads, with no build step and no daemon. A release package (Arch, Fedora, Debian/Ubuntu) or `make install` installs it as the
`w3c-linux` command, or you run it from a clone as `bash w3c-linux.sh`. Everything it changes is listed under [Files it touches](#files-it-touches).

Below, examples say `w3c-linux`. From a clone, write `bash w3c-linux.sh` instead.

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Commands](#commands)
- [Without Faugus](#without-faugus)
- [Doctor](#doctor)
- [Known issues](#known-issues)
- [Files it touches](#files-it-touches)
- [Contributing](CONTRIBUTING.md): tests, CI, the nightly check and the source layout
- [License](#license)

## Requirements

| What | Why |
|---|---|
| Arch, Fedora or Debian/Ubuntu (or derivatives), x86_64, a graphical session (X11 or Wayland) | Battle.net and the launcher are GUI apps |
| [Faugus Launcher](https://github.com/Faugus/faugus-launcher), **native package, not Flatpak** (how to get it on each distro: [Installation](#installation)) | the script reads Faugus's `games.json` and reuses its `umu-run`; it cannot re-enter a Flatpak sandbox |
| A Battle.net entry in Faugus (*Add game → Battle.net*), installed and started at least once | creates the prefix, `umu-run` and the container the launcher joins |
| Warcraft III installed from Battle.net and **started once** | only the game creates `Documents/Warcraft III`, and the launcher refuses to start without it |
| `curl python3 sha256sum tar md5sum pgrep` | required; `doctor` fails without them |
| `setsid flock tail` (util-linux, coreutils) | needed by `launch` and the match monitor |
| `nft` or `iptables`, plus `sudo` | optional; needed for the LAN-test NAT rule (one root command, applied only if you answer y) |
| `zenity`, `notify-send` | optional on a terminal; needed to start `launch` from the app menu (every question is a dialog, errors and status are notifications), and for the lost-result notification |
| `make` (Arch: `base-devel`; Fedora and Debian/Ubuntu: `make`) | needed only for the [Makefile paths](#with-make) |
| `desktop-file-utils` | optional; `update-desktop-database` refreshes the menu cache after `install` writes the entry |
| `kernel.yama.ptrace_scope` 0 or 1 | 2 or 3 breaks the launcher's game attach (`sudo sysctl kernel.yama.ptrace_scope=1`) |
| About 3 GB free under `~/.local/share/Steam/compatibilitytools.d` | the patched Proton build |

Each distro's line under [Installation](#installation) installs these tools; its last three packages are the optional ones. The release
packages declare them, the optional ones as optional dependencies (Recommends on Fedora and Debian/Ubuntu, which dnf and apt install by default).
faugus-launcher is one of those optional dependencies.

The script installs the patched Proton build [`GE-Proton11-7-W3C`](https://github.com/davex32/proton-ge-w3c) itself. Stock Wine,
GE-Proton and Valve Proton all fail the launcher's kill-on-close job check (`VerifyJob`), so Battle.net has to run on this build.

## Installation

Pick your distro's subsection for the tools and Faugus Launcher (the native package, not Flatpak), then install w3c-linux with its
release package, [`make`](#with-make) or a [clone](#from-a-clone).

The packages are on the [latest release](https://github.com/Nikita-Bombela/w3c-arch-linux/releases/latest) page. Download the one for your
distro and run its command in that directory, with only that release's file there (the commands match by glob). To check a download, take
`SHA256SUMS` from the same page and run `sha256sum -c --ignore-missing SHA256SUMS`.

### Arch

On Arch: `sudo pacman -S --needed curl python coreutils tar procps-ng util-linux nftables zenity libnotify`

Faugus Launcher comes from the AUR. `makepkg` cannot fetch AUR dependencies, so use your AUR helper, for example `yay -S faugus-launcher`.
w3c-linux itself is not on the AUR. Arch users without the AUR install the release's `.pkg.tar.zst`:

```bash
sudo pacman -U ./w3c-linux-*-any.pkg.tar.zst
```

Or build the same package from the PKGBUILD:

```bash
git clone https://github.com/Nikita-Bombela/w3c-arch-linux
cd w3c-arch-linux/packaging
makepkg -si                  # builds the release the PKGBUILD names (v<pkgver>) and installs it
w3c-linux doctor             # read-only: every row should be pass or warn, no fail
w3c-linux install            # guided setup; ends with "Launch now?"
w3c-linux launch             # every later session
```

The PKGBUILD's `sha256sums` is filled in by a "packaging: sha256sums for v<pkgver>" commit right after each release. A clone taken at the release
tag itself, or in the minutes before that commit, fails the integrity check with `FAILED`. Clone the default branch, wait for the commit, or run
`makepkg -si --skipinteg` once.

Run it from a terminal in your desktop session. Close Battle.net before `install`: the script waits until the prefix is idle before
it changes anything. Running `w3c-linux` with no argument prints the usage, it does not install.

**Updating:** install the new release's `.pkg.tar.zst` the same way, or `git pull` and run `makepkg -si` again (or `yay -S w3c-linux`
once it is on the AUR, which it is not yet).

**Removing:** `sudo pacman -R w3c-linux` removes the package files. `~/.local/state/w3c-linux` and `~/.cache/w3c-linux`
stay. Run `w3c-linux revert` first if Faugus's runner should go back.

### Fedora

On Fedora: `sudo dnf install curl python3 coreutils tar procps-ng util-linux-core nftables zenity libnotify`

Faugus Launcher comes from its Copr, which builds Fedora 43 and later (on an older release take the `.rpm` from
https://github.com/Faugus/faugus-launcher/releases/latest):

```bash
sudo dnf copr enable faugus/faugus-launcher
sudo dnf install faugus-launcher
```

Then install w3c-linux from the release's `.noarch.rpm` (dnf also installs the recommended tools, and faugus-launcher when its Copr is
enabled), or with [make](#with-make) or from a [clone](#from-a-clone):

```bash
sudo dnf install ./w3c-linux-*.noarch.rpm
```

`sudo dnf remove w3c-linux` removes it.

### Debian/Ubuntu

On Debian/Ubuntu: `sudo apt install curl python3 coreutils tar procps util-linux nftables zenity libnotify-bin`

Ubuntu and its derivatives get Faugus Launcher from its PPA, which builds Ubuntu 24.04 and 26.04:

```bash
sudo dpkg --add-architecture i386
sudo add-apt-repository ppa:faugus/faugus-launcher
sudo apt update
sudo apt install faugus-launcher
```

Debian takes the `faugus-launcher_<version>_all.deb` from https://github.com/Faugus/faugus-launcher/releases/latest:

```bash
sudo dpkg --add-architecture i386
sudo apt update
sudo apt install ./faugus-launcher_*_all.deb
```

Then install w3c-linux from the release's `.deb` (apt also installs the recommended tools, and faugus-launcher where its repository is
set up), or with [make](#with-make) or from a [clone](#from-a-clone):

```bash
sudo apt install ./w3c-linux_*_all.deb
```

`sudo apt remove w3c-linux` removes it.

### With make

System-wide, as root. To install the same files as the package, under `/usr`:

```bash
sudo make install
```

To remove them:

```bash
sudo make uninstall
```

`PREFIX=/usr/local` (or any prefix) works too. If w3c-linux came from a package, remove it with your package manager (`sudo pacman -R w3c-linux`, `sudo dnf remove w3c-linux` or
`sudo apt remove w3c-linux`), never with `make uninstall` (the package manager would keep tracking files that no longer exist).

Packagers stage into a root instead (this is what the PKGBUILD runs):

```bash
make install DESTDIR="$pkgdir" PREFIX=/usr
```

Per user, no root (Bazzite, Steam Deck and other read-only `/usr` systems): run these as your normal user, never with `sudo`. To install:

```bash
make install-user
```

This installs `~/.local/bin/w3c-linux`, `~/.local/lib/w3c-linux/`, `~/.local/share/applications/w3c-linux.desktop` and
`~/.local/share/icons/hicolor/256x256/apps/w3c-linux.png`. The menu entry runs `~/.local/bin/w3c-linux` by its full path; the `w3c-linux`
command needs `~/.local/bin` on your `PATH` (doctor's `install location` row warns when it is not). To update, `git pull` and run
`make install-user` again.

To remove it:

```bash
make uninstall-user
```

This removes those four paths. `~/.local/state/w3c-linux`, `~/.cache/w3c-linux` and `~/.config/w3c-linux` stay.

With both a system and a per-user install, doctor's `other install` row says which one your shell and your menu run; remove one.

`make check` runs shellcheck and every fixture suite (it needs shellcheck; phase 7 also needs makepkg, fakeroot and bsdtar).
`make check SUITES='tests/phase1[01].sh'` runs a subset (pass the glob quoted).

### From a clone

Install your distro's line and Faugus Launcher first (above), then:

```bash
git clone https://github.com/Nikita-Bombela/w3c-arch-linux && cd w3c-arch-linux
bash w3c-linux.sh doctor     # read-only: every row should be pass or warn, no fail
bash w3c-linux.sh install    # guided setup; ends with "Launch now?"
bash w3c-linux.sh launch     # every later session
```

To run it as `w3c-linux` from anywhere, run `make install-user` (see [With make](#with-make)). A clone kept in a directory whose path ends in
`lib/w3c-linux` is taken for an install.

## Commands

Running it with no argument prints the usage. Everything below is `w3c-linux <command>`.

| Command | What it does |
|---|---|
| [`install`](#install) | Guided setup from a working Faugus Battle.net to a playable W3Champions. Asks every question first, then works unattended. Rerun after a failure: finished steps are skipped. |
| [`launch`](#launch) | Starts W3Champions inside Battle.net's running container (starts Battle.net first if needed) and runs the match monitor. Use it every session. |
| `update` | Checks for a newer launcher (`latest.json`) and a newer patched Proton release, and asks before installing either. The previous Proton build stays installed until you remove it. Prints read-only notes on whether an upstream Wine or GE fix has landed; never switches the runner back by itself. |
| `doctor` | Read-only report ([below](#doctor)). Reads files and makes one GET of `latest.json`; never writes, starts Wine or runs sudo. Exit 0 when no row fails. |
| `revert` | Switches Faugus's Battle.net runner back: to the previous W3C build after an `update`, or to the runner you had before `install`. Backs up `games.json` first. |
| `backend` | `set umu PREFIX RUNNER` saves an existing Battle.net prefix and a runner so every command works without Faugus; `show` prints the active backend and where it comes from; `clear` goes back to Faugus. See [Without Faugus](#without-faugus). |
| `monitor` | The match monitor on its own (`launch` already starts it). Prints `monitor: already running` and exits 0 if one is running. |
| `version` | Prints `w3c-linux 0.3.1`. `w3c-linux --version` and `-V` do the same. |
| `report` | Read-only and offline: prints a Markdown bug report for the maintainer (distro and its family, kernel, GPU, Vulkan ICDs for x86_64 and i686, w3c-linux, Faugus, umu, Proton, launcher and WebView2 versions, last 40 lines of `wine.log` and of the launcher log). Paths under your home show as `~`; review it before pasting, the launcher log can contain your BattleTag. `W3C_REPORT_LINES=N` changes the line count. |

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
10. Sets up the app-menu entry without asking, and only for a complete install. When the copy you run was installed (package,
    `make install` or `make install-user`), the installed entry is used: `install` writes no per-user entry, prints `Desktop entry:
    the system entry is used (...)` (or `Desktop entry: the entry make install-user wrote is used (...)`), and removes a per-user
    entry that an earlier clone install wrote. From a clone it writes `~/.local/share/applications/w3c-linux.desktop` and copies the
    shipped icon to `~/.local/share/icons/hicolor/256x256/apps/w3c-linux.png`. It prints one line and says "already installed" when
    nothing changed.
11. Asks `Launch now?`.

A failed step stops `install`. Rerun it: finished steps are skipped. `W3C_WEBVIEW_WINVER=win8 w3c-linux install` switches the
WebView2 app version if the launcher window is white or black, or crashes in `ole32`.

### `launch`

Starts W3Champions inside Battle.net's running container.

- If Battle.net is not running, it starts it through Faugus and waits up to 120 s for its container. With the umu backend ([Without Faugus](#without-faugus)) it starts `Battle.net Launcher.exe` from the prefix through `umu-run` instead, with the same wait.
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

## Without Faugus

`w3c-linux` can work from a Battle.net prefix you already have, with no Faugus Launcher. This is the umu backend. `launch` starts
Battle.net itself through `umu-run`, and `doctor`, `install` and `update` work on that prefix. Faugus's `games.json` is never read or
written in this mode.

What it needs:

- A Battle.net prefix you already have: a Wine prefix with `drive_c` and Battle.net installed in it. `w3c-linux` never creates a
  prefix and never installs Battle.net, umu or Faugus.
- An `umu-run`: Faugus's own copy if it is there, else `UMU_RUN=/path/to/umu-run`, else the first `umu-run` on `PATH` (the
  `umu-launcher` package), else `/usr/share/umu/umu-run`. A `UMU_RUN` that is set but not executable fails the `umu-run` row; the
  search does not go on past it.

**Saved in a file:**

```bash
w3c-linux backend set umu ~/Games/battlenet GE-Proton11-7-W3C   # PREFIX needs drive_c; RUNNER is a compatibilitytools.d name or an absolute path
w3c-linux install   # installs the patched Proton and, after asking, saves its tag as RUNNER; rerun it for the prefix steps
w3c-linux launch    # starts Battle.net through umu-run when it is not running
w3c-linux backend show    # which backend is active and where it comes from
w3c-linux backend clear   # back to Faugus
```

The file is `~/.config/w3c-linux/backend` (`$XDG_CONFIG_HOME` is honoured), three lines: `BACKEND=umu`, `PREFIX=...`, `RUNNER=...`.
It is read as data and never run. `backend set` refuses a PREFIX without `drive_c`; it does not check RUNNER, since the build may not be
installed yet (`doctor` reports on it).

**Or set environment variables.** Set both `W3C_PREFIX` and `W3C_PROTON` (a `compatibilitytools.d` name or an absolute path):

```bash
W3C_PREFIX=~/Games/battlenet W3C_PROTON=GE-Proton11-7-W3C w3c-linux launch          # one command
export W3C_PREFIX=~/Games/battlenet W3C_PROTON=GE-Proton11-7-W3C                    # in ~/.bashrc
```

For a launch from the app menu, which does not read `~/.bashrc`, put the same two lines, without `export`, in
`~/.config/environment.d/w3c-linux.conf`:

```
W3C_PREFIX=/home/you/Games/battlenet
W3C_PROTON=GE-Proton11-7-W3C
```

It takes effect at your next login. The variables win over the saved file. Setting only one of the two stops every command with
`set both W3C_PREFIX and W3C_PROTON, or neither`. With the variables, `install` cannot change your environment: it prints the
`W3C_PROTON=<tag>` line to set instead of saving the tag.

What changes in this mode:

- `doctor` shows a `backend` row in place of `faugus version`; the Faugus rows say `skip needs: Faugus (backend: umu)`. See
  [What each row means](#what-each-row-means).
- `launch` starts `Battle.net Launcher.exe` from the prefix through `umu-run`, waits for its container, then starts the launcher
  inside it. It never starts Faugus.
- `install` and `update` install the patched Proton and never touch `games.json`. The in-prefix steps (WebView2, registry, launcher
  MSI) refuse until the runner is that build, so the first `install` ends with the saved tag (or the line to set) and you run it again.
- `revert` has nothing to switch back and says so.

## Doctor

`w3c-linux doctor` prints one `status  label  value` line per check, in the order of the tables below.

Before `install`, the rows from `w3c build` down are mostly `warn ... run w3c-linux install`. That is expected.

**Statuses:**
- `pass`: fine.
- `warn`: works, but something is missing or outdated. The row says what to run.
- `fail`: `install`, `update` and `launch` refuse to run until it is fixed.
- `skip`: not checked, because an earlier row failed (`needs: <what>`).

### What each row means

**Faugus and the Battle.net entry**

With the umu backend, the `games.json`, `battlenet`, `launch_arguments` and `path` rows, and `config.json`, `envar.json` and `faugus env` under Environment, show `skip needs: Faugus (backend: umu)`, and `launch env` lists `WINE_SIMULATE_WRITECOPY=1` and `PROTON_ENABLE_WAYLAND=0` unless you exported them.

| Row | Meaning | If not pass |
|---|---|---|
| `version` | this tool's own version, the same string as `w3c-linux --version` (always the first row) | |
| `distro` | the system's name (`PRETTY_NAME` from `/etc/os-release`) and its family, `arch`, `fedora`, `debian` or `unknown`, which picks the package names and the command in every hint. It comes from `ID`, then `ID_LIKE`, else the first of `pacman`, `dnf`, `apt-get` on `PATH`, shown as `(fedora, from dnf on PATH)`. Always pass | With `unknown` the hints say `install <packages> with your package manager`. |
| `backend` | umu backend only, in place of `faugus version`: where the prefix and runner come from (`W3C_PREFIX and W3C_PROTON`, or the backend file), and that Faugus's `games.json` is not read or written | |
| `faugus version` | Faugus's own version, read from the installed package, else your family's package query (`pacman -Q`, `rpm -q` or `dpkg-query -W`; none for `unknown`); 2.x is the tested format | warn `untested Faugus major N` (`games.json` or `envar.json` may differ) or `unknown`; it never blocks `install`, `launch` or `update`. |
| `games.json` | Faugus's game list | Install Faugus and add Battle.net, or use an existing prefix with `backend set umu PREFIX RUNNER` ([Without Faugus](#without-faugus)). A Flatpak Faugus is reported and unsupported. |
| `battlenet` | exactly one entry with `gameid` battlenet | Add Battle.net in Faugus, or remove the duplicate. |
| `prefix` `runner` `launch_arguments` `path` | that entry's fields, as stored | `prefix` must be set; the others are shown for reference. |
| `PREFIX` | the prefix path resolved the way Faugus does (`~`, `$VAR`, symlinks) | |
| `APPID` | md5 of `PREFIX`; umu names Battle.net's container `com.steampowered.App<APPID>` | |
| `W3C_EXE` | where the launcher is (or will be) installed | |
| `launch-client` | umu's tool for entering a running container | warn: launch Battle.net once in Faugus so umu downloads it. |
| `umu-run`, `umu version` | the `umu-run` found, Faugus's bundled copy first (bare path), then `UMU_RUN`, the first one on `PATH`, `/usr/share/umu/umu-run`; the row ends `(UMU_RUN)`, `(PATH)` or `(/usr/share/umu)` for those. The version is Faugus's `version.txt`, else `umu-run --version` (the one program `doctor` runs, stopped after 5 s); `unknown` (warn) if that fails | fail: launch any game once in Faugus so it downloads `umu-run`, or install `umu-launcher` or set `UMU_RUN`. A `UMU_RUN` that is not executable fails and names it. |

**Prefix and game**

| Row | Meaning | If not pass |
|---|---|---|
| `system.reg`, `Battle.net.exe` | the prefix really holds Battle.net | Install Battle.net in that prefix through Faugus. |
| `wc3 dir`, `wc3 exe`, `wc3 build` | Warcraft III's install and build (from the registry and `.build.info`) | Install Warcraft III from Battle.net and start it once. |
| `wc3 user data` | `Documents/Warcraft III` exists | warn: start Warcraft III once from Battle.net, then close it. The launcher refuses to start without it. |

**Host**

| Row | Meaning | If not pass |
|---|---|---|
| `required tools` | `curl python3 sha256sum tar md5sum pgrep` | Install the missing ones: the row ends with your family's command, for example `missing: tar pgrep: sudo dnf install tar procps-ng`. |
| `optional tool` | `zenity nft iptables sudo notify-send`, present or absent (always pass); an absent tool's row ends with its install command (not for `sudo`) | Install `nft` or `iptables` + `sudo` for the NAT step. |
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
| `/usr/bin/w3c-linux`, `/usr/lib/w3c-linux/` | the package's command (a symlink) and the script with its `lib/`; the package manager owns them, `w3c-linux` never writes there |
| `/usr/share/applications/w3c-linux.desktop`, `/usr/share/icons/hicolor/256x256/apps/w3c-linux.png` | the package's menu entry and icon; the package manager owns them |
| `~/.local/share/faugus-launcher/games.json` | the Battle.net runner field only, with a timestamped backup in `~/.local/state/w3c-linux/`; never touched with the umu backend |
| `~/.config/w3c-linux/backend` | the umu backend's prefix and runner: written by `backend set` and, with this backend, by `install` and `update` (the new runner tag); removed by `backend clear` |
| `~/.local/share/Steam/compatibilitytools.d/GE-Proton11-7-W3C` | the patched Proton build |
| the Battle.net prefix | WebView2, registry tweaks, the W3Champions launcher, `W3Champions.bat` |
| `~/.local/state/w3c-linux/` | recorded versions, `nat-applied` marker, `matches.log`, locks, `games.json` backups |
| `~/.cache/w3c-linux/` | downloads, `wine.log` and `launch.log` (what `launch` printed when started from the menu) |
| `~/.local/share/applications/w3c-linux.desktop` | the app-menu entry a clone's `install` writes (not written when an installed entry exists); `make install-user` also writes it (Exec on `~/.local/bin/w3c-linux`), and `install` and `revert` then leave it alone |
| `~/.local/bin/w3c-linux`, `~/.local/lib/w3c-linux/` | `make install-user`'s command and script; removed by `make uninstall-user`, never written by w3c-linux |
| `~/.local/share/icons/hicolor/256x256/apps/w3c-linux.png` | the per-user icon a clone's `install` copies, or `make install-user` installs |

To undo: `w3c-linux revert` restores the runner and, when it goes back to a non-W3C runner, removes the per-user menu entry
`install` wrote (its `Exec` names a `w3c-linux.sh`) and its icon; a file of that name it did not write stays, with one `Kept` line, and so does an icon with no such entry
(stepping back to an earlier W3C build keeps them). It never touches `/usr`; removing the package (`sudo pacman -R w3c-linux`, `sudo dnf remove w3c-linux` or `sudo apt remove w3c-linux`) removes those files. An entry make installed stays until `make uninstall-user`. Then uninstall W3Champions from inside the prefix, or keep it, and
remove the NAT rule with the printed lines.

## License

GPL-3.0-or-later. The text is in [LICENSE](LICENSE).
