#!/usr/bin/env bash
# Manual, direct reproduction of the working local-backup test: connects to
# the DC over WinRM/HTTPS and runs backup-ntds.ps1 (in this same folder) via
# Invoke-Command -FilePath, bypassing backup-ntds.sh's SMB push-receiver
# orchestration entirely. Use this while the push step in backup-ntds.ps1 is
# still commented out - the backup lands in C:\Windows\Temp\<BackupSet> on
# the DC itself; this script just triggers that run and prints the result.
#
# Prereqs (same as backup-ntds.sh's header):
#   sudo pwsh -c "Install-Module -Name PSWSMan -Scope AllUsers -Force"
#   Either /etc/adbackup/credentials (mode 600, root-owned):
#       WINRM_USER=username
#       WINRM_PASS=<password>
#   or pass -u/-p directly (see Usage) to skip the credentials file.
#
# Usage: ./run-local-backup.sh [-u username -p password] [dc-hostname-or-ip]
#   -u/-p must be used together. Without them, falls back to
#   /etc/adbackup/credentials. NOTE: -p puts the password on the command
#   line, which is visible to other local users via `ps` and may land in
#   shell history - fine for this lab, avoid for anything less trusted.
set -euo pipefail

CRED_FILE="/etc/adbackup/credentials"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REMOTE_JOB_SCRIPT="$SCRIPT_DIR/backup-ntds.ps1"

OPT_USER=""
OPT_PASS=""
while getopts ":u:p:" opt; do
    case "$opt" in
        u) OPT_USER="$OPTARG" ;;
        p) OPT_PASS="$OPTARG" ;;
        \?) echo "ERROR: unknown option -$OPTARG" >&2; exit 1 ;;
        :) echo "ERROR: -$OPTARG requires an argument" >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

DC_HOST="${1:-dc01}"

if [[ -n "$OPT_USER" && -n "$OPT_PASS" ]]; then
    WINRM_USER="$OPT_USER"
    WINRM_PASS="$OPT_PASS"
elif [[ -n "$OPT_USER" || -n "$OPT_PASS" ]]; then
    echo "ERROR: -u and -p must be used together" >&2
    exit 1
else
    if [[ ! -r "$CRED_FILE" ]]; then
        echo "ERROR: credentials file $CRED_FILE missing or unreadable (or pass -u/-p directly)" >&2
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$CRED_FILE"
    : "${WINRM_USER:?missing WINRM_USER in $CRED_FILE}"
    : "${WINRM_PASS:?missing WINRM_PASS in $CRED_FILE}"
fi

if [[ ! -f "$REMOTE_JOB_SCRIPT" ]]; then
    echo "ERROR: $REMOTE_JOB_SCRIPT not found" >&2
    exit 1
fi

log() { echo "[$(date +%H:%M:%S)] $1"; }

log "[local] Using WinRM user: $WINRM_USER"
log "[local] Connecting to $DC_HOST over WinRM/HTTPS and starting backup-ntds.ps1..."

# tee to a scratch file so remote Write-Host progress lines still stream to
# the terminal live, while we also capture the final BackupSet=...;TotalBytes=...
# line afterward to print a clean summary.
PWSH_LOG="$(mktemp)"
trap 'rm -f "$PWSH_LOG"' EXIT

WINRM_USER="$WINRM_USER" WINRM_PASS="$WINRM_PASS" DC_HOST="$DC_HOST" REMOTE_JOB_SCRIPT="$REMOTE_JOB_SCRIPT" \
pwsh -NoProfile -NonInteractive -Command '
  $ErrorActionPreference = "Stop"
  Import-Module PSWSMan
  Enable-PSWSMan -Force
  Set-PSWSManAuth -AuthProvider Devolutions
  $secPass = ConvertTo-SecureString $env:WINRM_PASS -AsPlainText -Force
  $cred = New-Object System.Management.Automation.PSCredential($env:WINRM_USER, $secPass)
  $so = New-PSSessionOption -SkipCACheck -SkipCNCheck   # self-signed cert from 02-enable-winrm-https.ps1; drop these if you install a CA-trusted cert
  $session = New-PSSession -ComputerName $env:DC_HOST -UseSSL -Authentication Negotiate -Credential $cred -SessionOption $so
  try {
      # PushHost/PushShare/SmbUser/SmbPassword are unused while the SMB push
      # block in backup-ntds.ps1 is commented out - placeholders only.
      $result = Invoke-Command -Session $session -FilePath $env:REMOTE_JOB_SCRIPT -ArgumentList "unused","unused","unused","unused"
      "BackupSet=$($result.BackupSet);TotalBytes=$($result.TotalBytes)"
  } finally {
      Remove-PSSession $session
  }
' | tee "$PWSH_LOG"

RESULT_LINE="$(grep '^BackupSet=' "$PWSH_LOG" | tail -1)"
if [[ "$RESULT_LINE" =~ ^BackupSet=(.+)\;TotalBytes=([0-9]+)$ ]]; then
    BACKUP_SET="${BASH_REMATCH[1]}"
    TOTAL_BYTES="${BASH_REMATCH[2]}"
    log "[local] Done. Backup set '$BACKUP_SET' ($(( TOTAL_BYTES / 1024 / 1024 )) MB) is in C:\\Windows\\Temp\\$BACKUP_SET on $DC_HOST"
else
    log "[local] WARNING: did not see a usable BackupSet=...;TotalBytes=... line in the output above"
    exit 1
fi
