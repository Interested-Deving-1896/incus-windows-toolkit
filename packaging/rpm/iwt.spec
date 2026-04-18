Name:           incus-windows-toolkit
Version:        1.0.0
Release:        1%{?dist}
Summary:        Unified CLI for Windows VM management on Incus
License:        MIT
URL:            https://gitlab.com/OSPF1896/incus-windows-toolkit
Source0:        %{name}-%{version}.tar.gz
BuildArch:      noarch
Requires:       bash >= 4.0, curl, jq
Recommends:     incus, qemu-img, wimlib-utils, xorriso, freerdp
Suggests:       dialog, hivex, cabextract

%description
IWT handles the full Windows VM lifecycle on Incus: ISO download,
image building with driver injection and debloating, VM creation
from templates, guest tool installation, GPU/USB passthrough,
shared folders, RemoteApp, snapshots, and backup/export.
Supports x86_64 and ARM64.

%prep
%autosetup

%install
%make_install PREFIX=%{_prefix}

%files
%license LICENSE
%{_bindir}/iwt
%{_datadir}/iwt/
%{_datadir}/bash-completion/completions/iwt
%{_datadir}/zsh/site-functions/_iwt
%{_mandir}/man1/iwt.1*

%changelog
* Sun Mar 02 2025 IWT Contributors - 1.0.0-1
- Initial release
