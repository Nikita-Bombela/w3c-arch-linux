#!/usr/bin/env bash
# Phase 13 static check of the package recipes, release.yml's wiring, git state and the release docs, on the harness of tests/phase2.sh to
# tests/phase6.sh. It is static only: the package builds and the container smoke tests run in .github/workflows/release.yml on GitHub, and
# nothing here may run a package manager or reach the network.
# Usage: bash tests/phase13.sh [GLOB]   (GLOB filters on display names such as workflow-guard)
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=phase6.sh
source "$(dirname "${BASH_SOURCE[0]}")/phase6.sh"

# this suite has its own cases only
mapfile -t P6_CASES < <(compgen -A function t_)
unset -f "${P6_CASES[@]}"

# nothing here may reach wine, sudo, the firewall or a package manager
FORBIDDEN=(wine wineserver sudo nft iptables pacman rpm dpkg-query dnf apt apt-get)

# ---------- globals ----------

VER=$(sed -n 's/^W3C_LINUX_VERSION=//p' "$ROOT/w3c-linux.sh")
WF=$ROOT/.github/workflows/release.yml
REPO_GUARD="github.repository == 'Nikita-Bombela/w3c-arch-linux'"
# the tools the package runs (depends) and the tools it only uses when present (optdepends), as names the doctor knows; pkg_name maps them
DEP_TOOLS='bash curl python3 sha256sum tar pgrep setsid'
OPT_TOOLS='faugus-launcher nft sudo zenity notify-send desktop-file-utils'
ARCH_OPT_TOOLS='faugus-launcher nft iptables sudo zenity notify-send desktop-file-utils'
REASON=$(bash -c 'source "$1"; printf "%s\n" "${optdepends[@]}"' _ "$ROOT/packaging/PKGBUILD" 2> /dev/null | sed -n 's/^faugus-launcher: //p')
# each job's needs, in the workflow's order; the keys are the jobs after test, which has no needs
declare -A WANT_NEEDS=([tarball]='test' [build-arch]='tarball' [smoke-arch]='tarball, build-arch'
  [build-rpm]='tarball' [smoke-rpm]='tarball, build-rpm'
  [build-deb]='tarball' [smoke-deb]='tarball, build-deb' [publish]='tarball, smoke-arch, smoke-rpm, smoke-deb' [push-copr]='tarball, publish, fetch-release'
  [push-obs]='tarball, publish, fetch-release' [fetch-release]='' [verify-repos]='tarball, fetch-release, push-copr, push-obs')
# the jobs that may read a secret and name the package-repos Environment (T-21-01, T-21-02); t_workflow_forbidden pins both
SECRET_JOBS=(push-copr push-obs)
# the jobs that may use !cancelled() in their if, beside explicit needs results (D-18, T-21-13); t_workflow_forbidden pins it
STATUS_JOBS=(push-copr push-obs verify-repos)
# shellcheck disable=SC2016 # the workflow's own text, $VER included, is searched for
declare -A SMOKE_INSTALL=([smoke-arch]='pacman -U --noconfirm "dist/w3c-linux-$VER-1-any.pkg.tar.zst"'
  [smoke-rpm]='dnf install -y "./dist/w3c-linux-$VER-1.noarch.rpm"' [smoke-deb]='apt-get install -y "./dist/w3c-linux_${VER}-1_all.deb"')
# shellcheck disable=SC2016
PUBLISH_ASSETS=('"w3c-linux-$VER.tar.gz"' '"w3c-linux-$VER-1-any.pkg.tar.zst"' '"w3c-linux-$VER-1.noarch.rpm"' '"w3c-linux_${VER}-1_all.deb"')
NOTES_LINES=('Fedora and Debian/Ubuntu can also install w3c-linux from its Copr and OBS repositories' 'sudo pacman -U ./w3c-linux-%s-1-any.pkg.tar.zst' 'sudo dnf install ./w3c-linux-%s-1.noarch.rpm' 'sudo apt install ./w3c-linux_%s-1_all.deb' 'https://github.com/Nikita-Bombela/w3c-arch-linux#readme')

# ---------- helpers ----------

# pkg_names FAMILY TOOL...: the package each TOOL maps to on FAMILY, space-separated with a trailing space, from lib/common.sh's pkg_name
pkg_names() {
  local fam=$1
  shift
  (
    # shellcheck disable=SC1090 # sourced from a process substitution
    source <(sed -n '/^pkg_name() {$/,/^}$/p' "$ROOT/lib/common.sh")
    export DISTRO_FAMILY=$fam
    for t in "$@"; do
      pkg_name "$t"
      printf '%s ' "$PKG"
    done
  )
}

# pkgbuild_list NAME: the PKGBUILD array NAME, one item per line
pkgbuild_list() { bash -c 'source "$1"; declare -n a=$2; printf "%s\n" "${a[@]}"' _ "$ROOT/packaging/PKGBUILD" "$1"; }

# wf_nc: release.yml without comment lines, so prose cannot satisfy or trip a check
wf_nc() { grep -v '^[[:space:]]*#' "$WF"; }
# wf_jobs: the job names in order (the two-space keys under jobs:, not those under on: or permissions:)
wf_jobs() { wf_nc | awk '/^jobs:$/ {on = 1; next} on && /^  [A-Za-z0-9_-]+:$/ {sub(/^  /, ""); sub(/:$/, ""); print}'; }
# wf_job NAME: the lines of job NAME below its key, up to the next job key
wf_job() { wf_nc | awk -v j="$1" '/^jobs:$/ {on = 1; next} on && /^  [A-Za-z0-9_-]+:$/ {k = $0; sub(/^  /, "", k); sub(/:$/, "", k); cur = (k == j); next} on && cur'; }
# wf_ok: ERRS line and failure when release.yml is missing
wf_ok() { [ -f "$WF" ] || { ERRS+=('.github/workflows/release.yml is missing'); return 1; }; }
# need_in JOB STRING...: an ERRS line for each STRING the job lacks
need_in() {
  local j=$1 s t
  shift
  t=$(wf_job "$j")
  for s in "$@"; do grep -qF -- "$s" <<< "$t" || ERRS+=("$j lacks: $s"); done
}
# ban_in JOB STRING...: an ERRS line for each STRING the job holds
ban_in() {
  local j=$1 s t
  shift
  t=$(wf_job "$j")
  for s in "$@"; do ! grep -qF -- "$s" <<< "$t" || ERRS+=("$j has: $s"); done
}

# ---------- version and PKGBUILD ----------

# the release version, and the PKGBUILD that names it (D-04, D-05)
t_version_sync() {
  [ "$VER" = 1.0.0 ] || ERRS+=("W3C_LINUX_VERSION is $VER, not 1.0.0")
  grep -qx "pkgver=$VER" "$ROOT/packaging/PKGBUILD" || ERRS+=('PKGBUILD pkgver differs from W3C_LINUX_VERSION')
}

# REL-01, D-09: depends are the tools the package runs and faugus-launcher is the first optdepend, with a reason; names come from pkg_name
t_pkgbuild_deps() {
  local got want o names=''
  got=$(pkgbuild_list depends | tr '\n' ' ')
  # shellcheck disable=SC2086 # the tool list is split on purpose
  want=$(pkg_names arch $DEP_TOOLS)
  [ "$got" = "$want" ] || ERRS+=("depends are [$got], want [$want]")
  while IFS= read -r o; do
    names+="${o%%:*} "
    case $o in *': '[!\ ]*) ;; *) ERRS+=("optdepend has no reason: $o") ;; esac
  done < <(pkgbuild_list optdepends)
  # shellcheck disable=SC2086
  want=$(pkg_names arch $ARCH_OPT_TOOLS)
  [ "$names" = "$want" ] || ERRS+=("optdepends are [$names], want [$want]")
  [ -n "$REASON" ] || ERRS+=('faugus-launcher has no optdepends reason')
}

# D-10, D-13, D-06: the source is the release asset, the tarball's top directory is w3c-linux-$pkgver, pkgrel stays 1
# shellcheck disable=SC2016 # PKGBUILD text is searched for
t_pkgbuild_source() {
  local p=$ROOT/packaging/PKGBUILD fn
  grep -qxF 'source=("$url/releases/download/v$pkgver/$pkgname-$pkgver.tar.gz")' "$p" || ERRS+=('PKGBUILD source is not the release asset')
  grep -qx 'pkgrel=1' "$p" || ERRS+=('pkgrel is not 1')
  for fn in check package; do
    sed -n "/^$fn() {\$/,/^}\$/p" "$p" | grep -qF 'w3c-linux-$pkgver' || ERRS+=("$fn() does not name w3c-linux-\$pkgver")
  done
  ! grep -v '^[[:space:]]*#' "$p" | grep -qF 'w3c-arch-linux-$' || ERRS+=('PKGBUILD still names the old top directory w3c-arch-linux-$pkgver')
}

# REL-05: no package or tarball is tracked under packaging/, and the names the build writes are ignored
t_git_clean() {
  local f
  if ! git -C "$ROOT" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    printf '# skip: not a git work tree (a release tarball)\n' >&2
    return 0
  fi
  git -C "$ROOT" ls-files packaging | grep -qE '\.pkg\.tar|\.tar\.gz$|\.rpm$|\.deb$' && ERRS+=('a package or tarball is tracked under packaging/')
  for f in "packaging/w3c-linux-$VER-1-any.pkg.tar.zst" "packaging/w3c-linux-$VER.tar.gz"; do
    git -C "$ROOT" check-ignore -q "$f" || ERRS+=("not git-ignored: $f")
  done
}

# ---------- rpm spec ----------

# REL-02, D-08: a noarch spec through make install; Version is a build input, there is no dist tag, no scriptlet, no changelog
# shellcheck disable=SC2016 # spec text is searched for
t_spec_fields() {
  local f=$ROOT/packaging/w3c-linux.spec s want n
  [ -f "$f" ] || { ERRS+=('packaging/w3c-linux.spec is missing'); return 0; }
  for s in '^Name: +w3c-linux$' '^Version: +%\{w3c_version\}$' '^Release: +1$' '^BuildArch: +noarch$' '^License: +GPL-3.0-or-later$' \
    '^URL: +https://github.com/Nikita-Bombela/w3c-arch-linux$' '^Source0: +%\{name\}-%\{version\}\.tar\.gz$'; do
    grep -qxE -- "$s" "$f" || ERRS+=("spec lacks a line matching: $s")
  done
  [ "$(grep -cxF 'make install DESTDIR=%{buildroot} PREFIX=%{_prefix}' "$f")" = 1 ] || ERRS+=('spec %install is not the one make install line')
  want='%license LICENSE
%{_bindir}/w3c-linux
%{_prefix}/lib/%{name}
%{_datadir}/applications/w3c-linux.desktop
%{_datadir}/icons/hicolor/256x256/apps/w3c-linux.png'
  n=$(grep -cx '%files' "$f")
  [ "$n" = 1 ] || ERRS+=("spec has $n %files lines")
  [ "$(sed -n '/^%files$/,$p' "$f" | sed 1d | grep -v '^[[:space:]]*$')" = "$want" ] || ERRS+=('spec %files, the last section, is not the five entries')
  for s in '%{?dist}' '%{_libdir}' '%global w3c_version' '%define w3c_version'; do
    ! grep -qF -- "$s" "$f" || ERRS+=("spec has: $s")
  done
  ! grep -qE '^%(pre|post|preun|postun|pretrans|posttrans|check|changelog)\b' "$f" || ERRS+=('spec has a scriptlet, %check or %changelog section')
}

# REL-01, D-09, D-15: Requires and Recommends are the family's names in the PKGBUILD's order; faugus-launcher is a Recommends with its reason
t_spec_deps() {
  local f=$ROOT/packaging/w3c-linux.spec got want
  [ -f "$f" ] || { ERRS+=('packaging/w3c-linux.spec is missing'); return 0; }
  got=$(sed -n 's/^Requires: *//p' "$f" | tr '\n' ' ')
  # shellcheck disable=SC2086 # the tool list is split on purpose
  want=$(pkg_names fedora $DEP_TOOLS)
  [ "$got" = "$want" ] || ERRS+=("Requires are [$got], want [$want]")
  got=$(sed -n 's/^Recommends: *//p' "$f" | tr '\n' ' ')
  # shellcheck disable=SC2086
  want=$(pkg_names fedora $OPT_TOOLS)
  [ "$got" = "$want" ] || ERRS+=("Recommends are [$got], want [$want]")
  want=$(pkg_names fedora iptables)
  grep -E '^#' "$f" | grep -qF -- "${want% }" || ERRS+=("no comment names ${want% }")
  [ -n "$REASON" ] || ERRS+=('faugus-launcher has no optdepends reason')
  grep -qF -- "faugus-launcher is recommended, not required: $REASON" "$f" || ERRS+=('spec %description lacks the faugus-launcher reason')
}

# ---------- debian source package ----------

# control_field NAME: the value of the single-line field NAME: in packaging/debian/control (first match)
control_field() { sed -n "s/^$1: //p" "$ROOT/packaging/debian/control" | head -n 1; }

# REL-01, REL-02, D-14: the source and binary stanzas, the noreply maintainer, and the faugus-launcher reason in the long description
t_control_fields() {
  local c=$ROOT/packaging/debian/control f want
  [ -f "$c" ] || { ERRS+=('packaging/debian/control is missing'); return 0; }
  for f in 'Source:w3c-linux' 'Package:w3c-linux' 'Architecture:all' 'Build-Depends:debhelper-compat (= 13)' 'Rules-Requires-Root:no' \
    'Homepage:https://github.com/Nikita-Bombela/w3c-arch-linux' 'Description:run the W3Champions launcher inside the Faugus Battle.net prefix' \
    'Maintainer:Mykyta Bombela <87374729+Nikita-Bombela@users.noreply.github.com>'; do
    [ "$(control_field "${f%%:*}")" = "${f#*:}" ] || ERRS+=("control ${f%%:*} is [$(control_field "${f%%:*}")], want [${f#*:}]")
  done
  [ "$(grep -c '^Maintainer: ' "$c")" = 1 ] || ERRS+=('control does not have exactly one Maintainer line')
  want=' faugus-launcher is recommended, not required: '$REASON
  [ -n "$REASON" ] || ERRS+=('faugus-launcher has no optdepends reason')
  grep -qF -- "$want" "$c" || ERRS+=('control long description lacks the faugus-launcher reason')
}

# REL-01, D-09, D-15: Depends and Recommends are the debian names in the PKGBUILD's order; one NAT alternation; faugus-launcher only in Recommends
# shellcheck disable=SC2016 # ${misc:Depends} is literal control text
t_control_deps() {
  local c=$ROOT/packaging/debian/control got want t rec=()
  [ -f "$c" ] || { ERRS+=('packaging/debian/control is missing'); return 0; }
  # shellcheck disable=SC2086 # the tool list is split on purpose
  want='${misc:Depends}, '$(pkg_names debian $DEP_TOOLS | sed 's/ $//; s/ /, /g')
  got=$(control_field Depends)
  [ "$got" = "$want" ] || ERRS+=("Depends is [$got], want [$want]")
  for t in $OPT_TOOLS; do
    if [ "$t" = nft ]; then rec+=("$(pkg_names debian nft | sed 's/ $//') | $(pkg_names debian iptables | sed 's/ $//')"); else rec+=("$(pkg_names debian "$t" | sed 's/ $//')"); fi
  done
  want=$(IFS=,; printf '%s' "${rec[*]}" | sed 's/,/, /g')
  got=$(control_field Recommends)
  [ "$got" = "$want" ] || ERRS+=("Recommends is [$got], want [$want]")
  ! control_field Depends | grep -qF faugus-launcher || ERRS+=('faugus-launcher is in Depends')
}

# REL-02, D-07: dh with make install and no dh_auto_test; format, copyright, no changelog and no maintainer script
# shellcheck disable=SC2016 # recipe text is searched for
t_rules() {
  local d=$ROOT/packaging/debian r s tab=$'\t'
  r=$d/rules
  [ -f "$r" ] || { ERRS+=('packaging/debian/rules is missing'); return 0; }
  [ "$(head -n 1 "$r")" = '#!/usr/bin/make -f' ] || ERRS+=('rules line 1 is not #!/usr/bin/make -f')
  for s in 'override_dh_auto_install:' 'override_dh_auto_test:' "${tab}dh \$@" "${tab}\$(MAKE) install DESTDIR=\$(CURDIR)/debian/w3c-linux PREFIX=/usr"; do
    grep -qxF -- "$s" "$r" || ERRS+=("rules lacks the line: $s")
  done
  if git -C "$ROOT" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    case $(git -C "$ROOT" ls-files -s packaging/debian/rules) in 100755*) ;; *) ERRS+=('rules is not git mode 100755') ;; esac
  else
    [ -x "$r" ] || ERRS+=('rules is not executable')
  fi
  [ "$(cat "$d/source/format" 2> /dev/null)" = '3.0 (quilt)' ] || ERRS+=('source/format is not 3.0 (quilt)')
  for s in 'Files: *' 'License: GPL-3+'; do
    grep -qxF -- "$s" "$d/copyright" 2> /dev/null || ERRS+=("copyright lacks: $s")
  done
  for s in changelog preinst postinst prerm postrm w3c-linux.preinst w3c-linux.postinst w3c-linux.prerm w3c-linux.postrm; do
    [ ! -e "$d/$s" ] || ERRS+=("packaging/debian/$s exists")
  done
}

# ---------- release.yml ----------

# D-01, D-03: the public-repo-only header, the two triggers and nothing else, read-only by default
t_workflow_head() {
  local s
  wf_ok || return 0
  for s in 'only in the public repo Nikita-Bombela/w3c-arch-linux' 'github.repository'; do
    head -n 1 "$WF" | grep -qF -- "$s" || ERRS+=("line 1 lacks: $s")
  done
  for s in 'name: release' "tags: ['v*']" 'workflow_dispatch:' 'contents: read'; do
    wf_nc | grep -qF -- "$s" || ERRS+=("workflow lacks: $s")
  done
  for s in pull_request 'schedule:'; do
    ! wf_nc | grep -qF -- "$s" || ERRS+=("workflow has: $s")
  done
}

# D-02, D-03, D-06, D-18: every job has one job-level if: publish the tag-push-and-public-repo one, push-copr and push-obs the !cancelled() one with
# explicit needs results, fetch-release the tagged-dispatch one, and every other job the dry-run-or-public-push one, so a republish dispatch skips them
# shellcheck disable=SC2016 # the workflow's ${{ }} text is searched for
t_workflow_guard() {
  local j n got want jobs
  wf_ok || return 0
  jobs=$(wf_jobs)
  for j in test "${!WANT_NEEDS[@]}"; do
    grep -qx -- "$j" <<< "$jobs" || ERRS+=("job missing: $j")
  done
  for j in $jobs; do
    n=$(wf_job "$j" | grep -c '^    if: ')
    [ "$n" = 1 ] || { ERRS+=("$j has $n job-level if lines"); continue; }
    got=$(wf_job "$j" | grep '^    if: ')
    case $j in
      publish) want="    if: github.event_name == 'push' && $REPO_GUARD" ;;
      push-copr | push-obs) want="    if: \${{ !cancelled() && $REPO_GUARD && (needs.publish.result == 'success' || needs.fetch-release.result == 'success') }}" ;;
      fetch-release) want="    if: github.event_name == 'workflow_dispatch' && inputs.tag != '' && $REPO_GUARD" ;;
      verify-repos) want="    if: \${{ !cancelled() && $REPO_GUARD && needs.push-copr.result == 'success' && needs.push-obs.result == 'success' }}" ;;
      *) want="    if: (github.event_name == 'workflow_dispatch' && inputs.tag == '') || (github.event_name == 'push' && $REPO_GUARD)" ;;
    esac
    [ "$got" = "$want" ] || ERRS+=("$j: [$got], want [$want]")
  done
}

# D-12: the needs chain, and the one write scope lives in publish; the token lives in publish and fetch-release (D-18)
# shellcheck disable=SC2016 # the workflow's ${{ }} text is searched for
t_workflow_chain() {
  local j got
  wf_ok || return 0
  for j in "${!WANT_NEEDS[@]}"; do
    got=$(wf_job "$j" | sed -n 's/^    needs: \[\(.*\)\]$/\1/p')
    [ "$got" = "${WANT_NEEDS[$j]}" ] || ERRS+=("$j needs [$got], want [${WANT_NEEDS[$j]}]")
  done
  ! wf_job test | grep -q '^    needs:' || ERRS+=('test has a needs line')
  [ "$(wf_nc | grep -c 'contents: write')" = 1 ] && [ "$(wf_job publish | grep -c 'contents: write')" = 1 ] || ERRS+=('want contents: write once, inside publish')
  [ "$(wf_nc | grep -cF 'GH_TOKEN: ${{ github.token }}')" = 2 ] && [ "$(wf_job publish | grep -cF 'GH_TOKEN: ${{ github.token }}')" = 1 ] \
    && [ "$(wf_job fetch-release | grep -cF 'GH_TOKEN: ${{ github.token }}')" = 1 ] || ERRS+=('want GH_TOKEN twice, once inside publish and once inside fetch-release')
}

# D-05, D-13: the version gate and the git archive tarball
# shellcheck disable=SC2016
t_workflow_tarball() {
  wf_ok || return 0
  need_in tarball 'REF_TYPE: ${{ github.ref_type }}' 'REF_NAME: ${{ github.ref_name }}' 's/^W3C_LINUX_VERSION=//p' 's/^pkgver=//p' \
    '[0-9]+\.[0-9]+\.[0-9]+' '[ "$REF_NAME" = "v$VER" ]' GITHUB_OUTPUT '--prefix="w3c-linux-$VER/"' '-o "w3c-linux-$VER.tar.gz"' \
    'if-no-files-found: error'
}

# D-12: make check, once per matrix leg (tests/phase14.sh checks the legs), as the builder user in the archlinux container
# shellcheck disable=SC2016
t_workflow_test_job() {
  wf_ok || return 0
  need_in test 'image: archlinux:latest' 'options: --init' 'persist-credentials: false' 'grep -vx faugus-launcher' 'runuser -u builder' \
    'SUITES: ${{ matrix.suites }}' 'make check SUITES="$SUITES"'
}

# the Arch package is built from the tarball's own PKGBUILD, as the builder user, and must exist under the D-13 name
# shellcheck disable=SC2016
t_workflow_build_arch() {
  wf_ok || return 0
  need_in build-arch '"w3c-linux-$VER/packaging/PKGBUILD"' 'runuser -u builder' 'makepkg -d --check --skipinteg' \
    'test -f "dist/w3c-linux-$VER-1-any.pkg.tar.zst"' 'name: pkg-arch' 'if-no-files-found: error'
  ban_in build-arch 'actions/checkout'
}

# build-rpm: fedora:latest, the spec read out of the tarball, the w3c_version define, and the exact D-13 file name
# shellcheck disable=SC2016
t_workflow_build_rpm() {
  wf_ok || return 0
  need_in build-rpm 'image: fedora:latest' 'dnf install -y rpm-build make' '"w3c-linux-$VER/packaging/w3c-linux.spec"' 'rpmbuild -bb' \
    '--define "w3c_version $VER"' '"rpm/RPMS/noarch/w3c-linux-$VER-1.noarch.rpm"' 'name: pkg-rpm' 'if-no-files-found: error'
  ban_in build-rpm 'actions/checkout'
  need_in smoke-rpm 'image: fedora:latest'
}

# build-deb: debian:stable, debian/ copied out of the tarball, the changelog trailer read from control, and the exact D-13 file name
# shellcheck disable=SC2016
t_workflow_build_deb() {
  wf_ok || return 0
  need_in build-deb 'image: debian:stable' 'DEBIAN_FRONTEND: noninteractive' debhelper 'cp -r packaging/debian debian' \
    "sed -n 's/^Maintainer: //p' debian/control" 'unstable; urgency=medium' 'date -R' 'dpkg-buildpackage -b -us -uc' '"../w3c-linux_${VER}-1_all.deb"' \
    'name: pkg-deb' 'if-no-files-found: error'
  ban_in build-deb 'actions/checkout'
}

# REL-04: install in a fresh container with the installer's defaults, then version and doctor must say exactly what a Faugus-less host shows
# shellcheck disable=SC2016
t_workflow_smoke() {
  local j
  wf_ok || return 0
  for j in "${!SMOKE_INSTALL[@]}"; do
    need_in "$j" "${SMOKE_INSTALL[$j]}" 'w3c-linux version' '"w3c-linux $VER"' 'w3c-linux doctor' '|| rc=$?' '[ "$rc" = 1 ]' '^fail  games.json' \
      'pass  version' 'pass  desktop entry'
    ban_in "$j" 'actions/checkout' '--no-install-recommends'
  done
  # D-15: the rpm and deb smoke jobs take smoke-umu.sh out of the tarball artifact
  for j in smoke-rpm smoke-deb; do need_in "$j" 'name: tarball' 'packaging/smoke-umu.sh'; done
  # smoke-deb: both images as one matrix that does not stop at the first failure, with a refreshed index and no prompts (Pitfall 3)
  need_in smoke-deb 'debian:stable' 'ubuntu:latest' 'fail-fast: false' 'apt-get update' 'DEBIAN_FRONTEND: noninteractive'
  # without the sync a fresh image cannot resolve python (Pitfall 2)
  wf_job smoke-arch | awk -v ins="${SMOKE_INSTALL[smoke-arch]}" 'index($0, "pacman -Syu --noconfirm") && !s {s = NR} index($0, ins) && !i {i = NR} END {exit !(s && i && s < i)}' \
    || ERRS+=('smoke-arch: pacman -Syu --noconfirm does not come before the install')
}

# REL-03, D-11: SHA256SUMS over the named assets, tarball first, then a tag-verified release with the fixed notes
# shellcheck disable=SC2016
t_workflow_publish() {
  local s l a b i
  wf_ok || return 0
  need_in publish 'merge-multiple: true' '> SHA256SUMS' 'gh release create "$TAG"' '--verify-tag' '--notes-file' 'TAG: ${{ github.ref_name }}' \
    "${PUBLISH_ASSETS[@]}" "${NOTES_LINES[@]}"
  l=$(wf_job publish | grep -F -- '> SHA256SUMS')
  # each asset is listed after the one before it: tarball, .pkg.tar.zst, .noarch.rpm, _all.deb
  for ((i = 1; i < ${#PUBLISH_ASSETS[@]}; i++)); do
    a=${l%%"${PUBLISH_ASSETS[i - 1]}"*}
    b=${l%%"${PUBLISH_ASSETS[i]}"*}
    [ "${#a}" -lt "${#b}" ] || ERRS+=("SHA256SUMS lists ${PUBLISH_ASSETS[i]} before ${PUBLISH_ASSETS[i - 1]}")
  done
  # D-14: the repository pointer line comes before the per-asset lines
  l=$(wf_job publish | grep -nF -- "${NOTES_LINES[0]}" | head -n 1 | cut -d: -f1)
  a=$(wf_job publish | grep -nF -- '- Arch:' | head -n 1 | cut -d: -f1)
  [ -n "$l" ] && [ -n "$a" ] && [ "$l" -lt "$a" ] || ERRS+=('publish notes: the repository pointer line does not come before the - Arch: line')
  ! wf_job publish | grep -F -- "${NOTES_LINES[0]}" | grep -qE 'dnf (copr|install)|apt (install|update)' || ERRS+=('the repository pointer line holds a command')
  for s in "${PUBLISH_ASSETS[@]}"; do
    [ "$(wf_job publish | grep -cF -- "$s")" -ge 2 ] || ERRS+=("publish names $s fewer than twice (SHA256SUMS and gh release create)")
  done
}

# T-13-01 to T-13-08: no status functions, third-party actions, asset replacement, or ${{ }} in a shell body; the one deliberate exception is D-18:
# !cancelled() once in each STATUS_JOBS job and nowhere else (T-21-13); T-21-01, T-21-02: a secret is read
# only by a step's env inside a SECRET_JOBS job (push-obs reads two), and only those jobs name the package-repos Environment
# shellcheck disable=SC2016
t_workflow_forbidden() {
  local s u v j l m c n=0 re='^ {10}[A-Z_]+: \$\{\{ secrets\.[A-Z_]+ \}\}$'
  wf_ok || return 0
  for s in continue-on-error 'always()' softprops '--clobber' 'gh release upload' 'gh release delete' 'w3c-arch-linux-$'; do
    ! wf_nc | grep -qF -- "$s" || ERRS+=("workflow has forbidden: $s")
  done
  # D-18: every cancelled() is !cancelled(), inside a STATUS_JOBS job, once per job
  ! wf_nc | grep -F 'cancelled()' | grep -qvF '!cancelled()' || ERRS+=('workflow has a cancelled() that is not !cancelled()')
  [ "$(wf_nc | grep -cF 'cancelled()')" = "${#STATUS_JOBS[@]}" ] || ERRS+=("want !cancelled() ${#STATUS_JOBS[@]} times, once in each of ${STATUS_JOBS[*]}")
  for j in $(wf_jobs); do
    c=$(wf_job "$j" | grep -cF 'cancelled()' || true)
    case " ${STATUS_JOBS[*]} " in
      *" $j "*) [ "$c" = 1 ] || ERRS+=("$j has $c cancelled() lines, want 1") ;;
      *) [ "$c" = 0 ] || ERRS+=("$j uses cancelled(), which only ${STATUS_JOBS[*]} may") ;;
    esac
  done
  while IFS= read -r u; do
    case $u in actions/checkout@v7 | actions/upload-artifact@v7 | actions/download-artifact@v8) ;; *) ERRS+=("uses a non-approved action: $u") ;; esac
  done < <(wf_nc | sed -n 's/^ *\(- \)\{0,1\}uses: *//p')
  for j in "${SECRET_JOBS[@]}"; do
    m=0
    while IFS= read -r l; do
      [[ $l =~ $re ]] || ERRS+=("$j: a secrets. line that is not a step env: $l")
      m=$((m + 1))
    done < <(wf_job "$j" | grep -F 'secrets.')
    [ "$m" -ge 1 ] || ERRS+=("$j reads no secret")
    n=$((n + m))
  done
  [ "$(wf_nc | grep -cF 'secrets.')" = "$n" ] || ERRS+=("want every secrets. line ($n) inside SECRET_JOBS (${SECRET_JOBS[*]})")
  for j in $(wf_jobs); do
    l=$(wf_job "$j" | grep -E '^ *environment:' || true)
    case " ${SECRET_JOBS[*]} " in
      *" $j "*) [ "$l" = '    environment: package-repos' ] || ERRS+=("$j: environment line is [$l], want environment: package-repos") ;;
      *) [ -z "$l" ] || ERRS+=("$j names an environment: $l") ;;
    esac
  done
  # a run: line, or a run: | block, that holds ${{ : the expression reaches the shell only through env:
  v=$(wf_nc | awk '
    { match($0, /^ */); ind = RLENGTH }
    inblk && $0 !~ /^[[:space:]]*$/ && ind <= blk { inblk = 0 }
    inblk && index($0, "${{") { print "in a run block: " $0 }
    /^ *(- )?run: *[|>]/ { inblk = 1; blk = ($0 ~ /^ *- run:/) ? ind + 2 : ind; next }
    /^ *(- )?run:/ && index($0, "${{") { print "on a run line: " $0 }')
  [ -z "$v" ] || ERRS+=("expression in a shell body: $v")
}

# ---------- README and CONTRIBUTING ----------

# readme_section HEADING: the README text from the line HEADING to the next `## ` heading.
readme_section() { awk -v h="$1" '$0 == h { on = 1; next } on && /^## / { exit } on' "$ROOT/README.md"; }
# readme_sub HEADING: the README text from the `### ` line HEADING to the next `### ` or `## ` heading.
readme_sub() { awk -v h="$1" '$0 == h { on = 1; next } on && /^##/ { exit } on' "$ROOT/README.md"; }

# REL-05, T-13-17: the README points at the release page and each family's asset by a glob that matches the name release.yml publishes
t_readme_assets() {
  local sec s fam cmd name glob
  sec=$(readme_section '## Installation')
  for s in 'https://github.com/Nikita-Bombela/w3c-arch-linux/releases/latest' 'sha256sum -c --ignore-missing SHA256SUMS'; do
    grep -qF -- "$s" <<< "$sec" || ERRS+=("Installation lacks: $s")
  done
  readme_sub '### Arch' | grep -qiF 'without the AUR' || ERRS+=('### Arch does not say that users without the AUR use the .pkg.tar.zst')
  # family|install command|the file name release.yml publishes (D-13); the command's glob has to match the name
  for fam in "Arch|sudo pacman -U ./w3c-linux-*-any.pkg.tar.zst|w3c-linux-$VER-1-any.pkg.tar.zst" \
    "Fedora|sudo dnf install ./w3c-linux-*.noarch.rpm|w3c-linux-$VER-1.noarch.rpm" \
    "Debian/Ubuntu|sudo apt install ./w3c-linux_*_all.deb|w3c-linux_${VER}-1_all.deb"; do
    IFS='|' read -r s cmd name <<< "$fam"
    readme_sub "### $s" | grep -qF -- "$cmd" || ERRS+=("### $s lacks: $cmd")
    glob=${cmd##* ./}
    # shellcheck disable=SC2053 # the unquoted glob is the point
    [[ $name == $glob ]] || ERRS+=("### $s: $glob does not match $name")
  done
  ! grep -qF '/releases/download/' "$ROOT/README.md" || ERRS+=('README.md holds a versioned /releases/download/ URL')
}

# D-04: the README's version row names the version the script prints
t_readme_version() {
  grep -qF -- "Prints \`w3c-linux $VER\`." "$ROOT/README.md" || ERRS+=("README.md lacks: Prints \`w3c-linux $VER\`.")
}

# D-01, D-12: CONTRIBUTING lists the new files, calls release.yml the one public workflow, describes CI as make check and holds the recipe
# shellcheck disable=SC2016 # the backticks are literal Markdown
t_contributing_release() {
  local c=$ROOT/CONTRIBUTING.md s sec
  for s in '| `.github/workflows/release.yml` |' '| `packaging/w3c-linux.spec` |' '| `packaging/debian/` |'; do
    grep -qF -- "$s" "$c" || ERRS+=("CONTRIBUTING.md Layout lacks a row: $s")
  done
  for s in 'The public repo carries one workflow, release.yml' 'make check SUITES=' 'Phase 13'; do
    grep -qF -- "$s" "$c" || ERRS+=("CONTRIBUTING.md lacks: $s")
  done
  [ "$(grep -c '^## Releases$' "$c")" = 1 ] || ERRS+=('CONTRIBUTING.md does not have exactly one ## Releases')
  sec=$(awk '$0 == "## Releases" { on = 1; next } on && /^## / { exit } on' "$c")
  for s in github.repository workflow_dispatch SHA256SUMS sha256sums W3C_LINUX_VERSION pkgver 'patch tag'; do
    grep -qF -- "$s" <<< "$sec" || ERRS+=("Releases lacks: $s")
  done
  ! grep -qF 'has no workflow' "$c" "$ROOT/README.md" || ERRS+=('a doc still says a repo has no workflow')
}

# ---------- runner ----------

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
