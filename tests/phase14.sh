#!/usr/bin/env bash
# Phase 14 static check of the CI matrix, on the harness of tests/phase2.sh to tests/phase6.sh: every tests/phase*.sh must run in exactly one
# leg of .github/workflows/release.yml and, where the file exists, of ci.yml (the public repo carries only release.yml), and ci.yml's legs
# must equal release.yml's. This is the only place the legs are pinned. It reads the workflow text and tests/ only, so it runs unchanged in
# the public tree, and it never reaches the network or a package manager.
# Usage: bash tests/phase14.sh [GLOB]   (GLOB filters on display names such as legs-release)
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

WF=$ROOT/.github/workflows/release.yml
LEG_NAMES='doctor launch nat distribution'

# ---------- helpers ----------

# legs FILE: one "name<TAB>suites" line per matrix.include entry. Whole-line comments and one pair of surrounding quotes are stripped; only the
# include: key is read, so a matrix without it (smoke-deb's image list) is skipped and the job id does not matter.
legs() {
  grep -v '^[[:space:]]*#' "$1" | awk -v q="'" '
    function val(s) { sub(/^[^:]*:[[:space:]]*/, "", s); sub(/[[:space:]]+$/, "", s); if (length(s) > 1 && (substr(s, 1, 1) == q || substr(s, 1, 1) == "\"") && substr(s, length(s), 1) == substr(s, 1, 1)) s = substr(s, 2, length(s) - 2); return s }
    { match($0, /^ */); ind = RLENGTH }
    inc && $0 !~ /^[[:space:]]*$/ && ind <= inc_ind { inc = 0 }
    /^ *include:[[:space:]]*$/ { inc = 1; inc_ind = ind; next }
    inc && /^ *- name:/ { if (n != "") print n "\t" s; n = val($0); s = ""; next }
    inc && /^ *suites:/ { s = val($0); next }
    END { if (n != "") print n "\t" s }'
}

# leg_problems ROOT WORKFLOW: one line per problem, nothing when the matrix is right
leg_problems() {
  local root=$1 wf=$2 names name suites g f n
  local -a globs
  local -A hit=()
  names=$(legs "$wf" | cut -f1 | tr '\n' ' ')
  [ "$names" = "$LEG_NAMES " ] || printf 'leg names are [%s], want [%s]\n' "${names% }" "$LEG_NAMES"
  while IFS=$'\t' read -r name suites; do
    # split without expanding against the cwd, then expand each glob inside ROOT as make check's shell loop would
    read -ra globs <<< "$suites"
    for g in ${globs[@]+"${globs[@]}"}; do
      n=0
      while IFS= read -r f; do n=$((n + 1)); hit[$f]+="$name "; done < <(cd "$root" && compgen -G "$g")
      [ "$n" -gt 0 ] || printf '%s: glob matches no file: %s\n' "$name" "$g"
    done
  done < <(legs "$wf")
  while IFS= read -r f; do
    case ${hit[$f]:-} in
      '') printf '%s is in no leg (add a glob for it to the same leg in ci.yml and release.yml)\n' "$f" ;;
      *' '?*' ') printf '%s is in several legs: %s\n' "$f" "${hit[$f]% }" ;;
    esac
  done < <(cd "$root" && compgen -G 'tests/phase*.sh')
}

# ci_problems ROOT CI RELEASE: the leg_problems of CI, plus a line when its legs (names and suites strings) differ from RELEASE's
ci_problems() {
  leg_problems "$1" "$2"
  [ "$(legs "$2")" = "$(legs "$3")" ] || printf 'ci.yml legs differ from release.yml legs\n'
}

# fx_tree: a fixture under $T/cov, with empty suites and a minimal release.yml holding the four legs
fx_tree() {
  local n
  mkdir -p "$T/cov/tests"
  for n in 1 2 3 4 5 6 7 8 10 11 12 13 14; do : > "$T/cov/tests/phase$n.sh"; done
  printf '%s\n' 'jobs:' '  test:' '    strategy:' '      matrix:' '        include:' \
    '          - name: doctor' "            suites: 'tests/phase[12].sh'" \
    '          - name: launch' "            suites: 'tests/phase[34].sh tests/phase10.sh'" \
    '          - name: nat' "            suites: 'tests/phase5.sh'" \
    '          - name: distribution' "            suites: 'tests/phase[678].sh tests/phase1[1-9].sh'" \
    '    container:' '      image: archlinux:latest' > "$T/cov/release.yml"
}

# ---------- cases ----------

t_legs_release() {
  [ -f "$WF" ] || { ERRS+=('.github/workflows/release.yml is missing'); return 0; }
  local l
  while IFS= read -r l; do ERRS+=("$l"); done < <(leg_problems "$ROOT" "$WF")
}

t_legs_ci() {
  local ci=$ROOT/.github/workflows/ci.yml l
  if [ ! -f "$ci" ]; then
    printf '# skip: no .github/workflows/ci.yml (the public repo carries only release.yml)\n' >&2
    return 0
  fi
  while IFS= read -r l; do ERRS+=("$l"); done < <(ci_problems "$ROOT" "$ci" "$WF")
}

t_catch_clean() {
  fx_tree
  local out
  out=$(leg_problems "$T/cov" "$T/cov/release.yml")
  [ -z "$out" ] || ERRS+=("a good fixture reports: $out")
}

t_catch_new_suite() {
  fx_tree
  : > "$T/cov/tests/phase20.sh"
  : > "$T/cov/tests/phase9.sh"
  local out
  out=$(leg_problems "$T/cov" "$T/cov/release.yml")
  grep -q '^tests/phase20.sh is in no leg' <<< "$out" || ERRS+=("phase20 not reported: $out")
  grep -q '^tests/phase9.sh is in no leg' <<< "$out" || ERRS+=("phase9 not reported: $out")
}

t_catch_empty_glob() {
  fx_tree
  sed -i "s#suites: 'tests/phase5.sh'#suites: 'tests/phase5.sh tests/phase99.sh'#" "$T/cov/release.yml"
  local out
  out=$(leg_problems "$T/cov" "$T/cov/release.yml")
  grep -qxF 'nat: glob matches no file: tests/phase99.sh' <<< "$out" || ERRS+=("empty glob not reported: $out")
}

t_catch_two_legs() {
  fx_tree
  sed -i "s#suites: 'tests/phase\[34\].sh tests/phase10.sh'#suites: 'tests/phase[34].sh tests/phase10.sh tests/phase5.sh'#" "$T/cov/release.yml"
  local out
  out=$(leg_problems "$T/cov" "$T/cov/release.yml")
  grep -qxF 'tests/phase5.sh is in several legs: launch nat' <<< "$out" || ERRS+=("two legs not reported: $out")
}

t_catch_leg_names() {
  fx_tree
  sed -i 's#- name: doctor#- name: faugus#' "$T/cov/release.yml"
  local out
  out=$(leg_problems "$T/cov" "$T/cov/release.yml")
  grep -qxF 'leg names are [faugus launch nat distribution], want [doctor launch nat distribution]' <<< "$out" || ERRS+=("leg names not reported: $out")
}

t_catch_ci_drift() {
  fx_tree
  cp "$T/cov/release.yml" "$T/cov/ci.yml"
  sed -i "s#suites: 'tests/phase\[34\].sh tests/phase10.sh'#suites: 'tests/phase10.sh tests/phase[34].sh'#" "$T/cov/ci.yml"
  local out
  out=$(ci_problems "$T/cov" "$T/cov/ci.yml" "$T/cov/release.yml")
  [ "$out" = 'ci.yml legs differ from release.yml legs' ] || ERRS+=("drift not reported alone: $out")
}

# ---------- runner ----------

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
