#!/usr/bin/env bash
# Build a Windows image for Incus with optional slimming and driver injection.
#
# Usage:
#   build-image.sh [options]
#
# Options:
#   --iso PATH          Path to Windows ISO (required)
#   --arch ARCH         Target architecture: x86_64 | arm64 (default: auto-detect)
#   --edition EDITION   Windows edition to install (default: Pro)
#   --slim              Strip bloatware packages (tiny11-style)
#   --output PATH       Output image path (default: windows-<arch>.qcow2)
#   --inject-drivers    Inject VirtIO + platform drivers into the image
#   --woa-drivers PATH  Path to WOA-Drivers directory (ARM only)
#   --size SIZE         Disk image size (default: 64G)
#   --keep-work         Don't delete the work directory on exit
#   --help              Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(dirname "$SCRIPT_DIR")"

# Find and source shared library
IWT_ROOT="$(cd "$PIPELINE_DIR/.." && pwd)"
source "$IWT_ROOT/cli/lib.sh"

WORK_DIR=""
KEEP_WORK=false

# Defaults
ARCH=""
EDITION="Pro"
SLIM=false
INJECT_DRIVERS=true
ISO_PATH=""
OUTPUT=""
WOA_DRIVERS=""
DISK_SIZE="${IWT_DISK_SIZE:-64G}"

# Load user config if present
load_config

# --- Cleanup ---

cleanup() {
    # Unmount anything we may have left mounted
    for mp in "$WORK_DIR"/iso_mount "$WORK_DIR"/wim_mount "$WORK_DIR"/virtio_mount; do
        if [[ -n "$mp" ]] && mountpoint -q "$mp" 2>/dev/null; then
            warn "Cleaning up stale mount: $mp"
            sudo umount "$mp" 2>/dev/null || true
        fi
    done

    if [[ "$KEEP_WORK" == true && -n "$WORK_DIR" ]]; then
        info "Work directory preserved: $WORK_DIR"
        return
    fi

    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        info "Cleaning up work directory"
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

usage() {
    sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
    exit 0
}

# --- Argument parsing ---

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --iso)            ISO_PATH="$2"; shift 2 ;;
            --arch)           ARCH="$2"; shift 2 ;;
            --edition)        EDITION="$2"; shift 2 ;;
            --slim)           SLIM=true; shift ;;
            --output)         OUTPUT="$2"; shift 2 ;;
            --inject-drivers) INJECT_DRIVERS=true; shift ;;
            --woa-drivers)    WOA_DRIVERS="$2"; shift 2 ;;
            --size)           DISK_SIZE="$2"; shift 2 ;;
            --keep-work)      KEEP_WORK=true; shift ;;
            --help)           usage ;;
            *)                die "Unknown option: $1" ;;
        esac
    done

    [[ -n "$ISO_PATH" ]] || die "--iso is required"
    [[ -f "$ISO_PATH" ]] || die "ISO not found: $ISO_PATH"

    # Auto-detect architecture from host if not specified
    if [[ -z "$ARCH" ]]; then
        ARCH=$(detect_arch)
        info "Auto-detected architecture: $ARCH"
    fi

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
    local mount_point="$WORK_DIR/iso_mount"
    local extract_dir="$WORK_DIR/iso_extracted"

    mkdir -p "$mount_point" "$extract_dir"

    sudo mount -o loop,ro "$ISO_PATH" "$mount_point"
    cp -a "$mount_point"/. "$extract_dir"/
    sudo umount "$mount_point"

    chmod -R u+w "$extract_dir"

    echo "$extract_dir"
}

# --- Bloatware removal (tiny11-style) ---

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

    local wim_mount="$WORK_DIR/wim_mount"
    mkdir -p "$wim_mount"

    # Find the index for the requested edition
    local index
    index=$(wiminfo "$install_wim" | grep -B1 "Name:.*$EDITION" | grep "Index:" | awk '{print $2}' | head -1)
    if [[ -z "$index" ]]; then
        err "Edition '$EDITION' not found in install.wim. Available editions:"
        wiminfo "$install_wim" | grep "Name:" >&2
        exit 1
    fi

    info "Mounting install.wim (index $index, edition: $EDITION)"
    sudo wimlib-imagex mountrw "$install_wim" "$index" "$wim_mount"

    local removed=0
    for pkg in "${SLIM_PACKAGES[@]}"; do
        local pkg_dirs
        pkg_dirs=$(find "$wim_mount/Program Files/WindowsApps" -maxdepth 1 -name "${pkg}_*" -type d 2>/dev/null || true)
        if [[ -n "$pkg_dirs" ]]; then
            while IFS= read -r pkg_dir; do
                info "  Removing: $(basename "$pkg_dir")"
                sudo rm -rf "$pkg_dir"
                removed=$((removed + 1))
            done <<< "$pkg_dirs"
        fi
    done

    # Deprovision via registry to prevent re-install on first login
    if command -v hivexsh &>/dev/null; then
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
        warn "hivexsh not found; skipping registry cleanup (packages may re-provision)"
    fi

    sudo wimlib-imagex unmount --commit "$wim_mount"
    ok "Removed $removed bloatware packages"
}

# --- Driver injection ---

download_virtio_iso() {
    local virtio_url="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso"
    cached_download "$virtio_url" "virtio-win.iso"
}

inject_virtio_drivers() {
    local extract_dir="$1"

    local virtio_iso
    virtio_iso=$(download_virtio_iso)

    local virtio_mount="$WORK_DIR/virtio_mount"
    mkdir -p "$virtio_mount"
    sudo mount -o loop,ro "$virtio_iso" "$virtio_mount"

    local driver_dest="$extract_dir/\$WinPEDriver\$"
    mkdir -p "$driver_dest"

    local win_arch
    win_arch=$(arch_to_windows "$ARCH")

    local injected=0
    for driver_dir in "$virtio_mount"/*/; do
        local driver_name
        driver_name=$(basename "$driver_dir")
        local arch_dir=""

        # Try Windows 11, then Server 2022, then Server 2019
        for win_ver in w11 2k22 2k19; do
            if [[ -d "$driver_dir/$win_ver/$win_arch" ]]; then
                arch_dir="$driver_dir/$win_ver/$win_arch"
                break
            fi
        done

        if [[ -n "$arch_dir" ]]; then
            info "  Adding driver: $driver_name"
            cp -r "$arch_dir" "$driver_dest/$driver_name"
            injected=$((injected + 1))
        fi
    done

    # Also inject any custom drivers from the drivers/ directory
    local custom_drivers="$PIPELINE_DIR/drivers/custom"
    if [[ -d "$custom_drivers" ]] && [[ -n "$(ls -A "$custom_drivers" 2>/dev/null)" ]]; then
        info "Injecting custom drivers from $custom_drivers"
        cp -r "$custom_drivers"/. "$driver_dest/"
        injected=$((injected + $(find "$custom_drivers" -maxdepth 1 -mindepth 1 -type d | wc -l)))
    fi

    sudo umount "$virtio_mount"
    ok "Injected $injected driver packages"
}

inject_woa_drivers() {
    local extract_dir="$1"

    [[ "$ARCH" == "arm64" ]] || return 0
    [[ -n "$WOA_DRIVERS" ]] || return 0

    local driver_dest="$extract_dir/\$WinPEDriver\$/woa"
    mkdir -p "$driver_dest"
    cp -r "$WOA_DRIVERS"/. "$driver_dest"/

    local count
    count=$(find "$driver_dest" -name '*.inf' | wc -l)
    ok "Injected $count WOA driver INF files"
}

# --- Answer file generation ---

generate_answer_file() {
    local extract_dir="$1"
    local answer_file="$extract_dir/autounattend.xml"

    # Check for user-provided template first
    local template="$PIPELINE_DIR/answer-files/autounattend-${ARCH}.xml"
    if [[ -f "$template" ]]; then
        info "Using architecture-specific answer file template"
        cp "$template" "$answer_file"
        return
    fi

    local xml_arch
    xml_arch=$(arch_to_windows "$ARCH")

    cat > "$answer_file" <<XMLEOF
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend"
          xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE"
               processorArchitecture="${xml_arch}"
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
               processorArchitecture="${xml_arch}"
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
               processorArchitecture="${xml_arch}"
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
               processorArchitecture="${xml_arch}"
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
          <CommandLine>powershell -ExecutionPolicy Bypass -File C:\iwt\setup-guest-tools.ps1</CommandLine>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
XMLEOF

    ok "Answer file generated"
}

# --- Guest tools preparation ---

prepare_guest_tools() {
    local extract_dir="$1"
    local tools_dir="$extract_dir/\$OEM\$/\$1/iwt"
    mkdir -p "$tools_dir"

    cat > "$tools_dir/setup-guest-tools.ps1" <<'PS1EOF'
# IWT Guest Tools Setup
# Runs on first boot to configure the Windows guest for Incus integration.

$ErrorActionPreference = "Stop"
$logFile = "C:\iwt\setup.log"

function Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts  $msg" | Tee-Object -FilePath $logFile -Append
}

Log "IWT: Starting guest tools setup"

# Enable incus-agent service if present
$agentPath = "C:\Program Files\incus-agent\incus-agent.exe"
if (Test-Path $agentPath) {
    Log "IWT: incus-agent found, ensuring service is running"
    Start-Service -Name "incus-agent" -ErrorAction SilentlyContinue
}

# Install WinFsp if the MSI is bundled
$winfspMsi = Join-Path $PSScriptRoot "winfsp.msi"
if (Test-Path $winfspMsi) {
    Log "IWT: Installing WinFsp for filesystem passthrough"
    $proc = Start-Process msiexec.exe -ArgumentList "/i `"$winfspMsi`" /qn" -Wait -PassThru
    Log "IWT: WinFsp install exit code: $($proc.ExitCode)"
}

# Configure RemoteApp -- allow all apps to be launched via RemoteApp
$raKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server\TSAppAllowList"
if (-not (Test-Path $raKey)) {
    New-Item -Path $raKey -Force | Out-Null
}
Set-ItemProperty -Path $raKey -Name "fDisabledAllowList" -Value 1 -Type DWord
Log "IWT: RemoteApp allow-all configured"

# Disable Windows Update automatic restart
$wuKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
if (-not (Test-Path $wuKey)) {
    New-Item -Path $wuKey -Force | Out-Null
}
Set-ItemProperty -Path $wuKey -Name "NoAutoRebootWithLoggedOnUsers" -Value 1 -Type DWord
Log "IWT: Disabled auto-restart for Windows Update"

# Enable long paths
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name "LongPathsEnabled" -Value 1 -Type DWord

# Disable hibernation (saves disk space in VM)
& powercfg /hibernate off 2>$null

# Create shared folder mount helper script
$mountScript = @'
# IWT Shared Folder Mount Helper
# Run this to mount virtiofs/9p shares as drive letters.
# Usage: iwt-mount-shares.ps1 [share_name] [drive_letter]
#
# Without arguments, reads C:\iwt\shares.conf for mappings.

param(
    [string]$ShareName,
    [string]$DriveLetter
)

$logFile = "C:\iwt\mount.log"
function Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts  $msg" | Tee-Object -FilePath $logFile -Append
}

function Mount-Share($name, $letter) {
    $letter = $letter.ToUpper().TrimEnd(':')

    # Skip if already mounted
    if (Test-Path "${letter}:\") {
        Log "IWT: ${letter}: already mounted, skipping"
        return
    }

    # Try virtiofs
    $virtiofsExe = "C:\Program Files\VirtIO-FS\virtiofs.exe"
    if (Test-Path $virtiofsExe) {
        Log "IWT: Mounting $name as ${letter}: via VirtIO-FS"
        & $virtiofsExe -o "uid=-1,gid=-1" -o "volname=$name" "${letter}:" 2>$null
        if ($LASTEXITCODE -eq 0) { return }
    }

    # Try net use (agent share)
    try {
        net use "${letter}:" "\\localhost\$name" /persistent:yes 2>$null
        if ($LASTEXITCODE -eq 0) {
            Log "IWT: Mounted $name as ${letter}: via net use"
            return
        }
    } catch {}

    # Try subst (local path)
    $localPath = "C:\shared\$name"
    if (Test-Path $localPath) {
        subst "${letter}:" $localPath
        Log "IWT: Mounted $name as ${letter}: via subst"
        return
    }

    Log "IWT: WARNING - Could not mount $name as ${letter}:"
}

if ($ShareName -and $DriveLetter) {
    Mount-Share $ShareName $DriveLetter
} else {
    $confFile = "C:\iwt\shares.conf"
    if (Test-Path $confFile) {
        Get-Content $confFile | ForEach-Object {
            $line = $_.Trim()
            if ($line -and -not $line.StartsWith('#')) {
                $parts = $line -split '\|'
                if ($parts.Count -ge 2) {
                    Mount-Share $parts[0].Trim() $parts[1].Trim()
                }
            }
        }
    }
}
'@

$mountScriptPath = Join-Path $PSScriptRoot "iwt-mount-shares.ps1"
Set-Content -Path $mountScriptPath -Value $mountScript
Log "IWT: Shared folder mount helper installed"

# Register mount helper as a startup task so shares auto-mount on login
$taskAction = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$mountScriptPath`""
$taskTrigger = New-ScheduledTaskTrigger -AtLogOn
$taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName "IWT-MountShares" -Action $taskAction `
    -Trigger $taskTrigger -Settings $taskSettings `
    -Description "Auto-mount IWT shared folders" -Force 2>$null
Log "IWT: Auto-mount scheduled task registered"

Log "IWT: Guest tools setup complete"
PS1EOF

    # Bundle VirtIO guest tools installer if cached
    local guest_tools_exe
    guest_tools_exe=$(find "$IWT_CACHE_DIR" -name 'virtio-win-guest-tools*' -print -quit 2>/dev/null || true)
    if [[ -n "$guest_tools_exe" && -f "$guest_tools_exe" ]]; then
        cp "$guest_tools_exe" "$tools_dir/virtio-win-guest-tools.exe"
        info "Bundled VirtIO guest tools installer"

        # Add auto-install to the setup script
        cat >> "$tools_dir/setup-guest-tools.ps1" <<'PS1VIRTIO'

# Install VirtIO guest tools (balloon, serial, QEMU agent)
$virtioInstaller = Join-Path $PSScriptRoot "virtio-win-guest-tools.exe"
if (Test-Path $virtioInstaller) {
    Log "IWT: Installing VirtIO guest tools..."
    $proc = Start-Process $virtioInstaller -ArgumentList "/install /quiet /norestart" -Wait -PassThru
    Log "IWT: VirtIO guest tools install exit code: $($proc.ExitCode)"
}
PS1VIRTIO
    else
        info "VirtIO guest tools not cached; run 'iwt image drivers download' to include them"
    fi

    ok "Guest tools prepared"
}

# --- Disk image creation ---

create_disk_image() {
    local extract_dir="$1"

    qemu-img create -f qcow2 "$OUTPUT" "$DISK_SIZE"
    ok "Created ${DISK_SIZE} QCOW2 disk: $OUTPUT"

    # Repack the modified ISO
    local modified_iso="$WORK_DIR/windows-modified.iso"

    if command -v xorriso &>/dev/null; then
        xorriso -as mkisofs \
            -iso-level 3 -udf \
            -b boot/etfsboot.com -no-emul-boot -boot-load-size 8 \
            -eltorito-alt-boot -b efi/microsoft/boot/efisys.bin -no-emul-boot \
            -o "$modified_iso" "$extract_dir" 2>&1 | tail -3
    elif command -v mkisofs &>/dev/null; then
        mkisofs -b boot/etfsboot.com -no-emul-boot -boot-load-size 8 \
            -iso-level 4 -udf -o "$modified_iso" "$extract_dir" 2>&1 | tail -3
    else
        die "Neither xorriso nor mkisofs found. Install one of them."
    fi

    # Copy modified ISO next to the output image
    local final_iso
    final_iso="$(dirname "$OUTPUT")/$(basename "$OUTPUT" .qcow2)-install.iso"
    mv "$modified_iso" "$final_iso"

    local iso_size
    iso_size=$(stat -c%s "$final_iso" 2>/dev/null || stat -f%z "$final_iso" 2>/dev/null || echo "0")

    ok "Modified ISO: $final_iso ($(human_size "$iso_size"))"
    echo ""
    bold "Next steps:"
    echo "  iwt vm create --name win11 --image $final_iso --disk $OUTPUT"
    echo "  iwt vm start win11"
}

# --- Main ---

main() {
    parse_args "$@"

    # Determine required tools based on options
    local required_cmds=(qemu-img curl)
    if [[ "$SLIM" == true ]]; then
        required_cmds+=(wimlib-imagex)
    fi
    require_cmd "${required_cmds[@]}"

    # Check for ISO repacking tool
    if ! command -v xorriso &>/dev/null && ! command -v mkisofs &>/dev/null; then
        die "Neither xorriso nor mkisofs found. Install one of them."
    fi

    WORK_DIR=$(mktemp -d -t iwt-build-XXXXXX)

    # Count steps for progress
    local total=4
    [[ "$SLIM" == true ]] && total=$((total + 1))
    [[ "$INJECT_DRIVERS" == true ]] && total=$((total + 1))
    progress_init "$total"

    echo ""
    bold "IWT Image Build"
    info "ISO:        $ISO_PATH"
    info "Arch:       $ARCH"
    info "Edition:    $EDITION"
    info "Slim:       $SLIM"
    info "Drivers:    $INJECT_DRIVERS"
    info "Disk size:  $DISK_SIZE"
    info "Output:     $OUTPUT"
    info "Work dir:   $WORK_DIR"
    echo ""

    progress_step "Extracting ISO"
    local extract_dir
    extract_dir=$(extract_iso)

    if [[ "$SLIM" == true ]]; then
        progress_step "Slimming image (removing bloatware)"
        slim_image "$extract_dir"
    fi

    if [[ "$INJECT_DRIVERS" == true ]]; then
        progress_step "Injecting drivers"
        inject_virtio_drivers "$extract_dir"
        inject_woa_drivers "$extract_dir"
    fi

    progress_step "Generating answer file"
    generate_answer_file "$extract_dir"

    progress_step "Preparing guest tools"
    prepare_guest_tools "$extract_dir"

    progress_step "Creating disk image and repacking ISO"
    create_disk_image "$extract_dir"

    echo ""
    ok "Build complete."
}

main "$@"
