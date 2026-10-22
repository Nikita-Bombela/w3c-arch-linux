#!/usr/bin/env bash
# Install w3c-linux from its Copr or OBS repository with the lines the README prints and check the version (Phase 21 D-09, D-17); release.yml's verify-repos job runs it
# as root in a bare fedora or debian-family container with the checkout (README.md) as the working directory. The lines come out of README.md, not a copy, so README drift turns it red.
# Reads the repositories anonymously: no secret, no osc.
# Usage: verify-repo.sh FAMILY VER [DIST]   (FAMILY fedora or debian; DIST is the OBS directory, required for debian)
set -euo pipefail

[ $# -ge 2 ] && [ $# -le 3 ] || { echo 'usage: verify-repo.sh FAMILY VER [DIST]' >&2; exit 2; }
family=$1 ver=$2 dist=${3:-}

err() {
  echo "::error::$*"
  exit 1
}

printf '%s' "$ver" | grep -Eqx '[0-9]+\.[0-9]+\.[0-9]+' || err "VER is '$ver', want N.N.N"

# sub HEADING: README.md's text from the `### ` line HEADING to the next heading
sub() { awk -v h="$1" '$0 == h { on = 1; next } on && /^##/ { exit } on' README.md; }
# blocks HEADING: the lines inside the ```bash fences of that section, one block after the other, a line holding --- between blocks
blocks() { sub "$1" | awk '/^```bash$/ { on = 1; n++; if (n > 1) print "---"; next } /^```$/ { on = 0; next } on'; }

# poll SECONDS EVERY WHAT CMD...: run CMD until it succeeds; give up with an error naming WHAT after SECONDS
poll() {
  local max=$1 every=$2 what=$3 end
  shift 3
  end=$((SECONDS + max))
  until "$@"; do
    [ "$SECONDS" -lt "$end" ] || err "$what did not carry w3c-linux $ver-1 within $((max / 60)) minutes"
    sleep "$every"
  done
}

copr_has() { dnf --refresh list --available w3c-linux 2> /dev/null | awk -v v="$ver-1" '$1 ~ /^w3c-linux\./ && $2 == v { f = 1 } END { exit !f }'; }
obs_has() {
  apt-get update -q > /dev/null 2>&1 || true
  apt-cache madison w3c-linux | awk -v v="$ver-1" '$3 == v { f = 1 } END { exit !f }'
}

case $family in
  fedora)
    sec=$(blocks '### Fedora')
    enable=$(grep -E '^sudo dnf copr enable [^ /]+/w3c-linux$' <<< "$sec" || true)
    install=$(grep -xF 'sudo dnf install w3c-linux' <<< "$sec" || true)
    [ "$(grep -c . <<< "$enable")" = 1 ] || err "README.md ### Fedora wants exactly one 'sudo dnf copr enable OWNER/w3c-linux' line in its bash blocks, has [$enable]"
    [ "$(grep -c . <<< "$install")" = 1 ] || err "README.md ### Fedora wants exactly one 'sudo dnf install w3c-linux' line in its bash blocks"
    command -v sudo > /dev/null || dnf install -y sudo
    # dnf asks before enabling a Copr; there is no tty here
    printf 'assumeyes=True\n' >> /etc/dnf/dnf.conf
    bash -eo pipefail -c "$enable"
    poll 600 20 'the Copr repository' copr_has
    bash -eo pipefail -c "$install"
    ;;
  debian)
    [ -n "$dist" ] || err 'debian needs the DIST argument'
    apt-get update
    apt-get install -y sudo curl gpg ca-certificates
    # sudo apt install asks "Do you want to continue?" and aborts without a tty
    printf 'APT::Get::Assume-Yes "true";\n' > /etc/apt/apt.conf.d/99yes
    block=$(blocks '### Debian/Ubuntu' | awk '/^---$/ { if (b ~ /^DIST=/) { printf "%s", b; exit } b = ""; next } { b = b $0 "\n" } END { if (b ~ /^DIST=/) printf "%s", b }')
    [ -n "$block" ] || err 'README.md ### Debian/Ubuntu has no bash block whose first line starts DIST='
    last=$(tail -n 1 <<< "$block")
    [ "$last" = 'sudo apt install w3c-linux' ] || err "README.md's DIST= block ends with '$last', want 'sudo apt install w3c-linux'"
    # the reader edits the first line; the middle lines are the key import, the source and the update
    middle=$(sed '1d;$d' <<< "$block")
    bash -eo pipefail -c "DIST=$dist"$'\n'"$middle"
    # shellcheck disable=SC2016 # the backticks are literal Markdown
    want=$(sub '### Debian/Ubuntu' | grep -oE '`([0-9A-F]{4} ){9}[0-9A-F]{4}`' | head -n 1 | tr -d '` ')
    [ -n "$want" ] || err "README.md ### Debian/Ubuntu holds no signing key fingerprint in ten groups of four"
    got=$(gpg --show-keys --with-colons /etc/apt/keyrings/w3c-linux.gpg | awk -F: '$1 == "fpr" { print $10; exit }')
    [ "$got" = "$want" ] || err "the imported key's fingerprint is '$got', the README says '$want'"
    poll 1200 30 "the OBS repository $dist" obs_has
    bash -eo pipefail -c "$last"
    ;;
  *) err "FAMILY is '$family', want fedora or debian" ;;
esac

got=$(w3c-linux version)
[ "$got" = "w3c-linux $ver" ] || err "w3c-linux version printed '$got', want 'w3c-linux $ver'"
echo "VERIFY-REPO-OK $family $ver ${dist:-copr}: $got"
