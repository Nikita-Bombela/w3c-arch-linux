#!/usr/bin/env bash
# Phase 21 static and fixture check of the package-repository scripts under packaging/ and release.yml's push wiring, on the harness and helpers of
# tests/phase13.sh. The scripts run against a fake rpmbuild; nothing here may run a package manager or reach the network. The real SRPM rebuild
# and the Copr hop are proven by the podman step in the plan and by the supervised run.
# Usage: bash tests/phase21.sh [GLOB]   (GLOB filters on display names such as srpm-pin)
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=phase13.sh
source "$(dirname "${BASH_SOURCE[0]}")/phase13.sh"

# this suite has its own cases only
mapfile -t P13_CASES < <(compgen -A function t_)
unset -f "${P13_CASES[@]}"

# ---------- helpers ----------

# fake_rpmbuild: a rpmbuild that records its arguments, keeps a copy of the spec it was given and creates <_topdir>/SRPMS/w3c-linux-<Version>-1.src.rpm
fake_rpmbuild() {
  mkdir -p "$T/fakebin"
  cat > "$T/fakebin/rpmbuild" << 'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$T/rpmbuild.args"
top='' spec=''
while [ $# -gt 0 ]; do
  case $1 in
    --define) case $2 in '_topdir '*) top=${2#_topdir } ;; esac; shift ;;
    -bs) ;;
    *) spec=$1 ;;
  esac
  shift
done
cp "$spec" "$T/captured.spec"
ver=$(sed -n 's/^Version: *//p' "$spec")
mkdir -p "$top/SRPMS"
: > "$top/SRPMS/w3c-linux-$ver-1.src.rpm"
SH
  chmod +x "$T/fakebin/rpmbuild"
}

# fx_tarball SPEC TARBALL: a tarball holding only w3c-linux-$VER/packaging/w3c-linux.spec, a copy of SPEC
fx_tarball() {
  mkdir -p "$T/fx/w3c-linux-$VER/packaging"
  cp "$1" "$T/fx/w3c-linux-$VER/packaging/w3c-linux.spec"
  tar -czf "$2" -C "$T/fx" "w3c-linux-$VER"
}

# run_mk ARGS...: mk-srpm.sh with the fake rpmbuild first on PATH; OUT holds both streams, RC the status
run_mk() {
  RC=0
  OUT=$(env T="$T" PATH="$T/fakebin:$PATH" bash "$ROOT/packaging/mk-srpm.sh" "$@" 2>&1) || RC=$?
}

# nc FILE: FILE without comment lines, so prose can neither satisfy nor trip a check
nc() { grep -v '^[[:space:]]*#' "$1"; }

# ---------- SRPM pin ----------

# REPO-01, D-07, D-10: the SRPM is built from a pinned copy of the released spec; exactly the Version line differs and no w3c_version define is passed
t_srpm_pin() {
  local ch
  fake_rpmbuild
  fx_tarball "$ROOT/packaging/w3c-linux.spec" "$T/w3c-linux-$VER.tar.gz"
  run_mk "$VER" "$T/w3c-linux-$VER.tar.gz" "$T/out"
  [ "$RC" = 0 ] || ERRS+=("mk-srpm.sh exited $RC: $OUT")
  [ -f "$T/out/w3c-linux-$VER-1.src.rpm" ] || ERRS+=("no out/w3c-linux-$VER-1.src.rpm")
  grep -qF -- '-bs' "$T/rpmbuild.args" 2> /dev/null || ERRS+=('rpmbuild was not run with -bs')
  ! grep -qF 'w3c_version' "$T/rpmbuild.args" 2> /dev/null || ERRS+=('rpmbuild got a w3c_version define')
  ch=$(diff "$ROOT/packaging/w3c-linux.spec" "$T/captured.spec" | grep '^[<>]' || true)
  [ "$(grep -c '^<' <<< "$ch")" = 1 ] && [ "$(grep -c '^>' <<< "$ch")" = 1 ] || ERRS+=("want one changed line, got: $ch")
  grep -qxF "> Version:        $VER" <<< "$ch" || ERRS+=("the changed line is not 'Version:        $VER': $ch")
}

# T-21-03: mk-srpm.sh refuses a spec with two Version lines, one with none, a leftover %{w3c_version} and a VER that is not N.N.N, and writes no SRPM
t_srpm_guard() {
  local spec=$T/spec case_name
  fake_rpmbuild
  { cat "$ROOT/packaging/w3c-linux.spec"; printf 'Version: 9.9.9\n'; } > "$spec"
  fx_tarball "$spec" "$T/two.tar.gz"
  grep -v '^Version:' "$ROOT/packaging/w3c-linux.spec" > "$spec"
  fx_tarball "$spec" "$T/none.tar.gz"
  { cat "$ROOT/packaging/w3c-linux.spec"; printf 'Release: %%{w3c_version}\n'; } > "$spec"
  fx_tarball "$spec" "$T/define.tar.gz"
  fx_tarball "$ROOT/packaging/w3c-linux.spec" "$T/good.tar.gz"
  for case_name in two none define badver; do
    case $case_name in
      badver) run_mk 1.2 "$T/good.tar.gz" "$T/out-$case_name" ;;
      *) run_mk "$VER" "$T/$case_name.tar.gz" "$T/out-$case_name" ;;
    esac
    [ "$RC" != 0 ] || ERRS+=("$case_name: mk-srpm.sh exited 0")
    grep -qF '::error::' <<< "$OUT" || ERRS+=("$case_name: no ::error:: line: $OUT")
    [ -z "$(find "$T/out-$case_name" -type f 2> /dev/null)" ] || ERRS+=("$case_name: an SRPM was written")
  done
  [ ! -e "$T/rpmbuild.args" ] || ERRS+=('rpmbuild ran for a refused input')
}

# T-21-04: the dry run builds and uploads the SRPM from the tarball; only the push job reads the Copr secret, and nothing but a later verify job may need it
# shellcheck disable=SC2016 # the workflow's ${{ }} text is searched for
t_srpm_workflow() {
  local j got
  wf_ok || return 0
  need_in build-rpm 'packaging/mk-srpm.sh' 'name: srpm' 'srpm/w3c-linux-*.src.rpm'
  need_in push-copr 'environment: package-repos' 'image: fedora:latest' 'dnf install -y copr-cli' 'persist-credentials: false' \
    'packaging/push-copr.sh' 'COPR_CONFIG: ${{ secrets.COPR_CONFIG }}'
  for j in $(wf_jobs); do
    [ "$j" = verify-repos ] && continue
    got=$(wf_job "$j" | sed -n 's/^    needs: \[\(.*\)\]$/\1/p')
    case ", $got," in *', push-copr,'*) ERRS+=("$j needs push-copr") ;; esac
  done
}

# ---------- Copr push ----------

# T-21-01, T-21-05, T-21-SC: push-copr.sh holds the config in a private file, reads the project and never creates it, never waits less, never traces
t_copr_push() {
  local f=$ROOT/packaging/push-copr.sh s code
  [ -f "$f" ] || { ERRS+=('packaging/push-copr.sh is missing'); return 0; }
  for s in 'umask 077' whoami ' get ' 'copr-cli --config' '::error::' 'mk-srpm.sh'; do
    grep -qF -- "$s" "$f" || ERRS+=("push-copr.sh lacks: $s")
  done
  code=$(nc "$f")
  for s in '--nowait' '--no-wait' 'set +-[a-zA-Z]*x' xtrace 'copr-cli.* (create|delete)( |$)' 'pip install' pipx; do
    ! grep -qE -- "$s" <<< "$code" || ERRS+=("push-copr.sh has: $s")
  done
  ! nc "$WF" | grep -qE 'copr-cli.* (create|delete)( |$)' || ERRS+=('release.yml creates or deletes a Copr project')
}

# D-04: copr_expiry warns once when the token has fewer than 30 days left or its date is unreadable, prints nothing otherwise, and always returns 0
t_copr_expiry() {
  local now=1780000000 d out cfg
  # shellcheck disable=SC1090 # sourced from a process substitution
  source <(sed -n '/^copr_expiry() {$/,/^}$/p' "$ROOT/packaging/push-copr.sh")
  declare -F copr_expiry > /dev/null || { ERRS+=('push-copr.sh defines no copr_expiry'); return 0; }
  for d in 10 29 30 100; do
    cfg=$T/cfg$d
    printf 'login = x\n# expiration date: %s\n' "$(date -u -d "@$((now + d * 86400))" +%F)" > "$cfg"
    out=$(copr_expiry "$cfg" "$now") || ERRS+=("$d days: copr_expiry returned non-zero")
    if [ "$d" -lt 30 ]; then
      [ "$(grep -c '' <<< "$out")" = 1 ] && [[ $out == '::warning::'*"$d days"* ]] || ERRS+=("$d days ahead: want one ::warning:: naming $d days, got [$out]")
    else
      [ -z "$out" ] || ERRS+=("$d days ahead: want no output, got [$out]")
    fi
  done
  printf 'login = x\n' > "$T/cfg-none"
  printf 'login = x\n# expiration date: not a date\n' > "$T/cfg-bad"
  for cfg in "$T/cfg-none" "$T/cfg-bad"; do
    out=$(copr_expiry "$cfg" "$now") || ERRS+=("${cfg##*/}: copr_expiry returned non-zero")
    [ "$(grep -c '' <<< "$out")" = 1 ] && [[ $out == '::warning::cannot read'* ]] || ERRS+=("${cfg##*/}: want one ::warning::cannot read line, got [$out]")
  done
}

# ---------- Debian source package ----------

# REPO-02, D-07: mk-dsc.sh builds the 3.0 (quilt) trio from the tarball, checks and round-trips the .dsc, and writes the changelog as build-deb does
# shellcheck disable=SC2016 # the script's own text is searched for
t_dsc_script() {
  local f=$ROOT/packaging/mk-dsc.sh s a b
  [ -f "$f" ] || { ERRS+=('packaging/mk-dsc.sh is missing'); return 0; }
  for s in 'w3c-linux_$ver.orig.tar.gz' 'packaging/debian' 'dpkg-source -b' 'dpkg-source -x' 'Format: 3.0 (quilt)' 'Version: $ver-1' '::error::'; do
    grep -qF -- "$s" "$f" || ERRS+=("mk-dsc.sh lacks: $s")
  done
  # the changelog format string, character for character, in the script and in build-deb
  a=$(nc "$f" | grep -o "printf 'w3c-linux (%s-1)[^']*'" || true)
  b=$(wf_job build-deb | grep -o "printf 'w3c-linux (%s-1)[^']*'" || true)
  [ -n "$a" ] && [ "$a" = "$b" ] || ERRS+=("changelog printf differs: mk-dsc.sh [$a], build-deb [$b]")
}

# D-10: the dry run builds the trio from the tarball with the script that is in it, and uploads it as the artifact dsc; no checkout
t_dsc_workflow() {
  wf_ok || return 0
  need_in build-deb 'packaging/mk-dsc.sh' 'name: dsc' '.debian.tar.xz' '.dsc'
  ban_in build-deb 'actions/checkout'
}

# ---------- OBS push ----------

# D-08, T-21-10: obs_all_succeeded returns 0 only for the four succeeded targets (any order); excluded, failed, unresolvable, missing, extra and empty all return 1
t_obs_results() {
  local good bad r
  # shellcheck disable=SC1090 # sourced from a process substitution
  source <(sed -n '/^obs_all_succeeded() {$/,/^}$/p' "$ROOT/packaging/push-obs.sh" 2> /dev/null)
  declare -F obs_all_succeeded > /dev/null || { ERRS+=('push-obs.sh defines no obs_all_succeeded'); return 0; }
  good=$'xUbuntu_26.04 x86_64 succeeded\nDebian_12 x86_64 succeeded\nxUbuntu_24.04 x86_64 succeeded\nDebian_13 x86_64 succeeded'
  obs_all_succeeded <<< "$good" || ERRS+=('the four succeeded lines in shuffled order returned non-zero')
  for r in excluded failed unresolvable; do
    bad=${good/xUbuntu_24.04 x86_64 succeeded/xUbuntu_24.04 x86_64 $r}
    ! obs_all_succeeded <<< "$bad" || ERRS+=("a $r target returned 0")
  done
  ! obs_all_succeeded <<< "$(sed 1d <<< "$good")" || ERRS+=('three of four targets returned 0')
  ! obs_all_succeeded <<< "$good"$'\nopenSUSE_Tumbleweed x86_64 succeeded' || ERRS+=('an extra repository returned 0')
  ! obs_all_succeeded <<< '' || ERRS+=('empty input returned 0')
}

# T-21-08, T-21-09, D-01, T-21-SC: push-obs.sh keeps the credentials in a private temporary HOME, replaces the files, waits for the results, never writes project or package meta and never traces;
# the job runs after publish with the secrets in the push step's env only, and nothing but a later verify job needs it
# shellcheck disable=SC2016 # the workflow's ${{ }} text is searched for
t_obs_push() {
  local f=$ROOT/packaging/push-obs.sh s code j got
  [ -f "$f" ] || { ERRS+=('packaging/push-obs.sh is missing'); return 0; }
  for s in 'umask 077' oscrc 'osc co' 'rm -f -- *' 'osc addremove' 'osc ci' 'osc results -w' obs_all_succeeded mk-dsc.sh trap '::error::'; do
    grep -qF -- "$s" "$f" || ERRS+=("push-obs.sh lacks: $s")
  done
  code=$(nc "$f")
  for s in 'set +-[a-zA-Z]*x' xtrace 'osc meta' 'results -w -F' 'osc (rdelete|delete|rm)( |$)' 'pip install' pipx; do
    ! grep -qE -- "$s" <<< "$code" || ERRS+=("push-obs.sh has: $s")
  done
  wf_ok || return 0
  need_in push-obs 'environment: package-repos' 'image: fedora:latest' 'dnf install -y osc git dpkg-dev' 'persist-credentials: false' \
    'packaging/push-obs.sh' 'OBS_USER: ${{ secrets.OBS_USER }}' 'OBS_PASS: ${{ secrets.OBS_PASS }}'
  ! nc "$WF" | grep -qE 'osc (meta|rdelete|delete)( |$)' || ERRS+=('release.yml writes OBS meta or deletes')
  for j in $(wf_jobs); do
    [ "$j" = verify-repos ] && continue
    got=$(wf_job "$j" | sed -n 's/^    needs: \[\(.*\)\]$/\1/p')
    case ", $got," in *', push-obs,'*) ERRS+=("$j needs push-obs") ;; esac
  done
}

# ---------- republish ----------

# REPO-05, D-06, D-07, T-21-11, T-21-12: the dispatch tag input reaches the shell only as fetch-release's TAG env, is checked against vN.N.N before use, and the job only downloads and checks
# shellcheck disable=SC2016 # the workflow's ${{ }} text is searched for
t_workflow_republish() {
  local s on bad
  wf_ok || return 0
  on=$(wf_nc | awk '/^on:$/ {on = 1; next} on && /^[^ ]/ {exit} on')
  for s in 'inputs:' 'tag:' 'required: false' 'type: string'; do
    grep -qF -- "$s" <<< "$on" || ERRS+=("the on: block lacks: $s")
  done
  need_in fetch-release 'TAG: ${{ inputs.tag }}' 'GH_TOKEN: ${{ github.token }}' '^v[0-9]+\.[0-9]+\.[0-9]+$' 'gh release download "$TAG"' '-p SHA256SUMS' \
    'sha256sum -c --ignore-missing SHA256SUMS' 'W3C_LINUX_VERSION=' GITHUB_OUTPUT 'name: tarball' 'if-no-files-found: error'
  ban_in fetch-release 'contents: write' 'environment:' 'secrets.' 'needs:'
  # the check comes before the download
  wf_job fetch-release | awk 'index($0, "^v[0-9]+") && !c {c = NR} index($0, "gh release download") && !d {d = NR} END {exit !(c && d && c < d)}' \
    || ERRS+=('fetch-release: the tag check does not come before gh release download')
  # inputs.tag: job-level if lines, and the one TAG env line
  bad=$(wf_nc | grep -F 'inputs.tag' | grep -vE '^    if: |^      TAG: \$\{\{ inputs\.tag \}\}$' || true)
  [ -z "$bad" ] || ERRS+=("inputs.tag outside a job-level if and the TAG env line: $bad")
  [ "$(wf_nc | grep -cE '^      TAG: \$\{\{ inputs\.tag \}\}$')" = 1 ] || ERRS+=('want exactly one TAG: ${{ inputs.tag }} line')
  ! wf_job fetch-release | grep -o '::error::[^"]*' | grep -qF 'TAG' || ERRS+=('an ::error:: line in fetch-release echoes $TAG')
}

# REPO-05, D-05, D-18, T-21-13: no job needs a push job but verify-repos, and both push jobs wait for publish and fetch-release, run on explicit results, and take the version from either path
# shellcheck disable=SC2016 # the workflow's ${{ }} text is searched for
t_workflow_isolation() {
  local j got
  wf_ok || return 0
  for j in $(wf_jobs); do
    got=$(wf_job "$j" | sed -n 's/^    needs: \[\(.*\)\]$/\1/p')
    [ "$j" = verify-repos ] && continue
    case ", $got," in *', push-copr,'* | *', push-obs,'*) ERRS+=("$j needs a push job: [$got]") ;; esac
  done
  for j in push-copr push-obs; do
    got=$(wf_job "$j" | sed -n 's/^    needs: \[\(.*\)\]$/\1/p')
    case ", $got," in *', publish,'*) ;; *) ERRS+=("$j needs [$got], want publish in it") ;; esac
    case ", $got," in *', fetch-release,'*) ;; *) ERRS+=("$j needs [$got], want fetch-release in it") ;; esac
    need_in "$j" "needs.publish.result == 'success'" "needs.fetch-release.result == 'success'" "$REPO_GUARD" \
      'VER: ${{ needs.tarball.outputs.version || needs.fetch-release.outputs.version }}'
    ban_in "$j" 'permissions:'
  done
}

# ---------- release smoke, umu half ----------

# DEBT-02, D-15, T-21-15: smoke-umu.sh runs the umu fallback and both backend set paths as a non-root user with a cleared environment, and never
# mocks umu: its non-comment lines name no umu override variable and write, copy or link nothing to a path ending umu-run
# shellcheck disable=SC2016 # the script's own text is searched for
t_smoke_script() {
  local f=$ROOT/packaging/smoke-umu.sh s
  [ -f "$f" ] || { ERRS+=('packaging/smoke-umu.sh is missing'); return 0; }
  for s in 'useradd -m' 'runuser -u' 'env -i' 'declare -f' 'backend set umu' 'fail  umu-run' \
    'Launch any game once in Faugus so it downloads umu-run' 'needs: Faugus (backend: umu)' 'W3C_PREFIX=' 'W3C_PROTON=' 'drive_c' \
    'pass  desktop entry' 'command -v umu-run'; do
    grep -qF -- "$s" "$f" || ERRS+=("smoke-umu.sh lacks: $s")
  done
  ! nc "$f" | grep -q 'UMU_RUN' || ERRS+=('smoke-umu.sh names the umu override variable')
  ! nc "$f" | grep -Eq '(>|>>|cp|ln|install|mv|tee)[^|;&]*umu-run[[:space:]"'"'"']*($|[;&|])' || ERRS+=('smoke-umu.sh writes, copies or links to a umu-run path')
}

# ---------- README repository routes and the verify job ----------

# bash_blocks HEADING: the lines inside the ```bash fences of README.md's `### ` section HEADING, each block's lines in order, blocks separated by a line holding ---
bash_blocks() { readme_sub "$1" | awk '/^```bash$/ {on = 1; n++; if (n > 1) print "---"; next} /^```$/ {on = 0; next} on'; }

# REPO-01, REPO-02, REPO-06, D-11, D-12, D-13, T-21-21, T-21-22: the README's repository lines have the shape verify-repo.sh copies, in order
# shellcheck disable=SC2016 # the README's own text, backticks included, is searched for
t_docs_readme() {
  local fed deb blk n s prev line fpr users
  fed=$(bash_blocks '### Fedora')
  deb=$(bash_blocks '### Debian/Ubuntu')
  [ "$(grep -cE '^sudo dnf copr enable [A-Za-z0-9_.-]+/w3c-linux$' <<< "$fed")" = 1 ] || ERRS+=('### Fedora wants exactly one `sudo dnf copr enable OWNER/w3c-linux` line in its bash blocks')
  [ "$(grep -cxF 'sudo dnf install w3c-linux' <<< "$fed")" = 1 ] || ERRS+=('### Fedora wants exactly one `sudo dnf install w3c-linux` line in its bash blocks')
  for s in '43, 44, 45 and rawhide' 'install-user' 'sudo dnf upgrade' 'sudo dnf install ./w3c-linux-*.noarch.rpm'; do
    readme_sub '### Fedora' | grep -qF -- "$s" || ERRS+=("### Fedora lacks: $s")
  done
  n=$(grep -c '^DIST=' <<< "$deb")
  [ "$n" = 1 ] || ERRS+=("### Debian/Ubuntu wants exactly one DIST= line in its bash blocks, has $n")
  blk=$(awk '/^---$/ {if (b ~ /^DIST=/) {printf "%s", b; exit}; b = ""; next} {b = b $0 "\n"} END {if (b ~ /^DIST=/) printf "%s", b}' <<< "$deb")
  [ "$(wc -l <<< "$blk")" = 5 ] || ERRS+=('the DIST= block is not five lines')
  [ "$(sed -n 1p <<< "$blk")" = 'DIST=xUbuntu_24.04' ] || ERRS+=('the DIST= block does not start with DIST=xUbuntu_24.04')
  prev=1
  for s in 'gpg --dearmor --yes -o /etc/apt/keyrings/w3c-linux.gpg' 'tee /etc/apt/sources.list.d/w3c-linux.list' 'sudo apt update' 'sudo apt install w3c-linux'; do
    prev=$((prev + 1))
    line=$(sed -n "${prev}p" <<< "$blk")
    grep -qF -- "$s" <<< "$line" || ERRS+=("DIST= block line $prev lacks: $s")
  done
  sed -n 3p <<< "$blk" | grep -qF 'signed-by=/etc/apt/keyrings/w3c-linux.gpg' || ERRS+=('the sources line lacks signed-by=/etc/apt/keyrings/w3c-linux.gpg')
  ! grep -qF 'tee -a' <<< "$blk" || ERRS+=('the DIST= block uses tee -a (not idempotent)')
  ! grep -qF 'os-release' <<< "$deb" || ERRS+=('a Debian/Ubuntu bash block reads os-release')
  for s in 'Debian 12 | `Debian_12`' 'Debian 13 | `Debian_13`' 'Ubuntu 26.04 | `xUbuntu_26.04`' 'LMDE 7 (untested) | `Debian_13`'; do
    readme_sub '### Debian/Ubuntu' | grep -qF -- "| $s |" || ERRS+=("DIST table lacks the row: $s")
  done
  readme_sub '### Debian/Ubuntu' | grep -F 'Linux Mint 22' | grep -qF '`xUbuntu_24.04`' || ERRS+=('Linux Mint 22 is not on the xUbuntu_24.04 row')
  fpr=$(readme_sub '### Debian/Ubuntu' | grep -oE '`([0-9A-F]{4} ){9}[0-9A-F]{4}`' | head -n 1)
  [ -n "$fpr" ] || ERRS+=('### Debian/Ubuntu holds no fingerprint in ten groups of four')
  users=$(grep -o 'repositories/home:/[^/]*/' "$ROOT/README.md" | sort -u)
  [ "$(grep -c . <<< "$users")" = 1 ] || ERRS+=("README OBS URLs name [$(tr '\n' ' ' <<< "$users")], want one project")
  readme_section '## Known issues' | grep -qF 'EXPKEYSIG' || ERRS+=('Known issues lacks EXPKEYSIG')
  readme_sub '### Fedora' | grep -F 'Bazzite' | grep -qF 'make install-user' || ERRS+=('the Bazzite line does not point at make install-user')
}

# REPO-05, REPO-06, D-04, T-21-24, T-21-25: RELEASE.md records the projects, the Environment, the credential locations, the token expiry with both renewal routes and the
# republish command; the Copr bot and the OBS project equal the README's. With RELEASE.md absent (the public tree) the case skips.
# shellcheck disable=SC2016 # RELEASE.md's own text, $PUB included, is searched for
t_docs_release() {
  local r=$ROOT/RELEASE.md s sec cb ob rb ru
  if [ ! -f "$r" ]; then
    printf '# skip: no RELEASE.md (the public repo)\n' >&2
    return 0
  fi
  for s in '## Package repositories' '180' 'new-api-token' 'COPR_CONFIG' 'OBS_USER' 'OBS_PASS' 'package-repos' '-f tag=v' 'gh run rerun'; do
    grep -qF -- "$s" "$r" || ERRS+=("RELEASE.md lacks: $s")
  done
  [ "$(grep -cE '^Copr token expires: [0-9]{4}-[0-9]{2}-[0-9]{2}$' "$r")" = 1 ] || ERRS+=('RELEASE.md wants exactly one line: Copr token expires: YYYY-MM-DD')
  grep '^PATHS=' "$r" | grep -qF 'packaging' || ERRS+=('the PATHS line lost packaging')
  grep '^PATHS=' "$r" | grep -qF '.github/workflows/release.yml' || ERRS+=('the PATHS line lost .github/workflows/release.yml')
  sec=$(awk '$0 == "## Package repositories" { on = 1; next } on && /^## / { exit } on' "$r")
  cb=$(grep '^| Copr project |' <<< "$sec" | grep -oE '`[A-Za-z0-9_.-]+/w3c-linux`' | head -n 1 | tr -d '`')
  ob=$(grep '^| OBS project |' <<< "$sec" | grep -oE '`home:[^`]*`' | head -n 1 | tr -d '`')
  rb=$(sed -n 's/^sudo dnf copr enable \([A-Za-z0-9_.-]*\/w3c-linux\)$/\1/p' "$ROOT/README.md" | head -n 1)
  ru=$(grep -o 'repositories/home:/[^/]*/[^/]*/' "$ROOT/README.md" | sort -u | head -n 1 | sed -e 's#^repositories/##' -e 's#:/#:#g' -e 's#/$##')
  [ -n "$cb" ] && [ "$cb" = "$rb" ] || ERRS+=("RELEASE.md Copr project [$cb] is not the README's [$rb]")
  [ -n "$ob" ] && [ "$ob" = "$ru" ] || ERRS+=("RELEASE.md OBS project [$ob] is not the README's [$ru]")
  ! grep -qE '^ *token *=' "$r" || ERRS+=('RELEASE.md holds a token = line')
  ! grep -qE 'OBS_PASS=.' "$r" || ERRS+=('RELEASE.md holds an OBS_PASS= value')
}

# REPO-05, REPO-06: CONTRIBUTING.md describes the new jobs and scripts
t_docs_contributing() {
  local c=$ROOT/CONTRIBUTING.md s sec tests
  sec=$(awk '$0 == "## Releases" { on = 1; next } on && /^## / { exit } on' "$c")
  for s in push-copr push-obs verify-repos fetch-release package-repos '!cancelled()' srpm dsc; do
    grep -qF -- "$s" <<< "$sec" || ERRS+=("Releases lacks: $s")
  done
  for s in mk-srpm.sh mk-dsc.sh push-copr.sh push-obs.sh smoke-umu.sh verify-repo.sh; do
    grep -qF -- "| \`packaging/$s\` |" "$c" || ERRS+=("Layout lacks a row for packaging/$s")
  done
  tests=$(awk '$0 == "## Tests" { on = 1; next } on && /^## / { exit } on' "$c")
  grep -qF 'Phase 21' <<< "$tests" || ERRS+=('Tests does not cover Phase 21')
}

# D-02: no placeholder owner or user name is left in the public text
t_docs_placeholders() {
  local f
  for f in README.md CONTRIBUTING.md RELEASE.md .github/workflows/release.yml packaging/*.sh; do
    [ -f "$ROOT/$f" ] || continue
    ! grep -qE '<copr-owner>|<obs-user>' "$ROOT/$f" || ERRS+=("$f holds a <copr-owner> or <obs-user> placeholder")
  done
}

# REPO-01, REPO-02, D-09, D-17, T-21-23: verify-repos waits for both pushes, runs in all eight images with no environment and no secret
# shellcheck disable=SC2016 # the workflow's ${{ }} text is searched for
t_verify_workflow() {
  local img
  wf_ok || return 0
  need_in verify-repos 'fail-fast: false' 'persist-credentials: false' 'packaging/verify-repo.sh' 'needs.push-copr.result' 'needs.push-obs.result' \
    "$REPO_GUARD" 'VER: ${{ needs.tarball.outputs.version || needs.fetch-release.outputs.version }}'
  for img in fedora:43 fedora:44 fedora:45 fedora:rawhide debian:12 debian:13 ubuntu:24.04 ubuntu:26.04; do
    [ "$(wf_job verify-repos | grep -cE "image: $img\$")" = 1 ] || ERRS+=("verify-repos wants the matrix image $img exactly once")
  done
  ban_in verify-repos 'environment:' 'secrets.' 'osc '
}

# REPO-01, REPO-02, T-21-22, T-21-23: verify-repo.sh takes its lines from the README, waits, checks the key and the version, and never uses osc
t_verify_script() {
  local f=$ROOT/packaging/verify-repo.sh s
  [ -f "$f" ] || { ERRS+=('packaging/verify-repo.sh is missing'); return 0; }
  for s in '### Fedora' '### Debian/Ubuntu' 'dnf copr enable' 'assumeyes=True' 'APT::Get::Assume-Yes' 'apt-cache madison' 'gpg --show-keys' 'w3c-linux version' '::error::'; do
    grep -qF -- "$s" "$f" || ERRS+=("verify-repo.sh lacks: $s")
  done
  ! nc "$f" | grep -qE '(^|[^[:alnum:]_-])osc([^[:alnum:]_-]|$)' || ERRS+=('verify-repo.sh calls osc')
}

# ---------- public path list ----------

# REPO-06: every tracked file under packaging/, and this suite, lies under a path RELEASE.md's PATHS line copies into the public repo
t_paths_public() {
  local r=$ROOT/RELEASE.md paths p f ok
  if [ ! -f "$r" ] || ! git -C "$ROOT" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    printf '# skip: no RELEASE.md or not a git work tree (the public repo)\n' >&2
    return 0
  fi
  paths=$(sed -n 's/^PATHS="\(.*\)"$/\1/p' "$r" | head -n 1)
  [ -n "$paths" ] || { ERRS+=('RELEASE.md has no PATHS="..." line'); return 0; }
  while IFS= read -r f; do
    ok=0
    # shellcheck disable=SC2086 # PATHS is a word list
    for p in $paths; do
      case $f in "$p" | "$p"/*) ok=1 ;; esac
    done
    [ "$ok" = 1 ] || ERRS+=("not under a PATHS entry: $f")
  done < <(git -C "$ROOT" ls-files packaging; printf '%s\n' tests/phase21.sh)
}

# ---------- runner ----------

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
