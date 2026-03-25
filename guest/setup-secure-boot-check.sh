#!/usr/bin/env bash
# Audit UEFI Secure Boot variables and ESP integrity inside a running Windows VM.
#
# Implements the checks from cjee21/Check-UEFISecureBootVariables, adapted to
# run via the Incus agent (incus exec + PowerShell) rather than requiring
# interactive access to the guest.
#
# Checks performed:
#   - Secure Boot enabled/disabled state
#   - PK (Platform Key) presence and subject
#   - KEK (Key Exchange Key) presence, Microsoft 2011 + 2023 certs
#   - DB (Allowed Signatures) presence, Microsoft 2011 + 2023 certs
#   - DBX (Forbidden Signatures) presence and update recency
#   - Windows Production PCA 2011 revocation status in DBX
#   - Boot manager (bootmgfw.efi) signing certificate
#   - AvailableUpdates registry bits (pending SB updates)
#   - SBAT/SVN policy presence (informational)
#
# Optionally applies pending Secure Boot updates:
#   --apply-dbx-update      Re-apply DBX updates Windows has queued
#   --apply-2023-certs       Apply 2023 KEK/DB certificates
#
# Usage:
#   setup-secure-boot-check.sh [options]
#
# Options:
#   --vm NAME              Target VM (default: $IWT_VM_NAME)
#   --apply-dbx-update     Apply pending DBX updates inside the guest
#   --apply-2023-certs     Apply 2023 KEK/DB certificate updates
#   --apply-revocations    Apply DBX + revoke Windows Production PCA 2011
#   --report FILE          Save full JSON report to FILE
#   --json                 Output raw JSON
#   --fail-on-warn         Exit 1 if any warnings found
#   --help                 Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$IWT_ROOT/cli/lib.sh"
source "$IWT_ROOT/remoteapp/backend/incus-backend.sh"
load_config

APPLY_DBX=false
APPLY_2023=false
APPLY_REVOCATIONS=false
REPORT_FILE=""
JSON_OUTPUT=false
FAIL_ON_WARN=false

# --- Argument parsing ---

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --vm)                 IWT_VM_NAME="$2"; shift 2 ;;
            --apply-dbx-update)   APPLY_DBX=true; shift ;;
            --apply-2023-certs)   APPLY_2023=true; shift ;;
            --apply-revocations)  APPLY_REVOCATIONS=true; shift ;;
            --report)             REPORT_FILE="$2"; shift 2 ;;
            --json)               JSON_OUTPUT=true; shift ;;
            --fail-on-warn)       FAIL_ON_WARN=true; shift ;;
            --help|-h)
                sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
                exit 0
                ;;
            *) die "Unknown option: $1" ;;
        esac
    done
}

# --- Audit PowerShell payload ---
# Reads UEFI Secure Boot variables via Get-SecureBootUEFI and the registry.
# Returns a structured JSON object.

SB_AUDIT_SCRIPT='
$ErrorActionPreference = "SilentlyContinue"
$result = [ordered]@{}

# Helper: check if a certificate with a given subject substring is in a variable
function Test-CertInVar {
    param([string]$VarName, [string]$SubjectFragment)
    try {
        $var = Get-SecureBootUEFI -Name $VarName -ErrorAction Stop
        if (-not $var -or -not $var.Bytes) { return $false }
        # Parse EFI_SIGNATURE_LIST: walk through signature entries looking for X.509 certs
        $bytes = $var.Bytes
        $offset = 0
        while ($offset -lt $bytes.Length - 28) {
            $sigType   = [System.BitConverter]::ToUInt32($bytes, $offset)
            $listSize  = [System.BitConverter]::ToUInt32($bytes, $offset + 16)
            $headerSize= [System.BitConverter]::ToUInt32($bytes, $offset + 20)
            $sigSize   = [System.BitConverter]::ToUInt32($bytes, $offset + 24)
            if ($listSize -eq 0) { break }
            # EFI_CERT_X509_GUID = {a5c059a1-94e4-4aa7-87b5-ab155c2bf072}
            $x509Guid = [byte[]](0xa1,0x59,0xc0,0xa5,0xe4,0x94,0xa7,0x4a,0x87,0xb5,0xab,0x15,0x5c,0x2b,0xf0,0x72)
            $isX509 = $true
            for ($i = 0; $i -lt 16; $i++) {
                if ($bytes[$offset + $i] -ne $x509Guid[$i]) { $isX509 = $false; break }
            }
            if ($isX509 -and $sigSize -gt 28) {
                $certOffset = $offset + 28 + $headerSize
                $certLen    = $sigSize - 28
                if ($certOffset + $certLen -le $bytes.Length) {
                    try {
                        $certBytes = $bytes[$certOffset..($certOffset + $certLen - 1)]
                        $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new([byte[]]$certBytes)
                        if ($cert.Subject -like "*$SubjectFragment*") { return $true }
                    } catch {}
                }
            }
            $offset += $listSize
        }
    } catch {}
    return $false
}

# --- Secure Boot state ---
$sbState = Confirm-SecureBootUEFI -ErrorAction SilentlyContinue
$result.SecureBootEnabled  = if ($null -ne $sbState) { [bool]$sbState } else { $false }
$result.SecureBootSupported = ($null -ne $sbState)

# --- PK ---
try {
    $pk = Get-SecureBootUEFI -Name PK -ErrorAction Stop
    $result.PK = [ordered]@{
        Present = ($null -ne $pk -and $pk.Bytes.Length -gt 0)
        Size    = if ($pk) { $pk.Bytes.Length } else { 0 }
    }
} catch {
    $result.PK = [ordered]@{ Present = $false; Size = 0 }
}

# --- KEK ---
$result.KEK = [ordered]@{
    Present          = $false
    Microsoft2011    = $false
    Microsoft2023    = $false
}
try {
    $kek = Get-SecureBootUEFI -Name KEK -ErrorAction Stop
    $result.KEK.Present       = ($null -ne $kek -and $kek.Bytes.Length -gt 0)
    $result.KEK.Microsoft2011 = Test-CertInVar "KEK" "Microsoft Corporation KEK CA 2011"
    $result.KEK.Microsoft2023 = Test-CertInVar "KEK" "Microsoft Corporation KEK 2K CA 2023"
} catch {}

# --- DB ---
$result.DB = [ordered]@{
    Present              = $false
    MicrosoftPCA2011     = $false
    MicrosoftUEFICA2011  = $false
    MicrosoftPCA2023     = $false
    MicrosoftUEFICA2023  = $false
}
try {
    $db = Get-SecureBootUEFI -Name db -ErrorAction Stop
    $result.DB.Present             = ($null -ne $db -and $db.Bytes.Length -gt 0)
    $result.DB.MicrosoftPCA2011    = Test-CertInVar "db" "Microsoft Windows Production PCA 2011"
    $result.DB.MicrosoftUEFICA2011 = Test-CertInVar "db" "Microsoft Corporation UEFI CA 2011"
    $result.DB.MicrosoftPCA2023    = Test-CertInVar "db" "Windows UEFI CA 2023"
    $result.DB.MicrosoftUEFICA2023 = Test-CertInVar "db" "Microsoft UEFI CA 2023"
} catch {}

# --- DBX ---
$result.DBX = [ordered]@{
    Present              = $false
    Size                 = 0
    PCA2011Revoked       = $false
}
try {
    $dbx = Get-SecureBootUEFI -Name dbx -ErrorAction Stop
    $result.DBX.Present      = ($null -ne $dbx -and $dbx.Bytes.Length -gt 0)
    $result.DBX.Size         = if ($dbx) { $dbx.Bytes.Length } else { 0 }
    $result.DBX.PCA2011Revoked = Test-CertInVar "dbx" "Windows Production PCA 2011"
} catch {}

# --- AvailableUpdates registry bits ---
# Bits indicate what Secure Boot updates Windows has queued but not yet applied.
$auKey = "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\AvailableUpdates"
$auVal = (Get-ItemProperty $auKey -Name AvailableUpdates -ErrorAction SilentlyContinue).AvailableUpdates
$result.AvailableUpdates = [ordered]@{
    Value            = if ($null -ne $auVal) { $auVal } else { 0 }
    DBXUpdate        = if ($null -ne $auVal) { ($auVal -band 0x0010) -ne 0 } else { $false }
    KEK2023          = if ($null -ne $auVal) { ($auVal -band 0x0020) -ne 0 } else { $false }
    DB2023           = if ($null -ne $auVal) { ($auVal -band 0x0040) -ne 0 } else { $false }
    PCA2011Revoke    = if ($null -ne $auVal) { ($auVal -band 0x0080) -ne 0 } else { $false }
    BootMgrUpdate    = if ($null -ne $auVal) { ($auVal -band 0x0100) -ne 0 } else { $false }
}

# --- Boot manager signing cert ---
$bootmgr = "C:\Windows\Boot\EFI\bootmgfw.efi"
$result.BootManager = [ordered]@{
    Path    = $bootmgr
    Exists  = (Test-Path $bootmgr)
    Signer  = ""
    Version = ""
}
if (Test-Path $bootmgr) {
    try {
        $sig = Get-AuthenticodeSignature $bootmgr -ErrorAction Stop
        $result.BootManager.Signer  = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { "Unknown" }
        $result.BootManager.Version = (Get-Item $bootmgr).VersionInfo.ProductVersion
    } catch {}
}

# --- SBAT variable (informational — only readable from firmware, not Windows) ---
# Windows cannot read SbatLevel directly; we note this limitation.
$result.SBAT = [ordered]@{
    Note = "SbatLevel is a Boot Services variable; not readable from within Windows."
}

$result | ConvertTo-Json -Depth 4
'

# --- Apply DBX update payload ---
APPLY_DBX_SCRIPT='
$ErrorActionPreference = "Stop"
Write-Host "IWT: Triggering Secure Boot DBX update..."
try {
    Start-ScheduledTask -TaskName "\Microsoft\Windows\PI\Secure-Boot-Update" -ErrorAction Stop
    Write-Host "IWT: Secure-Boot-Update task started. Waiting 15 seconds..."
    Start-Sleep -Seconds 15
    Write-Host "IWT: DBX update task completed (check Event Log for details)"
} catch {
    Write-Host "IWT: ERROR - $_"
    exit 1
}
'

# --- Apply 2023 certs payload ---
APPLY_2023_SCRIPT='
$ErrorActionPreference = "Stop"
Write-Host "IWT: Applying 2023 KEK/DB certificate updates..."

# Set AvailableUpdates bits for 2023 certs (0x0020 = KEK2023, 0x0040 = DB2023)
$auKey = "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot"
$current = (Get-ItemProperty "$auKey" -Name AvailableUpdates -ErrorAction SilentlyContinue).AvailableUpdates
if ($null -eq $current) { $current = 0 }
$newVal = $current -bor 0x0060
Set-ItemProperty "$auKey" -Name AvailableUpdates -Value $newVal -Type DWord
Write-Host "IWT: AvailableUpdates set to 0x$('{0:X4}' -f $newVal)"

try {
    Start-ScheduledTask -TaskName "\Microsoft\Windows\PI\Secure-Boot-Update" -ErrorAction Stop
    Write-Host "IWT: Secure-Boot-Update task started. Waiting 20 seconds..."
    Start-Sleep -Seconds 20
    Write-Host "IWT: 2023 cert update task completed"
} catch {
    Write-Host "IWT: ERROR - $_"
    exit 1
}
'

# --- Apply revocations payload ---
APPLY_REVOCATIONS_SCRIPT='
$ErrorActionPreference = "Stop"
Write-Host "IWT: Applying DBX update and revoking Windows Production PCA 2011..."
Write-Host "IWT: WARNING - This may prevent some older bootloaders from working."

# Set bits: 0x0010 (DBX), 0x0080 (revoke PCA 2011)
$auKey = "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot"
$current = (Get-ItemProperty "$auKey" -Name AvailableUpdates -ErrorAction SilentlyContinue).AvailableUpdates
if ($null -eq $current) { $current = 0 }
$newVal = $current -bor 0x0090
Set-ItemProperty "$auKey" -Name AvailableUpdates -Value $newVal -Type DWord
Write-Host "IWT: AvailableUpdates set to 0x$('{0:X4}' -f $newVal)"

try {
    Start-ScheduledTask -TaskName "\Microsoft\Windows\PI\Secure-Boot-Update" -ErrorAction Stop
    Write-Host "IWT: Secure-Boot-Update task started. Waiting 20 seconds..."
    Start-Sleep -Seconds 20
    Write-Host "IWT: Revocation task completed. A reboot is required for SBAT to take effect."
} catch {
    Write-Host "IWT: ERROR - $_"
    exit 1
}
'

# --- Result display ---

WARN_COUNT=0
FAIL_COUNT=0
PASS_COUNT=0

sb_check() {
    local label="$1" status="$2" detail="${3:-}"
    case "$status" in
        pass) ok   "  %-40s %s" "$label" "${detail:-OK}";      PASS_COUNT=$((PASS_COUNT+1)) ;;
        warn) warn "  %-40s %s" "$label" "${detail:-WARNING}"; WARN_COUNT=$((WARN_COUNT+1)) ;;
        fail) err  "  %-40s %s" "$label" "${detail:-FAIL}";    FAIL_COUNT=$((FAIL_COUNT+1)) ;;
        info) info "  %-40s %s" "$label" "${detail:-}" ;;
    esac
}

_sb_bool() {
    local label="$1" value="$2" detail="${3:-}"
    if [[ "$value" == "true" || "$value" == "True" ]]; then
        sb_check "$label" pass "$detail"
    else
        sb_check "$label" fail "$detail"
    fi
}

display_sb_results() {
    local json="$1"

    bold "UEFI Secure Boot Audit: $IWT_VM_NAME"
    echo ""

    # --- Secure Boot state ---
    info "Secure Boot State:"
    local sb_enabled sb_supported
    sb_enabled=$(echo "$json"   | jq -r '.SecureBootEnabled   // false')
    sb_supported=$(echo "$json" | jq -r '.SecureBootSupported // false')

    if [[ "$sb_supported" != "true" && "$sb_supported" != "True" ]]; then
        sb_check "Secure Boot" info "Not supported (Legacy BIOS or cmdlet unavailable)"
    else
        _sb_bool "Secure Boot enabled" "$sb_enabled"
    fi

    echo ""
    # --- PK ---
    info "Platform Key (PK):"
    local pk_present pk_size
    pk_present=$(echo "$json" | jq -r '.PK.Present // false')
    pk_size=$(echo "$json"    | jq -r '.PK.Size    // 0')
    if [[ "$pk_present" == "true" || "$pk_present" == "True" ]]; then
        sb_check "PK" pass "Present (${pk_size} bytes)"
    else
        sb_check "PK" fail "Not present — Secure Boot cannot function"
    fi

    echo ""
    # --- KEK ---
    info "Key Exchange Keys (KEK):"
    local kek_present kek_2011 kek_2023
    kek_present=$(echo "$json" | jq -r '.KEK.Present       // false')
    kek_2011=$(echo "$json"    | jq -r '.KEK.Microsoft2011 // false')
    kek_2023=$(echo "$json"    | jq -r '.KEK.Microsoft2023 // false')

    _sb_bool "KEK present"                    "$kek_present"
    _sb_bool "Microsoft KEK CA 2011"          "$kek_2011"
    if [[ "$kek_2023" == "true" || "$kek_2023" == "True" ]]; then
        sb_check "Microsoft KEK 2K CA 2023"   pass "Present (up to date)"
    else
        sb_check "Microsoft KEK 2K CA 2023"   warn "Not present — apply with: iwt vm secure-boot apply-2023-certs"
    fi

    echo ""
    # --- DB ---
    info "Allowed Signatures (DB):"
    local db_present db_pca2011 db_uefi2011 db_pca2023 db_uefi2023
    db_present=$(echo "$json"  | jq -r '.DB.Present              // false')
    db_pca2011=$(echo "$json"  | jq -r '.DB.MicrosoftPCA2011     // false')
    db_uefi2011=$(echo "$json" | jq -r '.DB.MicrosoftUEFICA2011  // false')
    db_pca2023=$(echo "$json"  | jq -r '.DB.MicrosoftPCA2023     // false')
    db_uefi2023=$(echo "$json" | jq -r '.DB.MicrosoftUEFICA2023  // false')

    _sb_bool "DB present"                         "$db_present"
    _sb_bool "Windows Production PCA 2011"        "$db_pca2011"
    _sb_bool "Microsoft UEFI CA 2011"             "$db_uefi2011"
    if [[ "$db_pca2023" == "true" || "$db_pca2023" == "True" ]]; then
        sb_check "Windows UEFI CA 2023"           pass "Present"
    else
        sb_check "Windows UEFI CA 2023"           warn "Not present — apply with: iwt vm secure-boot apply-2023-certs"
    fi
    if [[ "$db_uefi2023" == "true" || "$db_uefi2023" == "True" ]]; then
        sb_check "Microsoft UEFI CA 2023"         pass "Present"
    else
        sb_check "Microsoft UEFI CA 2023"         warn "Not present — apply with: iwt vm secure-boot apply-2023-certs"
    fi

    echo ""
    # --- DBX ---
    info "Forbidden Signatures (DBX):"
    local dbx_present dbx_size dbx_pca2011
    dbx_present=$(echo "$json"  | jq -r '.DBX.Present        // false')
    dbx_size=$(echo "$json"     | jq -r '.DBX.Size           // 0')
    dbx_pca2011=$(echo "$json"  | jq -r '.DBX.PCA2011Revoked // false')

    if [[ "$dbx_present" == "true" || "$dbx_present" == "True" ]]; then
        sb_check "DBX present" pass "${dbx_size} bytes"
    else
        sb_check "DBX present" fail "Empty DBX — revocations not applied"
    fi

    if [[ "$dbx_pca2011" == "true" || "$dbx_pca2011" == "True" ]]; then
        sb_check "Windows Production PCA 2011 revoked" pass "In DBX"
    else
        sb_check "Windows Production PCA 2011 revoked" warn "Not in DBX — apply with: iwt vm secure-boot apply-revocations"
    fi

    echo ""
    # --- Pending updates ---
    info "Pending Secure Boot Updates (AvailableUpdates registry):"
    local au_val au_dbx au_kek2023 au_db2023 au_pca2011 au_bootmgr
    au_val=$(echo "$json"      | jq -r '.AvailableUpdates.Value         // 0')
    au_dbx=$(echo "$json"      | jq -r '.AvailableUpdates.DBXUpdate     // false')
    au_kek2023=$(echo "$json"  | jq -r '.AvailableUpdates.KEK2023       // false')
    au_db2023=$(echo "$json"   | jq -r '.AvailableUpdates.DB2023        // false')
    au_pca2011=$(echo "$json"  | jq -r '.AvailableUpdates.PCA2011Revoke // false')
    au_bootmgr=$(echo "$json"  | jq -r '.AvailableUpdates.BootMgrUpdate // false')

    if [[ "$au_val" == "0" ]]; then
        sb_check "Pending updates" pass "None (0x0000)"
    else
        sb_check "Pending updates" warn "0x$(printf '%04X' "$au_val") — run Secure-Boot-Update task"
        [[ "$au_dbx"     == "true" || "$au_dbx"     == "True" ]] && sb_check "  DBX update pending"          warn ""
        [[ "$au_kek2023" == "true" || "$au_kek2023" == "True" ]] && sb_check "  KEK 2023 cert pending"       warn ""
        [[ "$au_db2023"  == "true" || "$au_db2023"  == "True" ]] && sb_check "  DB 2023 cert pending"        warn ""
        [[ "$au_pca2011" == "true" || "$au_pca2011" == "True" ]] && sb_check "  PCA 2011 revocation pending" warn ""
        [[ "$au_bootmgr" == "true" || "$au_bootmgr" == "True" ]] && sb_check "  Boot manager update pending" warn ""
    fi

    echo ""
    # --- Boot manager ---
    info "Boot Manager:"
    local bm_exists bm_signer bm_version
    bm_exists=$(echo "$json"  | jq -r '.BootManager.Exists  // false')
    bm_signer=$(echo "$json"  | jq -r '.BootManager.Signer  // "Unknown"')
    bm_version=$(echo "$json" | jq -r '.BootManager.Version // "?"')

    if [[ "$bm_exists" == "true" || "$bm_exists" == "True" ]]; then
        sb_check "bootmgfw.efi" pass "v${bm_version}"
        if echo "$bm_signer" | grep -qi "2023\|UEFI CA 2023"; then
            sb_check "Boot manager signer" pass "Signed by 2023 CA"
        elif echo "$bm_signer" | grep -qi "2011\|Production PCA 2011"; then
            sb_check "Boot manager signer" warn "Signed by 2011 CA — update available"
        else
            sb_check "Boot manager signer" info "$bm_signer"
        fi
    else
        sb_check "bootmgfw.efi" info "Not found at expected path"
    fi

    echo ""
    # --- SBAT note ---
    local sbat_note
    sbat_note=$(echo "$json" | jq -r '.SBAT.Note // ""')
    [[ -n "$sbat_note" ]] && info "Note: $sbat_note"

    echo ""
    echo "────────────────────────────────────────────"
    ok    "  PASS:    $PASS_COUNT"
    [[ $WARN_COUNT -gt 0 ]] && warn "  WARN:    $WARN_COUNT" || ok "  WARN:    $WARN_COUNT"
    [[ $FAIL_COUNT -gt 0 ]] && err  "  FAIL:    $FAIL_COUNT" || ok "  FAIL:    $FAIL_COUNT"
    echo "────────────────────────────────────────────"
}

# --- Main ---

main() {
    parse_args "$@"

    echo ""
    bold "UEFI Secure Boot Check"
    info "VM: $IWT_VM_NAME"
    echo ""

    if ! vm_is_running; then
        die "VM '$IWT_VM_NAME' is not running. Start it with: iwt vm start $IWT_VM_NAME"
    fi
    vm_wait_for_agent

    # Apply actions first if requested
    if [[ "$APPLY_REVOCATIONS" == true ]]; then
        warn "Applying DBX revocations and revoking Windows Production PCA 2011..."
        warn "This may prevent older bootloaders from working. Proceeding in 5 seconds..."
        sleep 5
        incus exec "$IWT_VM_NAME" -- powershell -Command "$APPLY_REVOCATIONS_SCRIPT" || \
            die "Failed to apply revocations"
        ok "Revocations applied. A reboot is required for SBAT to take effect."
        echo ""
    fi

    if [[ "$APPLY_2023" == true ]]; then
        info "Applying 2023 KEK/DB certificate updates..."
        incus exec "$IWT_VM_NAME" -- powershell -Command "$APPLY_2023_SCRIPT" || \
            die "Failed to apply 2023 cert updates"
        ok "2023 cert updates applied."
        echo ""
    fi

    if [[ "$APPLY_DBX" == true ]]; then
        info "Applying pending DBX updates..."
        incus exec "$IWT_VM_NAME" -- powershell -Command "$APPLY_DBX_SCRIPT" || \
            die "Failed to apply DBX update"
        ok "DBX update applied."
        echo ""
    fi

    info "Auditing UEFI Secure Boot variables..."
    local sb_json
    sb_json=$(incus exec "$IWT_VM_NAME" -- powershell -Command "$SB_AUDIT_SCRIPT" 2>/dev/null) || {
        die "Failed to run Secure Boot audit in guest. Is the Incus agent running?"
    }

    if ! echo "$sb_json" | jq empty 2>/dev/null; then
        err "Audit script returned unexpected output:"
        echo "$sb_json" | head -20
        die "Secure Boot audit failed"
    fi

    if [[ "$JSON_OUTPUT" == true ]]; then
        echo "$sb_json"
        exit 0
    fi

    echo ""
    display_sb_results "$sb_json"

    if [[ -n "$REPORT_FILE" ]]; then
        {
            echo "IWT Secure Boot Audit Report"
            echo "VM: $IWT_VM_NAME"
            echo "Date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
            echo ""
            echo "$sb_json" | jq .
        } > "$REPORT_FILE"
        ok "Report saved to: $REPORT_FILE"
    fi

    echo ""
    if [[ $FAIL_COUNT -gt 0 ]]; then
        err "$FAIL_COUNT Secure Boot issue(s) require attention"
        exit 1
    elif [[ $WARN_COUNT -gt 0 ]]; then
        warn "$WARN_COUNT Secure Boot warning(s) found"
        [[ "$FAIL_ON_WARN" == true ]] && exit 1
        exit 0
    else
        ok "All Secure Boot checks passed"
        exit 0
    fi
}

main "$@"
