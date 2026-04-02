# bdfs-mount-shares.ps1
# Mount bdfs virtiofs shares exposed by IWT as Windows drive letters.
#
# IWT exposes bdfs blend namespaces to Windows VMs via virtio-fs. This script
# discovers those shares and mounts them using WinFsp's net use integration.
#
# Usage (run inside the Windows VM):
#   .\bdfs-mount-shares.ps1                        # auto-assign drive letters
#   .\bdfs-mount-shares.ps1 -ShareName win-data -DriveLetter Z
#   .\bdfs-mount-shares.ps1 -List                  # list known bdfs shares
#   .\bdfs-mount-shares.ps1 -Unmount Z             # unmount drive Z
#
# Requirements: WinFsp + VirtIO-FS driver (installed by iwt vm setup-guest)

param(
    [string]$ShareName   = "",
    [string]$DriveLetter = "",
    [switch]$List,
    [string]$Unmount     = "",
    [switch]$All,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- Helpers ---

function Write-IwtInfo  { param([string]$msg) if (-not $Quiet) { Write-Host ":: $msg" -ForegroundColor Cyan } }
function Write-IwtOk    { param([string]$msg) if (-not $Quiet) { Write-Host "OK $msg" -ForegroundColor Green } }
function Write-IwtWarn  { param([string]$msg) Write-Warning $msg }
function Write-IwtError { param([string]$msg) Write-Error   $msg }

# Detect WinFsp installation
function Get-WinFspPath {
    $candidates = @(
        "C:\Program Files\WinFsp\bin\winfsp-x64.dll",
        "C:\Program Files (x86)\WinFsp\bin\winfsp-x86.dll"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return (Split-Path $c -Parent) }
    }
    return $null
}

# Discover virtio-fs shares that were attached by bdfs-share.
# virtio-fs shares appear as network providers under \\wsl.localhost\<name>
# or as UNC paths via the VirtioFsSvc service tag.
function Get-BdfsShares {
    $shares = @()

    # Method 1: query VirtioFsSvc for mounted tags
    $svc = Get-Service -Name "VirtioFsSvc" -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") {
        # VirtIO-FS tags are exposed as \\.\VirtioFsTag\<tag>
        # Enumerate via WMI or registry
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\VirtioFsSvc\Parameters"
        if (Test-Path $regPath) {
            $tags = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
            if ($tags -and $tags.PSObject.Properties["Tags"]) {
                foreach ($tag in ($tags.Tags -split ",")) {
                    $tag = $tag.Trim()
                    if ($tag) { $shares += $tag }
                }
            }
        }
    }

    # Method 2: check IWT share state file pushed by bdfs-share
    $stateFile = "C:\ProgramData\IWT\bdfs-shares.txt"
    if (Test-Path $stateFile) {
        foreach ($line in (Get-Content $stateFile)) {
            $line = $line.Trim()
            if ($line -and $line -notmatch "^#") {
                $parts = $line -split "\|"
                if ($parts.Count -ge 1 -and $parts[0] -notin $shares) {
                    $shares += $parts[0]
                }
            }
        }
    }

    return $shares
}

# Pick the next free drive letter starting from Z downward
function Get-NextFreeDriveLetter {
    $used = (Get-PSDrive -PSProvider FileSystem | Select-Object -ExpandProperty Name)
    foreach ($letter in "ZYXWVUTSRQPONMLKJIH".ToCharArray()) {
        if ($letter -notin $used) { return "$letter" }
    }
    throw "No free drive letters available"
}

# Mount a single virtio-fs share via net use
function Mount-BdfsShare {
    param([string]$Tag, [string]$Letter)

    if (-not $Letter) { $Letter = Get-NextFreeDriveLetter }
    $Letter = $Letter.TrimEnd(':').ToUpper()

    # Check if already mounted
    $existing = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayRoot -like "*$Tag*" }
    if ($existing) {
        Write-IwtWarn "Share '$Tag' already mounted at $($existing.Name):"
        return $existing.Name
    }

    Write-IwtInfo "Mounting bdfs share '$Tag' as ${Letter}:\ ..."

    # VirtIO-FS shares are accessible via the WinFsp network provider
    # UNC path: \\.\VirtioFsTag\<tag>  (driver-level)
    # Fallback: \\wsl.localhost\<tag>  (WSL2 provider, works on some configs)
    $unc = "\\.\VirtioFsTag\$Tag"

    $result = & net use "${Letter}:" "$unc" /persistent:yes 2>&1
    if ($LASTEXITCODE -ne 0) {
        # Fallback to wsl.localhost provider
        $unc = "\\wsl.localhost\$Tag"
        $result = & net use "${Letter}:" "$unc" /persistent:yes 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-IwtError "Failed to mount '$Tag': $result"
            return $null
        }
    }

    Write-IwtOk "Mounted '$Tag' at ${Letter}:\"
    return $Letter
}

# Unmount a drive letter
function Unmount-BdfsDrive {
    param([string]$Letter)
    $Letter = $Letter.TrimEnd(':').ToUpper()
    Write-IwtInfo "Unmounting ${Letter}:\ ..."
    $result = & net use "${Letter}:" /delete /yes 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-IwtError "Failed to unmount ${Letter}: $result"
    } else {
        Write-IwtOk "Unmounted ${Letter}:\"
    }
}

# --- Main ---

if (-not (Get-WinFspPath)) {
    Write-IwtError "WinFsp not found. Install it first: iwt vm setup-guest --vm <name> --install-winfsp"
    exit 1
}

if ($Unmount) {
    Unmount-BdfsDrive -Letter $Unmount
    exit 0
}

$shares = Get-BdfsShares

if ($List) {
    Write-IwtInfo "Known bdfs shares on this VM:"
    if ($shares.Count -eq 0) {
        Write-Host "  (none found)"
    } else {
        foreach ($s in $shares) {
            $mounted = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
                       Where-Object { $_.DisplayRoot -like "*$s*" }
            $status = if ($mounted) { "mounted at $($mounted.Name):" } else { "not mounted" }
            Write-Host "  $s  [$status]"
        }
    }
    exit 0
}

if ($ShareName) {
    # Mount a specific named share
    Mount-BdfsShare -Tag $ShareName -Letter $DriveLetter
    exit 0
}

if ($All -or (-not $ShareName -and -not $DriveLetter)) {
    # Auto-mount all discovered shares
    if ($shares.Count -eq 0) {
        Write-IwtInfo "No bdfs shares found on this VM."
        exit 0
    }
    Write-IwtInfo "Auto-mounting $($shares.Count) bdfs share(s)..."
    foreach ($s in $shares) {
        Mount-BdfsShare -Tag $s -Letter ""
    }
    exit 0
}
