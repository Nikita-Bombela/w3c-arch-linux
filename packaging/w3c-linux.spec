# Built by .github/workflows/release.yml: rpmbuild -bb --define "w3c_version X.Y.Z" from the release tarball; Version is a build input (Phase 13 D-05).
Name:           w3c-linux
Version:        %{w3c_version}
Release:        1
Summary:        Run the W3Champions launcher inside the Faugus Battle.net prefix
License:        GPL-3.0-or-later
URL:            https://github.com/Nikita-Bombela/w3c-arch-linux
Source0:        %{name}-%{version}.tar.gz
BuildArch:      noarch
BuildRequires:  make
Requires:       bash
Requires:       curl
Requires:       python3
Requires:       coreutils
Requires:       tar
Requires:       procps-ng
Requires:       util-linux-core
# Recommends are the PKGBUILD optdepends: dnf installs them by default and --setopt=install_weak_deps=False skips them.
# iptables-nft is the NAT alternative to nftables and is deliberately not recommended, so one firewall tool comes in.
Recommends:     faugus-launcher
Recommends:     nftables
Recommends:     sudo
Recommends:     zenity
Recommends:     libnotify
Recommends:     desktop-file-utils

%description
w3c-linux installs, launches and updates the W3Champions launcher inside the Battle.net prefix Faugus Launcher manages, or a prefix set with w3c-linux backend set umu.
faugus-launcher is recommended, not required: the Battle.net prefix and umu-run; without it, w3c-linux backend set umu and a system umu-run.

%prep
%autosetup

%build

%install
make install DESTDIR=%{buildroot} PREFIX=%{_prefix}

%files
%license LICENSE
%{_bindir}/w3c-linux
%{_prefix}/lib/%{name}
%{_datadir}/applications/w3c-linux.desktop
%{_datadir}/icons/hicolor/256x256/apps/w3c-linux.png
