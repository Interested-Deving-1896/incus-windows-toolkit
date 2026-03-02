#!/usr/bin/env bash
# Build a Windows image for Incus with optional slimming and driver injection.
#
# Usage:
#   build-image.sh [options]
#
# Options:
#   --iso PATH          Path to Windows ISO (required)
#   --arch ARCH         Target architecture: x86_64 | arm64 (default: x86_64)
#   --edition EDITION   Windows edition to install (default: Pro)
#   --slim              Strip bloatware packages (tiny11-style)
#   --output PATH       Output image path (default: windows-<arch>.qcow2)
#   --inject-drivers    Inject VirtIO + platform drivers into the image
#   --woa-drivers PATH  Path to WOA-Drivers directory (ARM only)
#   --size SIZE         Disk image size (default: 64G)
#   --help              Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(dirname "$SCRIPT_DIR")"
WORK_DIR=""

# Defaults
ARCH="x86_64"
EDITION="Pro"
SLIM=false
INJECT_DRIVERS=true
ISO_PATH=""
OUTPUT=""
WOA_DRIVERS=""
DISK_SIZE="64G"

# --- Helpers ---

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo ":: $*"; }
warn() { echo "WARNING: $*" >&2; }

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        info "Cleaning up work directory"
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

require_cmd() {
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
    done
}

usage() {
    sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
    exit 0
}

# --- Argument parsing ---

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --iso)        ISO_PATH="$2"; shift 2 ;;
            --arch)       ARCH="$2"; shift 2 ;;
            --edition)    EDITION="$2"; shift 2 ;;
            --slim)       SLIM=true; shift ;;
            --output)     OUTPUT="$2"; shift 2 ;;
            --inject-drivers) INJECT_DRIVERS=true; shift ;;
            --woa-drivers) WOA_DRIVERS="$2"; shift 2 ;;
            --size)       DISK_SIZE="$2"; shift 2 ;;
            --help)       usage ;;
            *)            die "Unknown option: $1" ;;
        esac
    done

    [[ -n "$ISO_PATH" ]] || die "--iso is required"
    [[ -f "$ISO_PATH" ]] || die "ISO not found: $ISO_PATH"
    [[ "$ARCH" =~ ^(x86_64|arm64)$ ]] || die "Invalid arch: $ARCH (must be x86_64 or arm64)"

    if [[ -z "$OUTPUT" ]]; then
        OUTPUT="windows-${ARCH}.qcow2"
    fi

    if [[ "$ARCH" == "arm64" && -n "$WOA_DRIVERS" && ! -d "$WOA_DRIVERS" ]]; then
        die "WOA drivers directory not found: $WOA_DRIVERS"
    fi
}

# --- ISO extraction and modification ---

extract_iso() {
    info "Extracting ISO to work directory"
    local mount_point="$WORK_DIR/iso_mount"
    local extract_dir="$WORK_DIR/iso_extracted"

    mkdir -p "$mount_point" "$extract_dir"

    # Mount and copy (handles read-only ISO)
    sudo mount -o loop,ro "$ISO_PATH" "$mount_point"
    cp -a "$mount_point"/. "$extract_dir"/
    sudo umount "$mount_point"

    # Make writable
    chmod -R u+w "$extract_dir"

    echo "$extract_dir"
}

# --- Bloatware removal (tiny11-style) ---

# Packages to remove for a slim image. Sourced from tiny11builder's approach.
SLIM_PACKAGES=(
    Microsoft.BingNews
    Microsoft.BingWeather
    Microsoft.GamingApp
    Microsoft.GetHelp
    Microsoft.Getstarted
    Microsoft.MicrosoftOfficeHub
    Microsoft.MicrosoftSolitaireCollection
    Microsoft.People
    Microsoft.PowerAutomateDesktop
    Microsoft.Todos
    Microsoft.WindowsAlarms
    Microsoft.WindowsCommunicationsApps
    Microsoft.WindowsFeedbackHub
    Microsoft.WindowsMaps
    Microsoft.WindowsSoundRecorder
    Microsoft.Xbox.TCUI
    Microsoft.XboxGameOverlay
    Microsoft.XboxGamingOverlay
    Microsoft.XboxIdentityProvider
    Microsoft.XboxSpeechToTextOverlay
    Microsoft.YourPhone
    Microsoft.ZuneMusic
    Microsoft.ZuneVideo
    Clipchamp.Clipchamp
    Microsoft.549981C3F5F10
    MicrosoftTeams
)

slim_image() {
    local install_wim="$1/sources/install.wim"
    [[ -f "$install_wim" ]] || die "install.wim not found in extracted ISO"

    info "Slimming Windows image (removing ${#SLIM_PACKAGES[@]} bloatware packages)"

    local wim_mount="$WORK_DIR/wim_mount"
    mkdir -p "$wim_mount"

    # Find the index for the requested edition
    local index
    index=$(wiminfo "$install_wim" | grep -B1 "Name:.*$EDITION" | grep "Index:" | awk '{print $2}' | head -1)
    [[ -n "$index" ]] || die "Edition '$EDITION' not found in install.wim"

    info "Mounting install.wim (index $index, edition: $EDITION)"
    sudo wimlib-imagex mountrw "$install_wim" "$index" "$wim_mount"

    # Remove provisioned appx packages
    for pkg in "${SLIM_PACKAGES[@]}"; do
        local pkg_dir
        pkg_dir=$(find "$wim_mount/Program Files/WindowsApps" -maxdepth 1 -name "${pkg}_*" -type d 2>/dev/null || true)
        if [[ -n "$pkg_dir" ]]; then
            info "  Removing: $pkg"
            sudo rm -rf "$pkg_dir"
        fi
    done

    # Remove provisioned package metadata from the registry hive
    # This prevents packages from being re-provisioned on first login
    if command -v hivexregedit >/dev/null 2>&1; then
        info "Cleaning provisioned package registry entries"
        local software_hive="$wim_mount/Windows/System32/config/SOFTWARE"
        if [[ -f "$software_hive" ]]; then
            for pkg in "${SLIM_PACKAGES[@]}"; do
                sudo hivexsh -w "$software_hive" <<-EOF 2>/dev/null || true
cd \Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned
mk ${pkg}_*
EOF
            done
        fi
    else
        warn "hivexregedit not found; skipping registry cleanup (packages may re-provision)"
    fi

    sudo wimlib-imagex unmount --commit "$wim_mount"
    info "Slimming complete"
}

# --- Driver injection ---

inject_virtio_drivers() {
    local extract_dir="$1"
    local install_wim="$extract_dir/sources/install.wim"

    info "Injecting VirtIO drivers"

    # Download VirtIO ISO if not cached
    local virtio_iso="$WORK_DIR/virtio-win.iso"
    local virtio_url
    if [[ "$ARCH" == "arm64" ]]; then
        virtio_url="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso"
    else
        virtio_url="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso"
    fi

    if [[ ! -f "$virtio_iso" ]]; then
        info "Downloading VirtIO drivers"
        curl -fSL -o "$virtio_iso" "$virtio_url"
    fi

    # Mount VirtIO ISO
    local virtio_mount="$WORK_DIR/virtio_mount"
    mkdir -p "$virtio_mount"
    sudo mount -o loop,ro "$virtio_iso" "$virtio_mount"

    # Copy drivers to a directory on the install media so Windows setup can find them
    local driver_dest="$extract_dir/\$WinPEDriver\$"
    mkdir -p "$driver_dest"

    local win_arch
    [[ "$ARCH" == "x86_64" ]] && win_arch="amd64" || win_arch="ARM64"

    # Copy all relevant driver directories
    for driver_dir in "$virtio_mount"/*/; do
        local driver_name
        driver_name=$(basename "$driver_dir")
        local arch_dir="$driver_dir/w11/$win_arch"
        [[ -d "$arch_dir" ]] || arch_dir="$driver_dir/2k22/$win_arch"
        [[ -d "$arch_dir" ]] || arch_dir="$driver_dir/2k19/$win_arch"
        if [[ -d "$arch_dir" ]]; then
            info "  Adding driver: $driver_name"
            cp -r "$arch_dir" "$driver_dest/$driver_name"
        fi
    done

    sudo umount "$virtio_mount"
}

inject_woa_drivers() {
    local extract_dir="$1"

    [[ "$ARCH" == "arm64" ]] || return 0
    [[ -n "$WOA_DRIVERS" ]] || return 0

    info "Injecting Windows on ARM drivers"

    local driver_dest="$extract_dir/\$WinPEDriver\$/woa"
    mkdir -p "$driver_dest"
    cp -r "$WOA_DRIVERS"/. "$driver_dest"/

    info "WOA drivers injected"
}

# --- Answer file generation ---

generate_answer_file() {
    local extract_dir="$1"
    local answer_file="$extract_dir/autounattend.xml"

    local template="$PIPELINE_DIR/answer-files/autounattend-${ARCH}.xml"
    if [[ -f "$template" ]]; then
        info "Using architecture-specific answer file template"
        cp "$template" "$answer_file"
    else
        info "Generating unattended answer file"
        cat > "$answer_file" <<'XMLEOF'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend"
          xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE"
               processorArchitecture="__ARCH__"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <SetupUILanguage>
        <UILanguage>en-US</UILanguage>
      </SetupUILanguage>
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup"
               processorArchitecture="__ARCH__"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add">
              <Order>1</Order>
              <Type>EFI</Type>
              <Size>260</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>2</Order>
              <Type>MSR</Type>
              <Size>128</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>3</Order>
              <Type>Primary</Type>
              <Extend>true</Extend>
            </CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add">
              <Order>1</Order>
              <PartitionID>1</PartitionID>
              <Format>FAT32</Format>
              <Label>EFI</Label>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>2</Order>
              <PartitionID>2</PartitionID>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>3</Order>
              <PartitionID>3</PartitionID>
              <Format>NTFS</Format>
              <Label>Windows</Label>
            </ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>
      <ImageInstall>
        <OSImage>
          <InstallTo>
            <DiskID>0</DiskID>
            <PartitionID>3</PartitionID>
          </InstallTo>
        </OSImage>
      </ImageInstall>
      <UserData>
        <AcceptEula>true</AcceptEula>
      </UserData>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Deployment"
               processorArchitecture="__ARCH__"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Path>cmd /c reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f</Path>
          <Description>Enable RDP</Description>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Path>cmd /c netsh advfirewall firewall set rule group="Remote Desktop" new enable=yes</Path>
          <Description>Allow RDP through firewall</Description>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="__ARCH__"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>User</Name>
            <Group>Administrators</Group>
            <Password>
              <Value></Value>
              <PlainText>true</PlainText>
            </Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>User</Username>
        <Password>
          <Value></Value>
          <PlainText>true</PlainText>
        </Password>
        <LogonCount>1</LogonCount>
      </AutoLogon>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <CommandLine>powershell -Command "Set-ExecutionPolicy RemoteSigned -Force"</CommandLine>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
XMLEOF

        # Replace architecture placeholder
        local xml_arch
        [[ "$ARCH" == "x86_64" ]] && xml_arch="amd64" || xml_arch="arm64"
        sed -i "s/__ARCH__/$xml_arch/g" "$answer_file"
    fi

    info "Answer file written"
}

# --- Guest tools preparation ---

prepare_guest_tools() {
    local extract_dir="$1"
    local tools_dir="$extract_dir/\$OEM\$/\$1/iwt"
    mkdir -p "$tools_dir"

    info "Preparing guest tools bundle"

    # Create a post-install script that will be run on first boot
    cat > "$tools_dir/setup-guest-tools.ps1" <<'PS1EOF'
# IWT Guest Tools Setup
# Runs on first boot to configure the Windows guest for Incus integration.

$ErrorActionPreference = "Stop"

Write-Host "IWT: Configuring guest tools..."

# Enable incus-agent service if present
$agentPath = "C:\Program Files\incus-agent\incus-agent.exe"
if (Test-Path $agentPath) {
    Write-Host "IWT: incus-agent found, ensuring service is running"
    Start-Service -Name "incus-agent" -ErrorAction SilentlyContinue
}

# Install WinFsp if the MSI is bundled
$winfspMsi = Join-Path $PSScriptRoot "winfsp.msi"
if (Test-Path $winfspMsi) {
    Write-Host "IWT: Installing WinFsp for filesystem passthrough"
    Start-Process msiexec.exe -ArgumentList "/i `"$winfspMsi`" /qn" -Wait
}

# Configure RemoteApp registry keys for seamless app integration
$raKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server\TSAppAllowList"
if (-not (Test-Path $raKey)) {
    New-Item -Path $raKey -Force | Out-Null
}
Set-ItemProperty -Path $raKey -Name "fDisabledAllowList" -Value 1 -Type DWord

# Allow RemoteApp from any source
$customRDP = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
if (-not (Test-Path $customRDP)) {
    New-Item -Path $customRDP -Force | Out-Null
}

Write-Host "IWT: Guest tools setup complete"
PS1EOF

    info "Guest tools prepared"
}

# --- Disk image creation ---

create_disk_image() {
    local extract_dir="$1"

    info "Creating ${DISK_SIZE} QCOW2 disk image: $OUTPUT"
    qemu-img create -f qcow2 "$OUTPUT" "$DISK_SIZE"

    # Repack the modified ISO
    local modified_iso="$WORK_DIR/windows-modified.iso"
    info "Repacking modified ISO"
    mkisofs -b boot/etfsboot.com -no-emul-boot -boot-load-size 8 \
        -iso-level 4 -udf -o "$modified_iso" "$extract_dir" 2>/dev/null || \
    xorriso -as mkisofs \
        -iso-level 3 -udf \
        -b boot/etfsboot.com -no-emul-boot -boot-load-size 8 \
        -eltorito-alt-boot -b efi/microsoft/boot/efisys.bin -no-emul-boot \
        -o "$modified_iso" "$extract_dir"

    info "Disk image created: $OUTPUT"
    info "Modified ISO created: $modified_iso"
    info ""
    info "To install, run the VM with:"
    info "  incus launch windows --vm --empty"
    info "  incus config device add windows install disk source=$modified_iso"
    info "  incus config device add windows disk0 disk source=$OUTPUT"
    info ""
    info "Or use: iwt vm create --image $modified_iso --disk $OUTPUT"
}

# --- Main ---

main() {
    parse_args "$@"

    require_cmd qemu-img curl

    # Prefer wimlib tools for WIM manipulation
    if [[ "$SLIM" == true ]]; then
        require_cmd wimlib-imagex
    fi

    WORK_DIR=$(mktemp -d -t iwt-build-XXXXXX)
    info "Work directory: $WORK_DIR"
    info "Architecture: $ARCH"
    info "Edition: $EDITION"
    info "Slim: $SLIM"
    info "Output: $OUTPUT"

    # Step 1: Extract ISO
    local extract_dir
    extract_dir=$(extract_iso)

    # Step 2: Slim (optional)
    if [[ "$SLIM" == true ]]; then
        slim_image "$extract_dir"
    fi

    # Step 3: Inject drivers
    if [[ "$INJECT_DRIVERS" == true ]]; then
        inject_virtio_drivers "$extract_dir"
        inject_woa_drivers "$extract_dir"
    fi

    # Step 4: Generate answer file
    generate_answer_file "$extract_dir"

    # Step 5: Prepare guest tools
    prepare_guest_tools "$extract_dir"

    # Step 6: Create disk image + repack ISO
    create_disk_image "$extract_dir"

    info "Build complete."
}

main "$@"
