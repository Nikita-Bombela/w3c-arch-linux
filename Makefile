# Installs w3c-linux the way packaging/PKGBUILD does: one tree definition for packages and for plain installs.
#   make install [DESTDIR=dir] [PREFIX=/usr]   system install or package staging
#   make install-user                          into ~/.local, no root;  make uninstall / uninstall-user remove it again
#   make check [SUITES=glob]                   shellcheck plus the test suites
PREFIX ?= /usr
# CI's split is SUITES='tests/phase[1-9].sh' and SUITES='tests/phase[1-9][0-9]*.sh' (Phase 10 D-22, Phase 11 D-11); packagers on other
# distros leave tests/phase7.sh out the same way (it needs makepkg). ?= so a SUITES in the environment, as ci.yml and release.yml set it per check (Phase 13 D-12), also works.
SUITES ?= tests/phase[0-9]*.sh

name := w3c-linux
# Recursive (=) on purpose: install-user sets PREFIX per target, and a simple (:=) assignment would freeze /usr at parse time.
root = $(DESTDIR)$(PREFIX)

.PHONY: all install install-user uninstall uninstall-user need-home check
# need-home must finish before install starts, also under make -j.
.NOTPARALLEL:

# First target: a bare `make` must never install.
all:
	@echo 'usage: make install [DESTDIR=dir] [PREFIX=/usr] | install-user | uninstall | uninstall-user | check [SUITES=glob]'

# ponytail: no update-desktop-database or icon-cache refresh (the entry has no MimeType and the package stays hook-free). A desktop that
# does not watch ~/.local/share/applications shows the entry after the next login; add an optional, never-failing refresh if one is shown to need it.
install:
	install -Dm755 -t '$(root)/lib/$(name)' w3c-linux.sh
	install -Dm644 -t '$(root)/lib/$(name)/lib' lib/*.sh lib/*.py
# the askpass helper is executed (sudo -A), so it stays 755
	install -Dm755 -t '$(root)/lib/$(name)/lib' lib/w3c-askpass.sh
	install -d '$(root)/bin'
# relative, so a staged root resolves inside itself; -f so a reinstall replaces the link
	ln -sf '../lib/$(name)/w3c-linux.sh' '$(root)/bin/$(name)'
	install -Dm644 -t '$(root)/share/applications' share/$(name).desktop
	install -Dm644 -t '$(root)/share/icons/hicolor/256x256/apps' share/$(name).png

# Stops before any install or rm step when HOME is empty: PREFIX would otherwise become /.local.
need-home:
	@test -n '$(HOME)' || { echo 'make: HOME is not set' >&2; exit 1; }

# The user install is `install` with PREFIX = ~/.local, then the menu entry's Exec line made absolute (the menu does not search ~/.local/bin).
# The Exec path is $(PREFIX)/bin, never $(root): DESTDIR is a staging prefix the running menu must not name. The path is used verbatim when
# it has only [A-Za-z0-9/._+@:,=-]; otherwise it is quoted as lib/common.sh desk_quote does (backslash x4, quote, backtick and dollar x2,
# percent doubled, wrapped in double quotes). The value reaches awk through its environment array, never program text, and is written into the file
# install just made, so it keeps mode 0644 whatever the umask.
install-user: PREFIX = $(HOME)/.local
install-user: need-home install
	@p='$(PREFIX)/bin/$(name)'; \
	case $$p in *[!A-Za-z0-9/._+@:,=-]*) \
	p=$$(printf '%s' "$$p" | sed -e 's/\\/\\\\\\\\/g' -e 's/"/\\\\"/g' -e 's/`/\\\\`/g' -e 's/\$$/\\\\$$/g' -e 's/%/%%/g'); p="\"$$p\"" ;; \
	esac; \
	W3C_EXEC="Exec=$$p launch" awk '/^Exec=/ { print ENVIRON["W3C_EXEC"]; next } { print }' share/$(name).desktop > '$(root)/share/applications/$(name).desktop'

# Removes the four installed paths and nothing else: no manifest, no per-file list, never state, cache or config. No trailing slash on the
# lib path, so a symlinked directory loses only the link. Shared directories stay, as pacman leaves them; a package install is removed with
# pacman -R instead.
uninstall:
	rm -rf '$(root)/lib/$(name)'
	rm -f '$(root)/bin/$(name)' '$(root)/share/applications/$(name).desktop' '$(root)/share/icons/hicolor/256x256/apps/$(name).png'

uninstall-user: PREFIX = $(HOME)/.local
uninstall-user: need-home uninstall

# shellcheck, then every suite (all of them run, shellcheck failing or not; the status is non-zero when any failed). ci.yml and release.yml call this target, once per
# suite half. A shell loop, not $(wildcard): an unmatched glob stays literal and bash fails on it, so a typo
# in SUITES is loud. A missing shellcheck fails and names itself.
check:
	@command -v shellcheck > /dev/null || { echo 'make check: shellcheck not found' >&2; exit 1; }
	@rc=0; shellcheck -x w3c-linux.sh lib/*.sh tests/phase*.sh tests/live.sh || rc=1; \
	for f in $(SUITES); do echo "== $$f"; bash "$$f" || rc=1; done; exit $$rc
