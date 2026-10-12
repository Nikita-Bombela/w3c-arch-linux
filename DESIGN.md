# Design reference

Comments in `w3c-linux.sh` and `lib/` explain themselves in plain sentences. This file keeps each planning ID they used to cite
traceable to the document that defines it; decision numbers restart at D-01 in every phase, so they are written with their phase.

## Decisions

| ID | Meaning | Source |
|----|---------|--------|
| Phase 1 D-01 | `ptrace_scope` is read from `W3C_PTRACE_SCOPE_FILE` (default `/proc/sys/kernel/yama/ptrace_scope`), the only test seam in the script. | `.planning/phases/01-detect-and-doctor/01-CONTEXT.md` |
| Phase 1 D-04 | Fixtures run only the real entry point, so prompts are tested through `install` with piped stdin and a zenity shim. | `.planning/phases/01-detect-and-doctor/01-CONTEXT.md` |
| Phase 1 D-05 | Every output line is `status  label  value`, one per detected value, printed only through `emit`. | `.planning/phases/01-detect-and-doctor/01-CONTEXT.md` |
| Phase 1 D-08 | Exit codes and streams: report lines go to stdout, usage errors, the EOF abort and prompts go to stderr; prompts are written with `printf` because `read -p` prints nothing without a terminal. | `.planning/phases/01-detect-and-doctor/01-CONTEXT.md` |
| Phase 1 D-09 | Python hands values to bash NUL-delimited and bash reads them with `mapfile -d ''`; there is no `eval`. | `.planning/phases/01-detect-and-doctor/01-CONTEXT.md` |
| Phase 1 D-10 | Python parses only the JSON files (`games.json`, `config.json`, `envar.json`); `system.reg` and `.build.info` are read in bash and awk. | `.planning/phases/01-detect-and-doctor/01-CONTEXT.md` |
| Phase 1 D-11 | The mirrored Faugus env is two bash arrays, toggles then `envar.json`, so later phases keep Faugus precedence. | `.planning/phases/01-detect-and-doctor/01-CONTEXT.md` |
| Phase 1 D-12 | `BN_LAUNCH_ENV` is the env part of `launch_arguments` built by Faugus's own rule, with `~` and `$VAR` expanded first. | `.planning/phases/01-detect-and-doctor/01-CONTEXT.md` |
| Phase 2 D-02 | A missing `running-games.json` counts as idle; the file is busy unless it parses to an empty dict. | `.planning/phases/02-patched-proton-and-runner-switch/02-CONTEXT.md` |
| Phase 2 D-03 | When busy, prompt 2 names only what still runs, waits for Enter with no retry cap, and never kills anything. | `.planning/phases/02-patched-proton-and-runner-switch/02-CONTEXT.md` |
| Phase 2 D-04 | The prefix also counts as busy while its own wineserver is alive; the idle check's `BUSY` contract is frozen for later phases. | `.planning/phases/02-patched-proton-and-runner-switch/02-CONTEXT.md` |
| Phase 2 D-06 | Downloads never resume: leftovers are deleted and the download restarts from zero. | `.planning/phases/02-patched-proton-and-runner-switch/02-CONTEXT.md` |
| Phase 2 D-08 | Extraction goes to a hidden staging dir inside `compatibilitytools.d`; a build is complete only when `proton`, `compatibilitytool.vdf`, `version` and `files/` exist. | `.planning/phases/02-patched-proton-and-runner-switch/02-CONTEXT.md` |
| Phase 2 D-09 | Tag and asset names from the GitHub API are untrusted: the tag must be a single safe path component and is validated at the Python edge. | `.planning/phases/02-patched-proton-and-runner-switch/02-CONTEXT.md` |
| Phase 2 D-10 | `install` records the installed tag in `~/.local/state/w3c-linux/proton-tag`, the expected W3C build for `doctor` and `update`. | `.planning/phases/02-patched-proton-and-runner-switch/02-CONTEXT.md` |
| Phase 2 D-11 | When the GitHub API is unreachable but a complete recorded build exists, `install` warns and continues with it. | `.planning/phases/02-patched-proton-and-runner-switch/02-CONTEXT.md` |
| Phase 2 D-12 | `install` is idempotent and sticks to the recorded build; a newer upstream tag only prints a notice pointing to `update`. | `.planning/phases/02-patched-proton-and-runner-switch/02-CONTEXT.md` |
| Phase 2 D-13 | The new `doctor` rows for the W3C build are warn, never fail, so `doctor`'s exit status is unchanged. | `.planning/phases/02-patched-proton-and-runner-switch/02-CONTEXT.md` |
| Phase 2 D-14 | When the runner already equals the recorded tag, `install` skips the switch prompt: no backup and no write. | `.planning/phases/02-patched-proton-and-runner-switch/02-CONTEXT.md` |
| Phase 2 D-15 | `revert` restores the runner from the newest backup whose runner is not a W3C build. | `.planning/phases/02-patched-proton-and-runner-switch/02-CONTEXT.md` |
| Phase 2 D-17 | After a revert, a default-No prompt offers to delete the W3C build, unless a `games.json` entry still uses it. | `.planning/phases/02-patched-proton-and-runner-switch/02-CONTEXT.md` |
| Phase 2 D-18 | All `games.json` backups are kept; none are pruned. | `.planning/phases/02-patched-proton-and-runner-switch/02-CONTEXT.md` |
| Phase 2 D-20 | The `games.json` write mirrors Faugus's `save_json_file` (indent 4, no trailing newline, temp file and `os.replace`) so a diff shows only the `runner` line. | `.planning/phases/02-patched-proton-and-runner-switch/02-CONTEXT.md` |
| Phase 3 D-01 | All prompts come first in one batch, then `install` runs unattended: downloads, one idle wait, the switch and the chosen steps. | `.planning/phases/03-prefix-provisioning/03-CONTEXT.md` |
| Phase 3 D-02 | Installers (WebView2, launcher MSI) are downloaded before the idle wait, with no resume, while Faugus or Battle.net may still run. | `.planning/phases/03-prefix-provisioning/03-CONTEXT.md` |
| Phase 3 D-04 | A failed prefix step stops `install` with a clear message, finished steps are skipped on the rerun, and files are trusted over exit codes. | `.planning/phases/03-prefix-provisioning/03-CONTEXT.md` |
| Phase 3 D-05 | The registry step is skipped only when all its items already hold; one missing item means a full apply. | `.planning/phases/03-prefix-provisioning/03-CONTEXT.md` |
| Phase 3 D-07 | An unset `W3C_WEBVIEW_WINVER` never reverts; `win7` and `win8` both count as satisfied and the variable only forces a change. | `.planning/phases/03-prefix-provisioning/03-CONTEXT.md` |
| Phase 3 D-08 | The WebView2 step is skipped when `msedgewebview2.exe` exists anywhere under the prefix; its version is still reported. | `.planning/phases/03-prefix-provisioning/03-CONTEXT.md` |
| Phase 3 D-09 | The `system.reg` DisplayVersion of W3Champions is the installed launcher version; the recorded `launcher-version` file is the fallback. | `.planning/phases/03-prefix-provisioning/03-CONTEXT.md` |
| Phase 3 D-10 | `doctor` goes online once, for `latest.json` only, with a short timeout, writing nothing. | `.planning/phases/03-prefix-provisioning/03-CONTEXT.md` |
| Phase 3 D-12 | The new prefix and launcher `doctor` rows are warn, never fail. | `.planning/phases/03-prefix-provisioning/03-CONTEXT.md` |
| Phase 3 D-13 | One `update` run handles the launcher and Proton, asking every prompt first, then downloading, waiting once and installing. | `.planning/phases/03-prefix-provisioning/03-CONTEXT.md` |
| Phase 3 D-14 | A newer Proton tag is detected against `proton-tag`, and the replaced tag is written to `proton-tag.prev`. | `.planning/phases/03-prefix-provisioning/03-CONTEXT.md` |
| Phase 3 D-15 | The replaced W3C build is removed only when the user says so on a later run, never in the run that switches. | `.planning/phases/03-prefix-provisioning/03-CONTEXT.md` |
| Phase 3 D-16 | `revert` first steps back one W3C build when `proton-tag.prev` names a complete one; the W3C test is the recorded tag or a `*-W3C` name. | `.planning/phases/03-prefix-provisioning/03-CONTEXT.md` |
| Phase 3 D-17 | The upstream-fix watch runs live wherever no authentication is needed and is advisory output only (amended at planning to count `limit_flags` in the `get_job_info` block). | `.planning/phases/03-prefix-provisioning/03-CONTEXT.md` |
| Phase 4 D-01 | `launch` stays in the foreground until the launcher exits, which gives the monitor an owner. | `.planning/phases/04-launch/04-CONTEXT.md` |
| Phase 4 D-03 | The run lock is held only during preflight and start, and released once the launcher runs, so `doctor` works during play. | `.planning/phases/04-launch/04-CONTEXT.md` |
| Phase 4 D-05 | If `W3Champions.exe` already runs, `launch` says so and exits 0; this check precedes the Bonjour and updater cleanup. | `.planning/phases/04-launch/04-CONTEXT.md` |
| Phase 4 D-06 | The sign-in prompt appears on every launch; `q` or EOF aborts. | `.planning/phases/04-launch/04-CONTEXT.md` |
| Phase 4 D-07 | An open Faugus window is irrelevant to `launch`; the idle gate never applies to it. | `.planning/phases/04-launch/04-CONTEXT.md` |
| Phase 4 D-08 | The fallback to a separate container asks with default No and is never silent. | `.planning/phases/04-launch/04-CONTEXT.md` |
| Phase 4 D-09 | The WC3 user-data folder is checked before the launcher starts, because the launcher refuses to run without it. | `.planning/phases/04-launch/04-CONTEXT.md` |
| Phase 4 D-10 | The restart path waits until the launcher window is closed, then starts it again in the same container; the wrapper never kills it. | `.planning/phases/04-launch/04-CONTEXT.md` |
| Phase 4 D-11 | The first-run Bonjour notice shows until `mDNSResponder.exe` exists in the prefix; it is a file check with no state file. | `.planning/phases/04-launch/04-CONTEXT.md` |
| Phase 4 D-12 | The Play guidance is one line on every launch. | `.planning/phases/04-launch/04-CONTEXT.md` |
| Phase 4 D-13 | The exe is the default target; `W3C_LAUNCH_BAT=1` switches to the `.bat` for that run only, and nothing is remembered. | `.planning/phases/04-launch/04-CONTEXT.md` |
| Phase 4 D-14 | `W3Champions.bat` is written on every launch when missing or different, four CRLF lines verbatim from W3ChampionsOnLinux. | `.planning/phases/04-launch/04-CONTEXT.md` |
| Phase 4 D-15 | While `launch` waits it watches the launcher log and prints a LAN-test-failure hint once per session. | `.planning/phases/04-launch/04-CONTEXT.md` |
| Phase 5 D-01 | `install` prompt 8 prints the full NAT block (apply, removal, side-effect note, persistence notes) after the launcher step. | `.planning/phases/05-nat-guidance-and-monitor/05-CONTEXT.md` |
| Phase 5 D-02 | After n, Enter continues and `q` or EOF also continue without the rule; the NAT step never fails `install`. | `.planning/phases/05-nat-guidance-and-monitor/05-CONTEXT.md` |
| Phase 5 D-03 | `launch` asks nothing about NAT up front; the launcher's own LAN-test result is the per-launch check and pauses the follow tick. | `.planning/phases/05-nat-guidance-and-monitor/05-CONTEXT.md` |
| Phase 5 D-04 | A per-boot marker holding the `boot_id` records that this script applied the rule this boot. | `.planning/phases/05-nat-guidance-and-monitor/05-CONTEXT.md` |
| Phase 5 D-05 | The variant is nft when `nft` is on PATH, else iptables, else no apply offer; there is no override. | `.planning/phases/05-nat-guidance-and-monitor/05-CONTEXT.md` |
| Phase 5 D-06 | The applied command is idempotent and the printed text is exactly what `sudo` runs. | `.planning/phases/05-nat-guidance-and-monitor/05-CONTEXT.md` |
| Phase 5 D-07 | Persistence is printed only, labelled unverified, and never touches `/etc`. | `.planning/phases/05-nat-guidance-and-monitor/05-CONTEXT.md` |
| Phase 5 D-08 | Prompt 9 prints firewall ports and an NTP hint only when relevant, and runs only unprivileged reads. | `.planning/phases/05-nat-guidance-and-monitor/05-CONTEXT.md` |
| Phase 5 D-09 | RESULT-LOST is armed by game-end: the next `submitGameExited` with no current match raises it and disarms. | `.planning/phases/05-nat-guidance-and-monitor/05-CONTEXT.md` |
| Phase 5 D-10 | A `joined` event naming the launcher's `w3c-test-` LAN game is skipped. | `.planning/phases/05-nat-guidance-and-monitor/05-CONTEXT.md` |
| Phase 5 D-11 | The notification always fires on RESULT-LOST, as `notify-send -u critical` naming the newest replay. | `.planning/phases/05-nat-guidance-and-monitor/05-CONTEXT.md` |
| Phase 5 D-12 | The monitored log is the launcher's daily file named by the UTC date. | `.planning/phases/05-nat-guidance-and-monitor/05-CONTEXT.md` |
| Phase 5 D-13 | Each `matches.log` line carries a config tag (target, mode, WebView flags). | `.planning/phases/05-nat-guidance-and-monitor/05-CONTEXT.md` |
| Phase 5 D-14 | `monitor` is always silent on stdout; its outputs are `matches.log` and `notify-send`, and errors go to stderr. | `.planning/phases/05-nat-guidance-and-monitor/05-CONTEXT.md` |
| Phase 5 D-15 | The armed state expires after about 120 seconds, so a standby exit after a good match raises no false RESULT-LOST. | `.planning/phases/05-nat-guidance-and-monitor/05-CONTEXT.md` |
| Phase 6 D-01 | The Battle.net sign-in wait stays a zenity question on every launch without a terminal; No stops with nothing started. | `.planning/phases/06-terminal-free-launch-and-desktop-entry/06-CONTEXT.md` |
| Phase 6 D-02 | Without a terminal the NAT offer is a zenity question carrying the full block, then `sudo -A` runs the same printed script with `SUDO_ASKPASS` on a helper whose password dialog names the exact root command; the terminal path keeps foreground `sudo`, and without zenity nothing is applied. | `.planning/phases/06-terminal-free-launch-and-desktop-entry/06-CONTEXT.md` |
| Phase 6 D-03 | The separate-container fallback and the Warcraft III user-data loop are zenity questions with the terminal's defaults (No for the fallback). | `.planning/phases/06-terminal-free-launch-and-desktop-entry/06-CONTEXT.md` |
| Phase 6 D-04 | The Enter-to-restart path is dropped without a terminal: `follow_launcher` only waits, and a launcher that exits within seconds gets a notification saying to start Warcraft III once from Battle.net and start W3Champions again. | `.planning/phases/06-terminal-free-launch-and-desktop-entry/06-CONTEXT.md` |
| Phase 6 D-05 | `install`, `update`, `revert` and `doctor` stay terminal-only; only `launch` (and the `monitor` it owns) goes terminal-free. | `.planning/phases/06-terminal-free-launch-and-desktop-entry/06-CONTEXT.md` |
| Phase 6 D-06 | "No terminal" means stdin is not a tty; the harness-only `W3C_ASSUME_TTY=1` override (amended at planning) lets the phase 2 to 5 suites keep exercising the terminal path and is not documented for users. | `.planning/phases/06-terminal-free-launch-and-desktop-entry/06-CONTEXT.md` |
| Phase 6 D-07 | With no terminal and no zenity, `launch` refuses at the start with a critical `notify-send` naming the fix and exits 1. | `.planning/phases/06-terminal-free-launch-and-desktop-entry/06-CONTEXT.md` |
| Phase 6 D-08 | Without a terminal, `launch`'s own lines go to `~/.cache/w3c-linux/launch.log`, so they are not buried in Proton output (which stays in `wine.log`). | `.planning/phases/06-terminal-free-launch-and-desktop-entry/06-CONTEXT.md` |
| Phase 6 D-09 | `launch.log` rotates once before each no-terminal launch into `launch.log.1`, so two sessions are kept. | `.planning/phases/06-terminal-free-launch-and-desktop-entry/06-CONTEXT.md` |
| Phase 6 D-10 | Stops before the launcher starts are `zenity --error` dialogs carrying the one-line message and the `launch.log` path. | `.planning/phases/06-terminal-free-launch-and-desktop-entry/06-CONTEXT.md` |
| Phase 6 D-11 | Normal notifications are limited to the newer-launcher line and the first-run notice; everything else informational goes to `launch.log` only. | `.planning/phases/06-terminal-free-launch-and-desktop-entry/06-CONTEXT.md` |
| Phase 6 D-12 | "W3Champions is already running" is silent without a terminal: a log line and exit 0. | `.planning/phases/06-terminal-free-launch-and-desktop-entry/06-CONTEXT.md` |
| Phase 6 D-13 | A non-zero launcher exit after a successful start is a notification pointing at `launch.log`; status 0 is log only. | `.planning/phases/06-terminal-free-launch-and-desktop-entry/06-CONTEXT.md` |
| Phase 6 D-14 | The icon is a PNG shipped in the repo, replaced at install time by the launcher's own icon when `icoextract`, ImageMagick and `W3Champions.exe` are present. | `.planning/phases/06-terminal-free-launch-and-desktop-entry/06-CONTEXT.md` |
| Phase 6 D-15 | The repo ships `share/w3c-linux.desktop` with `Exec=w3c-linux launch`; `install` writes the user entry with `Exec` on the script's quoted realpath and copies the icon to `hicolor/256x256/apps`, checked with `desktop-file-validate`. | `.planning/phases/06-terminal-free-launch-and-desktop-entry/06-CONTEXT.md` |
| Phase 6 D-16 | `install` writes the entry and icon without a prompt, only for a complete install, atomically, saying "already installed" when nothing changed and running `update-desktop-database` when it is present. | `.planning/phases/06-terminal-free-launch-and-desktop-entry/06-CONTEXT.md` |
| Phase 6 D-17 | `doctor` has one `desktop entry` row (pass, absent or pointing at a missing script, always pass or warn) and `revert` deletes exactly the entry and icon it wrote, but only on the full restore to a non-W3C runner (amended at planning): stepping back to an earlier W3C build keeps them. | `.planning/phases/06-terminal-free-launch-and-desktop-entry/06-CONTEXT.md` |
| Phase 7 D-06 | `W3C_LINUX_VERSION` in `w3c-linux.sh` is the one version; the PKGBUILD `pkgver` equals it and its `check()` fails otherwise. | `.planning/phases/07-pkgbuild-packaging/07-CONTEXT.md` |
| Phase 7 D-07 | The version is printed by `--version`, `-V` and `version`, in the usage text, in `report` and as `doctor`'s first row. | `.planning/phases/07-pkgbuild-packaging/07-CONTEXT.md` |
| Phase 7 D-09 | With the system entry installed, `install` writes no per-user `.desktop` but still places the launcher icon per user when the tools exist. | `.planning/phases/07-pkgbuild-packaging/07-CONTEXT.md` |
| Phase 7 D-10 | `install` removes a per-user entry only when its `Exec` names a `w3c-linux.sh` path. | `.planning/phases/07-pkgbuild-packaging/07-CONTEXT.md` |
| Phase 7 D-11 | `doctor`'s desktop entry row: the system entry passes, a per-user file hiding it warns, the clone row is unchanged. | `.planning/phases/07-pkgbuild-packaging/07-CONTEXT.md` |
| Phase 7 D-13 | `BIN_NAME` is `w3c-linux` when the script lives at the package path, else `w3c-linux.sh`; it never comes from `$0`. | `.planning/phases/07-pkgbuild-packaging/07-CONTEXT.md` |
| Phase 8 D-01 | `.github/workflows/nightly.yml` lives and runs only in the private dev repo; it is never copied to the public repo. | `.planning/phases/08-nightly-dependency-check/08-CONTEXT.md` |
| Phase 8 D-08 | The nightly fails when the upstream watch lines differ from the known state (news), as well as on breakage; a "could not check" line is breakage. | `.planning/phases/08-nightly-dependency-check/08-CONTEXT.md` |
| Phase 8 D-09 | The known state is `tests/fixtures/upstream-state.txt`, the watch lines as printed; `tests/live.sh --offline` serves values that match it. | `.planning/phases/08-nightly-dependency-check/08-CONTEXT.md` |
| Phase 8 D-10 | Both MSI sources, the update API and `latest.json`'s URL, are downloaded and magic-checked separately, so a dead primary fails although the install fallback would hide it. | `.planning/phases/08-nightly-dependency-check/08-CONTEXT.md` |
| Phase 8 D-11 | `tests/live.sh` sends `GITHUB_TOKEN` only to `https://api.github.com/`, through a test-only curl wrapper reading a 0600 header file; without a token the calls go out unauthenticated. | `.planning/phases/08-nightly-dependency-check/08-CONTEXT.md` |
| Phase 8 D-12 | One job with named steps; every check step runs after an earlier failure (`!cancelled()`) and the upstream watch is last. | `.planning/phases/08-nightly-dependency-check/08-CONTEXT.md` |
| Phase 8 D-13 | `tests/live.sh --offline` serves generated fixtures through a curl shim first on `PATH`; `tests/phase8.sh` runs it in the regular suite set. | `.planning/phases/08-nightly-dependency-check/08-CONTEXT.md` |
| Phase 8 D-15 | `W3C_LIVE_RELEASE_API` replaces `RELEASE_API` in `tests/live.sh` after the libs load, for the deliberate red run; `lib/` is not edited. | `.planning/phases/08-nightly-dependency-check/08-CONTEXT.md` |
| Phase 8 D-16 | There is no headless MSI install check; MSI coverage is the file-magic check. | `.planning/phases/08-nightly-dependency-check/08-CONTEXT.md` |
| Phase 8 D-17 | The fixture suites and shellcheck run in `.github/workflows/ci.yml` on pull requests into main only (work goes through PRs; GitHub Free cannot require `tests` on a private repo, so check the PR result before merging); `nightly.yml` keeps only the install path and the live checks, so a red nightly means something upstream or in Arch moved. CI's container runs with `--init` so killed orphans are reaped. | `.planning/phases/08-nightly-dependency-check/08-05-SUMMARY.md` |
| Phase 9 D-01 | A per-user `w3c-linux.desktop` is ours when it is not a symlink and its `Exec="<path>" launch` line names a `w3c-linux.sh`, a moved or deleted clone included; `desk_ours` is the one test `install` and `revert` share, and any other file of that name is the user's. | `.planning/phases/09-address-tech-debt-revert-ownership-guard/09-CONTEXT.md` |
| Phase 9 D-02 | `revert` deletes the per-user icon only together with our entry; with no per-user entry or a foreign one the icon stays, including the package case where `install` places only the icon. | `.planning/phases/09-address-tech-debt-revert-ownership-guard/09-CONTEXT.md` |
| Phase 9 D-03 | A per-user entry that is not ours stays, and `revert` prints one line, `Kept <path>: not written by w3c-linux.`; the icon is never removed on its own. | `.planning/phases/09-address-tech-debt-revert-ownership-guard/09-CONTEXT.md` |
| Quick 261010-175 D-01 | Only `faugus_backend` reads Faugus's files for the launch contract; the in-prefix step keeps its old gate, re-reading only the runner through `faugus_backend runner` (same `games.json`, same refusals) while the prefix, env and `umu-run` stay as the checks read them. | `.planning/quick/261010-175-isolate-the-faugus-contract-in-lib-faugu/261010-175-PLAN.md` |
| Quick 261010-175 D-02 | Faugus's version is the `VERSION` line of the installed package's `faugus/launcher.py`, found with `importlib.util.find_spec` and read as text (never imported), with `pacman -Q faugus-launcher` as fallback; major 2 passes, any other major or an unreadable version warns and never blocks. | `.planning/quick/261010-175-isolate-the-faugus-contract-in-lib-faugu/261010-175-PLAN.md` |
| Quick 261010-175 D-03 | `W3C_FAUGUS_PY_DIR` points the version read at `DIR/faugus/launcher.py`, a test seam like `W3C_SYS_ROOT`, because `python3 -I` ignores `PYTHONPATH`. | `.planning/quick/261010-175-isolate-the-faugus-contract-in-lib-faugu/261010-175-PLAN.md` |

## Requirements

| ID | Meaning | Source |
|----|---------|--------|
| PRT-02 | The latest patched Proton is resolved from the GitHub releases API, parsed with `python3 -I`, never from a fixed-name download URL. | `.planning/REQUIREMENTS.md` |
| PRT-03 | The tarball is downloaded, checked against `SHA256SUMS` and extracted into `compatibilitytools.d/<tag>`. | `.planning/REQUIREMENTS.md` |
| PRT-04 | Only the battlenet entry's `runner` changes, after a `games.json` backup and through an atomic replace. | `.planning/REQUIREMENTS.md` |
| PRT-05 | `revert` restores the battlenet runner from a backup under the same idle, backup and atomic-write rules. | `.planning/REQUIREMENTS.md` |
| PRT-06 | `doctor` reports the configured runner against the expected W3C build, whether its directory exists, and the prefix version. | `.planning/REQUIREMENTS.md` |
| PFX-01 | `run_in_prefix` is the only way Wine starts in the Battle.net prefix, through Faugus's `umu-run` on the W3C runner and only when idle. | `.planning/REQUIREMENTS.md` |
| PFX-02 | The WebView2 Evergreen installer is run silently in the prefix, skipped when WebView2 is already present. | `.planning/REQUIREMENTS.md` |
| PFX-03 | `w3c.reg` is applied through `run_in_prefix regedit` and the prefix is set to Windows 10. | `.planning/REQUIREMENTS.md` |
| PFX-05 | `doctor` reports WebView2, the registry values, the launcher, and its recorded, installed and latest versions. | `.planning/REQUIREMENTS.md` |
| UPD-03 | `update` prints advisory text only for the upstream-fix watch. | `.planning/REQUIREMENTS.md` |
| LCH-01 | `launch` starts with a preflight: warn when the runner is not the W3C build and run a non-blocking launcher-update check. | `.planning/REQUIREMENTS.md` |
| LCH-02 | Battle.net counts as up when its bus name exists; otherwise `faugus-launcher --game battlenet` is started and the bus awaited for up to 120 seconds. | `.planning/REQUIREMENTS.md` |
| LCH-03 | W3Champions starts through Faugus's `umu-run` with the container re-entry variables, in a fixed env order where ours win. | `.planning/REQUIREMENTS.md` |
| LCH-06 | Before each launch, and only when no `W3Champions.exe` runs, stale Bonjour and Edge updater processes are cleared and `W3Champions.bat` is written. | `.planning/REQUIREMENTS.md` |
| NAT-05 | Prompt 9 prints firewall port and NTP information only when relevant. | `.planning/REQUIREMENTS.md` |
| MON-02 | On RESULT-LOST the monitor raises a critical `notify-send` naming the newest replay, degrading to the log line without `notify-send`. | `.planning/REQUIREMENTS.md` |
| MON-03 | `launch` starts at most one background monitor and none remains after the session ends. | `.planning/REQUIREMENTS.md` |

## Research findings

| ID | Meaning | Source |
|----|---------|--------|
| Phase 1 P2 | Nothing from the prefix or Faugus is ever executed: `umu-run` is tested with `-f` and `-x` and its version is read from `version.txt`. | `.planning/phases/01-detect-and-doctor/01-RESEARCH.md` |
| Phase 1 P6 | A `grep -A25` window on `system.reg` can cross into the next registry key, so it is cut at the first blank line. | `.planning/phases/01-detect-and-doctor/01-RESEARCH.md` |
| Phase 1 P7 | `strings` on `Warcraft III.exe` prints a trailing letter after the version, so only the dotted number is kept. | `.planning/phases/01-detect-and-doctor/01-RESEARCH.md` |
| Phase 2 F1 | `$PREFIX/version` never reads the W3C build name because Proton writes a hard-coded constant, so it is shown for information and never compared. | `.planning/phases/02-patched-proton-and-runner-switch/02-RESEARCH.md` |
| Phase 2 Pattern 2 | The prefix's wineserver is found by the server directory name derived from the prefix's `st_dev` and `st_ino`. | `.planning/phases/02-patched-proton-and-runner-switch/02-RESEARCH.md` |
| Phase 3 Pitfall 1 | A whole-file `limit_flags` count in `sync.c` reports a fix that does not exist; only the `get_job_info` request block counts. | `.planning/phases/03-prefix-provisioning/03-RESEARCH.md` |
| Phase 3 Pitfall 4 | Wine's registry files are current only after the wineserver exits, so the step waits for it before trusting them. | `.planning/phases/03-prefix-provisioning/03-RESEARCH.md` |
| Phase 3 Pitfall 5 | The MSI's Uninstall key lands in the 64-bit registry view, so both views are scanned. | `.planning/phases/03-prefix-provisioning/03-RESEARCH.md` |
| Phase 3 Pitfall 6 | The run-lock descriptor leaks into the wineserver unless Wine is started with it closed. | `.planning/phases/03-prefix-provisioning/03-RESEARCH.md` |
| Phase 3 Pitfall 8 | Our own lingering wineserver makes the next in-prefix command look busy, so the wineserver is settled between steps. | `.planning/phases/03-prefix-provisioning/03-RESEARCH.md` |
| Phase 5 Anti-Patterns | The monitor never uses a `tail \| while` pipeline: its subshell would lose the armed state and outlive the monitor. | `.planning/phases/05-nat-guidance-and-monitor/05-RESEARCH.md` |

## Review findings, threats and acceptance checks

| ID | Meaning | Source |
|----|---------|--------|
| Phase 2 WR-01 | `revert` must check that Battle.net is on a W3C build, so a deliberate runner is never replaced by an old backup (fixed in Phase 3). | `.planning/phases/02-patched-proton-and-runner-switch/02-REVIEW.md` |
| Phase 2 WR-02 | The compare-and-swap must treat a missing or non-string runner as `""`, like the reader, or `install` and `revert` fail with a false "games.json changed" (fixed in Phase 3). | `.planning/phases/02-patched-proton-and-runner-switch/02-REVIEW.md` |
| Phase 2 WR-03 | Concurrent `install` runs destroyed each other's download and staging dir, hence the run lock (fixed in Phase 3). | `.planning/phases/02-patched-proton-and-runner-switch/02-REVIEW.md` |
| Phase 2 WR-04 | A missing `pgrep` was found only after the large download and left an unrecoverable wait loop, so the wait stops with a message (fixed in Phase 3). | `.planning/phases/02-patched-proton-and-runner-switch/02-REVIEW.md` |
| Phase 2 T-02-16 | Poisoned leftovers in the cache or staging dir are removed before anything new is fetched. | `.planning/phases/02-patched-proton-and-runner-switch/02-03-PLAN.md` |
| Phase 3 T-03-01 | `latest.json` is untrusted: the launcher version and MSI URL are validated at the Python edge. | `.planning/phases/03-prefix-provisioning/03-01-PLAN.md` |
| Phase 1 AC-6 | Zenity is used only when it and a display variable are both present; a non-zero zenity exit is No. | `.planning/phases/01-detect-and-doctor/01-SPEC.md` |

## Backend contract

`faugus_backend` in `lib/faugus.sh` is the only code that reads Faugus's files. It prints nothing and sets the variables below, and
every other lib reads them. A Lutris or plain umu backend would be another function setting the same names; there is no dispatch yet.
`faugus_backend runner` is the one narrow form: it re-reads only the runner.

| Variable | Meaning | Faugus source |
|----------|---------|---------------|
| `NEED_ENTRY` | empty when the Battle.net entry was read, else the cause the skip rows print (`games.json`, `python3`, `battlenet entry`) | `games.json` and its battlenet entry |
| `NEED_PREFIX` | empty when the prefix is known, else the cause (`NEED_ENTRY`'s value, or `prefix`) | the entry's `prefix` field |
| `BN_SOURCE` | display only: the `games.json` path the entry was read from | `~/.local/share/faugus-launcher/games.json`, else the config home |
| `BN_PREFIX` | the prefix as stored | the entry's `prefix` field |
| `PREFIX` | the resolved prefix: Faugus's expansion of `~` and `$VAR`, then `realpath -m` | the entry's `prefix` field |
| `BN_RUNNER` | the runner name; empty means Faugus's UMU-Proton Latest | the entry's `runner` field |
| `RUNNER_PATH` | the `PROTONPATH` value: `compatibilitytools.d/<name>` when `BN_RUNNER` names a complete build, else the bare name | `BN_RUNNER` and the compat directory |
| `BN_RUNNER_NOW` | the runner as `games.json` holds it when an in-prefix step starts; set only by `faugus_backend runner`, the in-prefix step's runner-only re-read | the entry's `runner` field |
| `UMU_RUN`, `NEED_UMU` | the `umu-run` path; `NEED_UMU` is `umu-run` when it is missing or not executable | `~/.local/share/faugus-launcher/umu-run` |
| `UMU_VERSION` | display only | `version.txt` next to `umu-run` |
| `FAUGUS_ENV_PRE` | Faugus's toggles as env, minus the keys `envar.json` sets | `config.json` |
| `BN_LAUNCH_ENV` | the env part of the entry's `launch_arguments`, by Faugus's own rule | the entry's `launch_arguments` |
| `FAUGUS_ENV_POST` | the extra env vars | `envar.json` |

The env arrays are spliced in that order: `FAUGUS_ENV_PRE`, `BN_LAUNCH_ENV`, `FAUGUS_ENV_POST`.

Faugus-only, stays in `lib/faugus.sh`:

- the Faugus doctor rows and the `faugus version` check (`FAUGUS_VERSION`, `W3C_FAUGUS_PY_DIR`)
- Flatpak detection
- the `games.json` runner switch and its backups (`switch_runner`, `revert_write`, `faugus_pick_backup`, `faugus_uses_runner`), which `install`, `update` and `revert` depend on
- `start_battlenet` (`faugus-launcher --game battlenet`)
- `faugus_busy`, the idle check's Faugus processes and `running-games.json`
- `faugus_managed` and `runner_label`

`launch_cmd` and `prefix_cmd` unset `FAUGUSID`, which is harmless for other backends.

Follow-up (not done): the in-prefix step could re-read the whole contract and refuse when the Battle.net prefix was blanked in `games.json` between the checks and the step; today it keeps the prefix the checks read, as it did before 261010-175, because that task changed no behaviour.

## Kept in output

Three output strings keep their planning references, because output must not change in this refactor: the `install` message that
the prefix steps were not offered (names PFX-01), the NAT block's heading line, and the LAN-test-failed line of `lan_hint_scan`
(the last two are compared with `plan.md` by `tests/phase5.sh`).
