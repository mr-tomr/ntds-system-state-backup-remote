#!/usr/bin/env bash
# Lists the files a run-local-backup.sh run produced in C:\Windows\Temp on
# the DC, so you can confirm a backup actually landed without RDP'ing in.
#
# Usage: ./verify-local-backup.sh [-u username -p password] <backup-set-name> [dc-hostname-or-ip]
#   -u/-p must be used together. Without them, falls back to
#   /etc/adbackup/credentials. e.g.
#     ./verify-local-backup.sh ntds-20261125-174110 dc01
#     ./verify-local-backup.sh -u username -p 'Passw0rd123' ntds-20261125-174110 dc01
set -euo pipefail

CRED_FILE="/etc/adbackup/credentials"

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

BACKUP_SET="${1:?usage: verify-local-backup.sh [-u user -p pass] <backup-set-name> [dc-host]}"
DC_HOST="${2:-dc01}"

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

WINRM_USER="$WINRM_USER" WINRM_PASS="$WINRM_PASS" DC_HOST="$DC_HOST" BACKUP_SET="$BACKUP_SET" \
pwsh -NoProfile -NonInteractive -Command '
  $ErrorActionPreference = "Stop"
  Import-Module PSWSMan
  Enable-PSWSMan -Force
  Set-PSWSManAuth -AuthProvider Devolutions
  $secPass = ConvertTo-SecureString $env:WINRM_PASS -AsPlainText -Force
  $cred = New-Object System.Management.Automation.PSCredential($env:WINRM_USER, $secPass)
  $so = New-PSSessionOption -SkipCACheck -SkipCNCheck
  $session = New-PSSession -ComputerName $env:DC_HOST -UseSSL -Authentication Negotiate -Credential $cred -SessionOption $so
  try {
    Invoke-Command -Session $session -ArgumentList $env:BACKUP_SET -ScriptBlock {
      param($BackupSet)
      Get-ChildItem (Join-Path "$env:WINDIR\Temp" $BackupSet) -Recurse |
        Select-Object FullName, Length
    }
  } finally {
    Remove-PSSession $session
  }
'
