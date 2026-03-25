#!/usr/bin/env bash
# Run a Windows security audit inside a running VM via the Incus agent.
#
# Executes an embedded version of the Windows-Security-Checks audit script
# (joe-shenouda/Windows-Security-Checks) inside the guest via PowerShell,
# then parses and displays the results in IWT's colour-coded format.
#
# Checks performed inside the guest:
#   - Windows Defender (antivirus, real-time protection, definitions age)
#   - Firewall (all three profiles: Domain, Private, Public)
#   - UAC (User Account Control)
#   - Automatic Updates
#   - BitLocker (C: drive)
#   - Guest account status
#   - Network sharing (SMBv1, anonymous shares)
#   - PowerShell execution policy
#   - Secure Boot (firmware-reported)
#   - RDP (enabled/disabled, NLA enforcement)
#   - LAPS (Local Administrator Password Solution)
#   - Audit policy (logon, object access, privilege use)
#
# Usage:
#   setup-security-audit.sh [options]
#
# Options:
#   --vm NAME       Target VM (default: $IWT_VM_NAME)
#   --report FILE   Save full report to FILE (default: print to stdout)
#   --json          Output raw JSON instead of formatted report
#   --fail-on-warn  Exit 1 if any warnings are found (useful in CI)
#   --help          Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$IWT_ROOT/cli/lib.sh"
source "$IWT_ROOT/remoteapp/backend/incus-backend.sh"
load_config

REPORT_FILE=""
JSON_OUTPUT=false
FAIL_ON_WARN=false

# --- Argument parsing ---

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --vm)           IWT_VM_NAME="$2"; shift 2 ;;
            --report)       REPORT_FILE="$2"; shift 2 ;;
            --json)         JSON_OUTPUT=true; shift ;;
            --fail-on-warn) FAIL_ON_WARN=true; shift ;;
            --help|-h)
                sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
                exit 0
                ;;
            *) die "Unknown option: $1" ;;
        esac
    done
}

# --- Audit PowerShell payload ---
# Runs entirely inside the guest. Returns a JSON object with one key per check.
# Each value is either a boolean, a string status, or a structured object.

AUDIT_SCRIPT='
$ErrorActionPreference = "SilentlyContinue"
$result = [ordered]@{}

# --- Windows Defender ---
$defender = Get-MpComputerStatus
$result.Defender = [ordered]@{
    Enabled          = if ($defender) { [bool]$defender.AntivirusEnabled } else { $false }
    RealTimeProtection = if ($defender) { [bool]$defender.RealTimeProtectionEnabled } else { $false }
    DefinitionAge    = if ($defender) { $defender.AntivirusSignatureAge } else { -1 }
    TamperProtection = if ($defender) { [bool]$defender.IsTamperProtected } else { $false }
}

# --- Firewall ---
$fw = Get-NetFirewallProfile
$result.Firewall = [ordered]@{
    Domain  = ($fw | Where-Object { $_.Name -eq "Domain"  } | Select-Object -ExpandProperty Enabled)
    Private = ($fw | Where-Object { $_.Name -eq "Private" } | Select-Object -ExpandProperty Enabled)
    Public  = ($fw | Where-Object { $_.Name -eq "Public"  } | Select-Object -ExpandProperty Enabled)
}

# --- UAC ---
$uacKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
$uac    = (Get-ItemProperty $uacKey -Name EnableLUA).EnableLUA
$uacLevel = (Get-ItemProperty $uacKey -Name ConsentPromptBehaviorAdmin -ErrorAction SilentlyContinue).ConsentPromptBehaviorAdmin
$result.UAC = [ordered]@{
    Enabled = ($uac -eq 1)
    Level   = if ($null -ne $uacLevel) { $uacLevel } else { -1 }
}

# --- Automatic Updates ---
$auKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update"
$auVal = (Get-ItemProperty $auKey -Name AUOptions -ErrorAction SilentlyContinue).AUOptions
$result.AutoUpdate = [ordered]@{
    # 4 = Auto download and install; 3 = Auto download, notify install; 2 = Notify; 1 = Disabled
    AUOptions = if ($null -ne $auVal) { $auVal } else { -1 }
    Enabled   = ($auVal -eq 4 -or $auVal -eq 3)
}

# --- BitLocker ---
$bl = Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue
$result.BitLocker = [ordered]@{
    Status          = if ($bl) { $bl.ProtectionStatus.ToString() } else { "NotAvailable" }
    EncryptionMethod = if ($bl) { $bl.EncryptionMethod.ToString() } else { "None" }
}

# --- Guest Account ---
$guest = Get-LocalUser -Name "Guest" -ErrorAction SilentlyContinue
$result.GuestAccount = [ordered]@{
    Exists  = ($null -ne $guest)
    Enabled = if ($guest) { $guest.Enabled } else { $false }
}

# --- SMBv1 ---
$smb1 = Get-SmbServerConfiguration -ErrorAction SilentlyContinue
$result.SMBv1 = [ordered]@{
    Enabled = if ($smb1) { [bool]$smb1.EnableSMB1Protocol } else { $true }
}

# --- Anonymous shares ---
$anonShares = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\LanManServer\Parameters" `
    -Name RestrictNullSessAccess -ErrorAction SilentlyContinue).RestrictNullSessAccess
$result.AnonymousShares = [ordered]@{
    Restricted = ($anonShares -eq 1)
}

# --- PowerShell Execution Policy ---
$policy = Get-ExecutionPolicy -Scope LocalMachine -ErrorAction SilentlyContinue
$result.ExecutionPolicy = [ordered]@{
    Policy = if ($policy) { $policy.ToString() } else { "Unknown" }
    Secure = ($policy -eq "AllSigned" -or $policy -eq "RemoteSigned" -or $policy -eq "Restricted")
}

# --- Secure Boot ---
$sb = Confirm-SecureBootUEFI -ErrorAction SilentlyContinue
$result.SecureBoot = [ordered]@{
    Enabled = if ($null -ne $sb) { [bool]$sb } else { $false }
    Supported = ($null -ne $sb)
}

# --- RDP ---
$rdpKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server"
$rdpEnabled = (Get-ItemProperty $rdpKey -Name fDenyTSConnections -ErrorAction SilentlyContinue).fDenyTSConnections
$nlaKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp"
$nla = (Get-ItemProperty $nlaKey -Name UserAuthenticationRequired -ErrorAction SilentlyContinue).UserAuthenticationRequired
$result.RDP = [ordered]@{
    Enabled = ($rdpEnabled -eq 0)
    NLA     = ($nla -eq 1)
}

# --- LAPS ---
$lapsKey = "HKLM:\SOFTWARE\Policies\Microsoft Services\AdmPwd"
$lapsEnabled = (Get-ItemProperty $lapsKey -Name AdmPwdEnabled -ErrorAction SilentlyContinue).AdmPwdEnabled
$lapsNew = Get-Command "Get-LapsADPassword" -ErrorAction SilentlyContinue
$result.LAPS = [ordered]@{
    LegacyEnabled = ($lapsEnabled -eq 1)
    WindowsLAPS   = ($null -ne $lapsNew)
}

# --- Audit Policy ---
$auditRaw = auditpol /get /category:* 2>$null
$result.AuditPolicy = [ordered]@{
    LogonSuccess  = ($auditRaw -match "Logon.*Success")
    LogonFailure  = ($auditRaw -match "Logon.*Failure")
    ObjectAccess  = ($auditRaw -match "Object Access.*Success|Object Access.*Failure")
    PrivilegeUse  = ($auditRaw -match "Privilege Use.*Success|Privilege Use.*Failure")
}

# --- Windows version ---
$os = Get-CimInstance Win32_OperatingSystem
$result.OS = [ordered]@{
    Caption = $os.Caption
    Version = $os.Version
    Build   = $os.BuildNumber
}

$result | ConvertTo-Json -Depth 4
'

# --- Result display ---

WARN_COUNT=0
FAIL_COUNT=0
PASS_COUNT=0

audit_check() {
    local label="$1"
    local status="$2"   # pass | warn | fail | info
    local detail="${3:-}"

    case "$status" in
        pass)
            ok    "  %-35s %s" "$label" "${detail:-OK}"
            PASS_COUNT=$((PASS_COUNT + 1))
            ;;
        warn)
            warn  "  %-35s %s" "$label" "${detail:-WARNING}"
            WARN_COUNT=$((WARN_COUNT + 1))
            ;;
        fail)
            err   "  %-35s %s" "$label" "${detail:-FAIL}"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            ;;
        info)
            info  "  %-35s %s" "$label" "${detail:-}"
            ;;
    esac
}

display_audit_results() {
    local json="$1"

    bold "Windows Security Audit: $IWT_VM_NAME"
    echo ""

    # OS info
    local os_caption os_build
    os_caption=$(echo "$json" | jq -r '.OS.Caption // "Unknown"')
    os_build=$(echo "$json"   | jq -r '.OS.Build   // "?"')
    info "  OS: $os_caption (Build $os_build)"
    echo ""

    # --- Defender ---
    info "Antivirus:"
    local def_enabled def_rtp def_age def_tamper
    def_enabled=$(echo "$json" | jq -r '.Defender.Enabled          // false')
    def_rtp=$(echo "$json"     | jq -r '.Defender.RealTimeProtection // false')
    def_age=$(echo "$json"     | jq -r '.Defender.DefinitionAge     // -1')
    def_tamper=$(echo "$json"  | jq -r '.Defender.TamperProtection  // false')

    _bool_check "Windows Defender"          "$def_enabled"
    _bool_check "Real-time protection"      "$def_rtp"
    _bool_check "Tamper protection"         "$def_tamper"

    if [[ "$def_age" -ge 0 ]]; then
        if [[ "$def_age" -le 3 ]]; then
            audit_check "Definition age" pass "${def_age} day(s)"
        elif [[ "$def_age" -le 7 ]]; then
            audit_check "Definition age" warn "${def_age} day(s) — consider updating"
        else
            audit_check "Definition age" fail "${def_age} day(s) — outdated"
        fi
    fi

    echo ""
    # --- Firewall ---
    info "Firewall:"
    local fw_domain fw_private fw_public
    fw_domain=$(echo "$json"  | jq -r '.Firewall.Domain  // false')
    fw_private=$(echo "$json" | jq -r '.Firewall.Private // false')
    fw_public=$(echo "$json"  | jq -r '.Firewall.Public  // false')
    _bool_check "Domain profile"  "$fw_domain"
    _bool_check "Private profile" "$fw_private"
    _bool_check "Public profile"  "$fw_public"

    echo ""
    # --- UAC ---
    info "User Account Control:"
    local uac_enabled uac_level
    uac_enabled=$(echo "$json" | jq -r '.UAC.Enabled // false')
    uac_level=$(echo "$json"   | jq -r '.UAC.Level   // -1')
    _bool_check "UAC enabled" "$uac_enabled"
    if [[ "$uac_level" -ge 0 ]]; then
        case "$uac_level" in
            0) audit_check "UAC consent level" fail "Never notify (0) — insecure" ;;
            1) audit_check "UAC consent level" warn "Notify only for app changes, no dimming (1)" ;;
            2) audit_check "UAC consent level" pass "Notify for app changes (2) — default" ;;
            5) audit_check "UAC consent level" pass "Always notify (5) — most secure" ;;
            *) audit_check "UAC consent level" info "Level $uac_level" ;;
        esac
    fi

    echo ""
    # --- Updates ---
    info "Automatic Updates:"
    local au_enabled au_opts
    au_enabled=$(echo "$json" | jq -r '.AutoUpdate.Enabled   // false')
    au_opts=$(echo "$json"    | jq -r '.AutoUpdate.AUOptions // -1')
    local au_label
    case "$au_opts" in
        4) au_label="Auto download and install (4)" ;;
        3) au_label="Auto download, notify install (3)" ;;
        2) au_label="Notify only (2)" ;;
        1) au_label="Disabled (1)" ;;
        *) au_label="Unknown ($au_opts)" ;;
    esac
    _bool_check "Auto updates enabled" "$au_enabled" "$au_label"

    echo ""
    # --- BitLocker ---
    info "Encryption:"
    local bl_status bl_method
    bl_status=$(echo "$json" | jq -r '.BitLocker.Status           // "NotAvailable"')
    bl_method=$(echo "$json" | jq -r '.BitLocker.EncryptionMethod // "None"')
    case "$bl_status" in
        On)           audit_check "BitLocker (C:)" pass "On ($bl_method)" ;;
        Off)          audit_check "BitLocker (C:)" warn "Off — drive not encrypted" ;;
        NotAvailable) audit_check "BitLocker (C:)" info "Not available (Home edition or VM)" ;;
        *)            audit_check "BitLocker (C:)" info "$bl_status" ;;
    esac

    echo ""
    # --- Accounts ---
    info "Accounts:"
    local guest_enabled
    guest_enabled=$(echo "$json" | jq -r '.GuestAccount.Enabled // false')
    if [[ "$guest_enabled" == "true" || "$guest_enabled" == "True" ]]; then
        audit_check "Guest account" fail "Enabled — should be disabled"
    else
        audit_check "Guest account" pass "Disabled"
    fi

    echo ""
    # --- Network ---
    info "Network:"
    local smb1_enabled anon_restricted
    smb1_enabled=$(echo "$json"    | jq -r '.SMBv1.Enabled           // true')
    anon_restricted=$(echo "$json" | jq -r '.AnonymousShares.Restricted // false')

    if [[ "$smb1_enabled" == "true" || "$smb1_enabled" == "True" ]]; then
        audit_check "SMBv1" fail "Enabled — vulnerable to EternalBlue/WannaCry"
    else
        audit_check "SMBv1" pass "Disabled"
    fi
    _bool_check "Anonymous share restriction" "$anon_restricted"

    echo ""
    # --- PowerShell ---
    info "PowerShell:"
    local ps_policy ps_secure
    ps_policy=$(echo "$json" | jq -r '.ExecutionPolicy.Policy // "Unknown"')
    ps_secure=$(echo "$json" | jq -r '.ExecutionPolicy.Secure // false')
    if [[ "$ps_secure" == "true" || "$ps_secure" == "True" ]]; then
        audit_check "Execution policy" pass "$ps_policy"
    else
        audit_check "Execution policy" warn "$ps_policy — consider AllSigned or RemoteSigned"
    fi

    echo ""
    # --- Secure Boot ---
    info "Secure Boot:"
    local sb_enabled sb_supported
    sb_enabled=$(echo "$json"   | jq -r '.SecureBoot.Enabled   // false')
    sb_supported=$(echo "$json" | jq -r '.SecureBoot.Supported // false')
    if [[ "$sb_supported" != "true" && "$sb_supported" != "True" ]]; then
        audit_check "Secure Boot" info "Not supported (Legacy BIOS or cmdlet unavailable)"
    else
        _bool_check "Secure Boot" "$sb_enabled"
    fi

    echo ""
    # --- RDP ---
    info "Remote Desktop:"
    local rdp_enabled rdp_nla
    rdp_enabled=$(echo "$json" | jq -r '.RDP.Enabled // false')
    rdp_nla=$(echo "$json"     | jq -r '.RDP.NLA     // false')
    if [[ "$rdp_enabled" == "true" || "$rdp_enabled" == "True" ]]; then
        audit_check "RDP" info "Enabled"
        _bool_check "Network Level Auth (NLA)" "$rdp_nla"
    else
        audit_check "RDP" pass "Disabled"
    fi

    echo ""
    # --- LAPS ---
    info "Local Admin Password:"
    local laps_legacy laps_new
    laps_legacy=$(echo "$json" | jq -r '.LAPS.LegacyEnabled // false')
    laps_new=$(echo "$json"    | jq -r '.LAPS.WindowsLAPS   // false')
    if [[ "$laps_new" == "true" || "$laps_new" == "True" ]]; then
        audit_check "Windows LAPS" pass "Configured"
    elif [[ "$laps_legacy" == "true" || "$laps_legacy" == "True" ]]; then
        audit_check "Legacy LAPS" pass "Configured"
    else
        audit_check "LAPS" warn "Not configured — local admin password may be static"
    fi

    echo ""
    # --- Audit Policy ---
    info "Audit Policy:"
    local audit_logon_s audit_logon_f audit_obj audit_priv
    audit_logon_s=$(echo "$json" | jq -r '.AuditPolicy.LogonSuccess // false')
    audit_logon_f=$(echo "$json" | jq -r '.AuditPolicy.LogonFailure // false')
    audit_obj=$(echo "$json"     | jq -r '.AuditPolicy.ObjectAccess // false')
    audit_priv=$(echo "$json"    | jq -r '.AuditPolicy.PrivilegeUse // false')
    _bool_check "Logon success auditing" "$audit_logon_s"
    _bool_check "Logon failure auditing" "$audit_logon_f"
    _bool_check "Object access auditing" "$audit_obj"
    _bool_check "Privilege use auditing" "$audit_priv"

    echo ""
    echo "────────────────────────────────────────────"
    ok    "  PASS:    $PASS_COUNT"
    if [[ $WARN_COUNT -gt 0 ]]; then
        warn "  WARN:    $WARN_COUNT"
    else
        ok   "  WARN:    $WARN_COUNT"
    fi
    if [[ $FAIL_COUNT -gt 0 ]]; then
        err  "  FAIL:    $FAIL_COUNT"
    else
        ok   "  FAIL:    $FAIL_COUNT"
    fi
    echo "────────────────────────────────────────────"
}

# Helper: display a boolean check as pass/fail
_bool_check() {
    local label="$1"
    local value="$2"
    local detail="${3:-}"
    if [[ "$value" == "true" || "$value" == "True" || "$value" == "1" ]]; then
        audit_check "$label" pass "$detail"
    else
        audit_check "$label" fail "$detail"
    fi
}

# --- Main ---

main() {
    parse_args "$@"

    echo ""
    bold "Windows Security Audit"
    info "VM: $IWT_VM_NAME"
    echo ""

    if ! vm_is_running; then
        die "VM '$IWT_VM_NAME' is not running. Start it with: iwt vm start $IWT_VM_NAME"
    fi
    vm_wait_for_agent

    info "Running security checks inside guest..."
    local audit_json
    audit_json=$(incus exec "$IWT_VM_NAME" -- powershell -Command "$AUDIT_SCRIPT" 2>/dev/null) || {
        die "Failed to run audit script in guest. Is the Incus agent running?"
    }

    # Validate we got JSON back
    if ! echo "$audit_json" | jq empty 2>/dev/null; then
        err "Audit script returned unexpected output:"
        echo "$audit_json" | head -20
        die "Audit failed"
    fi

    if [[ "$JSON_OUTPUT" == true ]]; then
        echo "$audit_json"
        exit 0
    fi

    echo ""
    display_audit_results "$audit_json"

    # Optionally save report
    if [[ -n "$REPORT_FILE" ]]; then
        {
            echo "IWT Security Audit Report"
            echo "VM: $IWT_VM_NAME"
            echo "Date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
            echo ""
            echo "$audit_json" | jq .
        } > "$REPORT_FILE"
        ok "Report saved to: $REPORT_FILE"
    fi

    echo ""
    if [[ $FAIL_COUNT -gt 0 ]]; then
        err "$FAIL_COUNT security issue(s) found that should be addressed"
        [[ "$FAIL_ON_WARN" == true ]] && exit 1
        exit 1
    elif [[ $WARN_COUNT -gt 0 ]]; then
        warn "$WARN_COUNT warning(s) found"
        [[ "$FAIL_ON_WARN" == true ]] && exit 1
        exit 0
    else
        ok "All security checks passed"
        exit 0
    fi
}

main "$@"
