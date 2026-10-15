# Contributing

Installing and using w3c-linux is in [README.md](README.md).

## Layout

| Path | What |
|---|---|
| `w3c-linux.sh` | the entry: finds `lib/`, loads it, runs the subcommand |
| `lib/common.sh` | colours, output helpers, paths, prompts, state records, the run lock, the distro family and `install_hint` |
| `lib/umu.sh` | the umu backend: `backend_resolve`, `umu_backend`, the backend file and `backend` subcommand, the umu cold start |
| `lib/faugus.sh` | everything that knows Faugus: `faugus_backend`, the only reader of Faugus's files and the contract it sets; the Faugus doctor rows and version check; the runner switch and backups; the Battle.net start; the idle check's Faugus processes |
| `lib/checks.sh` | the prefix, Warcraft III, host and Proton rows and `run_checks`, shared by `doctor`, `install`, `update`, `launch` and `report` |
| `lib/proton.sh` | patched Proton download, idle wait, removal of a replaced build |
| `lib/prefix.sh` | launcher version lookup and the in-prefix steps (WebView2, registry, launcher MSI) |
| `lib/nat.sh` | NAT rule text, apply and offer |
| `lib/doctor.sh`, `lib/install.sh`, `lib/revert.sh`, `lib/update.sh`, `lib/launch.sh`, `lib/monitor.sh`, `lib/report.sh` | one subcommand each |
| `Makefile` | `install`, `install-user`, `uninstall`, `uninstall-user` and `check`; the PKGBUILD's `package()` calls `make install` |
| `lib/w3c-askpass.sh` | the password dialog `sudo -A` runs for the NAT rule when there is no terminal |
| `share/` | the shipped `.desktop` entry and icon that make and a clone's `install` place |
| `lib/w3c_helper.py` | the Python JSON parsers, run as `python3 -I -B` |
| `packaging/PKGBUILD` | the Arch package recipe: `source` is the release tarball, `package()` runs `make install` into `/usr` |
| `packaging/w3c-linux.spec` | the rpm recipe: `%install` runs `make install`, and release.yml sets the version |
| `packaging/debian/` | the debhelper source package (`control`, `rules`, `copyright`, `source/format`): `rules` runs `make install`, and release.yml writes `changelog` |
| `LICENSE` | GPL-3.0 text |
| `tests/phaseN.sh` | the fixture suites, one per phase |
| `tests/live.sh` | the live upstream check the nightly runs; `--offline` serves generated fixtures |
| `tests/fixtures/upstream-state.txt` | the known upstream-watch state the nightly compares against |
| `.github/workflows/ci.yml` | `make check` per suite half on pull requests into main; dev repo only |
| `.github/workflows/nightly.yml` | the nightly job; dev repo only, not in the public repo |
| `.github/workflows/release.yml` | the release build on a `v*` tag; the public repo carries one workflow, this one (see [Releases](#releases)) |
| `docs/ARCHITECTURE.md` | Mermaid flow charts of every subcommand |

## Tests

```bash
make check
```

`bash tests/phaseN.sh [GLOB]` runs one suite. Packagers on other distros leave phase 7 out with `make check SUITES='tests/phase[!7]*.sh'`.

Phase 7 builds the real package, so it needs `makepkg`, `fakeroot`, `bsdtar` and `git`, and must run as a non-root user.

Phase 10 covers the umu backend: the `umu-run` chain, `backend set/show/clear`, the override env, doctor, install, update, revert and launch in that mode, and that Faugus users see the v0.1.1 rows.

Phase 11 covers the Makefile (the staged tree against the v0.1.1 package, `install-user` and both uninstall targets under a fake HOME, `make check`), doctor's install location rows and the installed menu entry.

Phase 12 covers the distro family (fake `os-release` files under `W3C_SYS_ROOT` and a fake `PATH`), the install hints per family, the Faugus version query per family, and the README's install lines.

Phase 13 is static: it checks the PKGBUILD, spec and `debian/` dependency lists against the `pkg_name` table, release.yml's jobs, guards and asset names, that no package or tarball is tracked under `packaging/`, and the README's release-asset lines. The package builds and container smoke tests run only in release.yml.

Phase 8 runs `tests/live.sh --offline` against generated fixtures and needs no network; the live check is
under [Nightly check](#nightly-check).

In the dev repo these run on GitHub too, see [CI tests](#ci-tests).

The fixture suites cover the script's pure logic. umu, Wine and Battle.net are never mocked; those parts are verified by hand on a
real machine.

## CI tests

`.github/workflows/ci.yml` runs on every pull request into main and on manual dispatch, only in the private dev repo
Nikita-Bombela/w3c-arch-linux-dev. In a fresh `archlinux:latest` container it installs the packages of the `On Arch:` line in [README.md](README.md#arch) and the PKGBUILD
optdepends, then runs `make check SUITES=…` (shellcheck plus the suites above) as an unprivileged user. They run as two checks: `faugus` (`tests/phase1` to `9`, the v0.1.x Faugus suites) and `v0.2 (BFaA)` (`tests/phase10` and later), each with its own `make check` and package install. The package install leaves out the AUR-only faugus-launcher. Check both on the pull request. It never touches the network checks.
The container runs with `--init`: without a PID 1 that reaps orphans, the monitor tail that phase 5 and 6 kill stays a zombie and their
`kill -0` checks report it as still running. A run takes about 9 minutes, almost all of it the suites.

There is no push trigger: work reaches main through pull requests, so the PR run is the check. GitHub Free cannot require a status check
on a private repo (branch protection needs Pro), so nothing blocks a red merge: check the PR's `faugus` and `v0.2 (BFaA)` results before merging.

## Nightly check

`.github/workflows/nightly.yml` runs every night at 03:23 UTC and on manual dispatch, only in the private dev repo
Nikita-Bombela/w3c-arch-linux-dev. The public repo carries one workflow, release.yml (see [Releases](#releases)); the nightly never runs or goes red there.

One run, in step order:

1. a fresh `archlinux:latest` container with `pacman -Syu` (no cache: every night starts fresh); the fixture suites are not part of the
   nightly, they run in [CI tests](#ci-tests);
2. the packages of the `On Arch:` line in [README.md](README.md#arch) plus the PKGBUILD optdepends; a renamed or dropped package fails (keep that line's shape,
   the job reads it);
3. faugus-launcher from the AUR, built with makepkg as an unprivileged user;
4. the w3c-linux package, built from a `git archive` of the checkout and installed with `makepkg -si --skipinteg` (the recipe in the comment at the top of `packaging/PKGBUILD`);
5. `doctor` on the fixture home with the installed Faugus (a Faugus major change shows here);
6. `tests/live.sh`, which runs the real lib code against upstream: the patched Proton release (release JSON, download, `sha256sum -c`,
   extract, build check), the launcher (`latest.json`, and the MSI from the update API and from `latest.json`, each checked by file
   magic), the WebView2 bootstrapper (PE magic) and the upstream watch. The MSI coverage is the file check only; nothing is installed
   into a prefix.

**Breakage and news.** Every step reports on its own after an earlier failure. The last step, `live: upstream watch (fails on news too)`,
fails when upstream changed (issue #57 state, Wine's `get_job_info`, GE-Proton's latest tag against the W3C build's base) as well as when a
check could not run. A change is a to-do signal: act on it (for example a fork rebase, or trying stock Proton), then paste the new lines
from the step log into `tests/fixtures/upstream-state.txt`, set the offline values at the top of `tests/live.sh` to match, run
`bash tests/phase8.sh` and push.

**How a failure arrives.** GitHub's own failure email, no extra service. For the schedule it goes to the user who created the workflow
(later, whoever edits the cron line or re-enables the workflow); a manual run notifies whoever started it. Turn on email for Actions in
GitHub's notification settings (failed runs only is enough). The email and the run page name the failed step, and each failed live check
adds an error annotation naming it.

**Budget.** A run takes about 2 minutes, so about 60 of the 2,000 Actions minutes a month that GitHub Free gives a private repo; each
CI run adds about 9. GitHub's automatic disabling of scheduled workflows after 60 days without repo activity applies to public repos only, so it does not affect the dev
repo; it would if the workflow were ever copied to a public one.

By hand:

```bash
bash tests/live.sh                  # everything: about 1.4 GB of downloads, about 4 GB free under /var/tmp (or set TMPDIR)
bash tests/live.sh launcher watch   # light
bash tests/live.sh --offline        # no network
```

Without `GITHUB_TOKEN` the GitHub API calls go out unauthenticated (60 an hour per IP); with it in the environment they carry the token, to
api.github.com only. `W3C_LIVE_RELEASE_API` points the release check at another URL, which is how a deliberate red run is made.

## Releases

`.github/workflows/release.yml` starts on a `v*` tag push. It publishes only from the public repo Nikita-Bombela/w3c-arch-linux: every job checks
`github.repository`, so a tag pushed to the dev repo gives a skipped run.

The jobs, in order:

1. `test` runs `make check` for both halves;
2. `tarball` is the version gate: the tag must be `v` plus `W3C_LINUX_VERSION`, which must equal `pkgver`, and the job builds the `git archive` `w3c-linux-X.Y.Z.tar.gz`;
3. `build-arch`, `build-rpm` and `build-deb` each build from that tarball;
4. `smoke-arch`, `smoke-rpm` and `smoke-deb` install each package in a fresh `archlinux`, `fedora`, `debian:stable` or `ubuntu:latest` container and run
   `w3c-linux version` and `w3c-linux doctor` (which must exit 1, for the missing Faugus);
5. `publish` writes `SHA256SUMS` and runs `gh release create` with the fixed install lines: the tarball, `.pkg.tar.zst`, `.noarch.rpm`, `.deb` and `SHA256SUMS`.

A `workflow_dispatch` run (Actions, release, Run workflow, or `gh workflow run release.yml`) is a dry run in either repo. It tests, builds and
smoke-tests, uploads the packages as run artifacts, and never publishes.

To release:

1. bump `W3C_LINUX_VERSION` in `w3c-linux.sh` and `pkgver` in `packaging/PKGBUILD` to the same X.Y.Z;
2. run the dry run in the dev repo until it is green;
3. put the release commit on the public repo with the public files, `.github/workflows/release.yml` included;
4. create the annotated tag `vX.Y.Z` and push it. Pushing a workflow file needs a token with the `workflow` scope;
5. when the release is published, copy the `w3c-linux-X.Y.Z.tar.gz` line's hash from its `SHA256SUMS` into the PKGBUILD's `sha256sums`, and commit
   "packaging: sha256sums for vX.Y.Z" to both repos.

Assets on a published release are never replaced. A packaging-only fix gets a new patch tag, and `pkgrel`, the rpm `Release` and the deb revision stay `1`.
