#!/usr/bin/env bash
# DEBT-02 (Phase 21 D-15): the release smoke jobs' umu half. Run as root after the package install, in a container with no Faugus and no umu-run;
# release.yml takes this script out of the tarball. The checks run as a non-root user with a cleared environment: doctor on the umu fallback,
# backend set umu and backend show. Nothing here mocks umu or reaches the network.
# Usage: smoke-umu.sh
set -euo pipefail

err() {
  echo "::error::$*"
  exit 1
}

# smoke_user: every check, run as the unprivileged user (declare -f carries it through runuser); bf is the backend file
smoke_user() {
  local bf=$HOME/.config/w3c-linux/backend rc out last l
  fail() {
    echo "::error::smoke-umu: $*"
    exit 1
  }
  mkdir -p "$HOME/pfx/drive_c" "$HOME/runner"

  # c: doctor on the umu fallback; the override pair is on this command line only
  rc=0
  out=$(W3C_PREFIX="$HOME/pfx" W3C_PROTON="$HOME/runner" w3c-linux doctor 2>&1) || rc=$?
  printf '%s\n' "$out"
  [ "$rc" = 1 ] || fail "doctor exited $rc, want 1"
  grep -Eq '^fail  umu-run  *Launch any game once in Faugus so it downloads umu-run' <<< "$out" \
    || fail "doctor has no fail row for umu-run telling the user to launch a game once in Faugus"
  grep -Eq '^pass  backend  *umu: prefix and runner from W3C_PREFIX and W3C_PROTON' <<< "$out" \
    || fail "doctor has no pass row for backend naming W3C_PREFIX and W3C_PROTON"
  for l in games.json battlenet launch_arguments path config.json envar.json 'faugus env'; do
    grep -F "skip  $l " <<< "$out" | grep -qF 'needs: Faugus (backend: umu)' || fail "doctor has no skip row for $l needing Faugus (backend: umu)"
  done
  ! grep -Eq '^(pass|fail|warn)  (games\.json|battlenet|launch_arguments|path|config\.json|envar\.json|faugus env) ' <<< "$out" \
    || fail "doctor has a pass, fail or warn row for a Faugus-only check"
  last=${out##*$'\n'}
  case $last in
    'pass  desktop entry'*) ;;
    *) fail "doctor's last row is '$last', want pass  desktop entry" ;;
  esac

  # d: backend set umu saves the pair; backend show names the file
  w3c-linux backend set umu "$HOME/pfx" "$HOME/runner"
  [ -f "$bf" ] || fail "backend set umu wrote no $bf"
  grep -qxF 'BACKEND=umu' "$bf" || fail "$bf has no BACKEND=umu line"
  grep -qxF "PREFIX=$HOME/pfx" "$bf" || fail "$bf has no PREFIX=$HOME/pfx line"
  grep -q '^RUNNER=' "$bf" || fail "$bf has no RUNNER= line"
  out=$(w3c-linux backend show)
  printf '%s\n' "$out"
  [ "${out%%$'\n'*}" = "backend: umu (from $bf)" ] || fail "backend show's first line is '${out%%$'\n'*}', want 'backend: umu (from $bf)'"
}

# the machine must have no umu-run: this smoke proves the fallback, never a stand-in (D-15)
if command -v umu-run > /dev/null 2>&1; then
  err 'smoke-umu: umu-run is installed here; this smoke needs a machine without it'
fi
if ! command -v runuser > /dev/null 2>&1 && command -v dnf > /dev/null 2>&1; then
  dnf install -y util-linux
fi
command -v runuser > /dev/null 2>&1 || err 'smoke-umu: runuser is missing'
id smoke > /dev/null 2>&1 || useradd -m smoke

# env -i: no inherited UMU or W3C_* variables reach the checks
runuser -u smoke -- env -i HOME=/home/smoke PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin LANG=C.UTF-8 \
  bash -c "set -euo pipefail; $(declare -f smoke_user); smoke_user"
