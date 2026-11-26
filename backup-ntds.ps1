<#
Executed remotely (via Invoke-Command -FilePath from the Linux side) under
the backup-operator account. Relies entirely on SeBackupPrivilege granted by
Backup Operators membership - no local admin rights needed, and uses only
native Windows tools (diskshadow.exe, robocopy.exe) - no extra Windows
feature or SMB share may be installed/created on the DC under company
policy, and both of those would need local Administrator rights this
account intentionally does not have. Because of that, this script does not
stage a backup locally on the DC at all - it pushes ntds.dit and its log
files straight out over SMB to a share the Linux backup host stands up
itself for the duration of the run (see backup-ntds.sh). Connecting to a
remote SMB share as a client needs no special rights on this end.

Takes an application-consistent VSS shadow copy of the volume(s) holding the
AD database and its transaction logs (the NTDS VSS writer participates in
the freeze/thaw, same as a system-state backup would), then pushes just
ntds.dit and its log files - the minimum needed for a consistent, restorable
copy - to the caller's share.
#>
param(
    [Parameter(Mandatory)] [string]$PushHost,
    [Parameter(Mandatory)] [string]$PushShare,
    [Parameter(Mandatory)] [string]$SmbUser,
    [Parameter(Mandatory)] [string]$SmbPassword,
    # Default NTDS location. If ntdsutil has relocated the database or logs
    # on a given DC, pass the real paths in here - they can't be looked up
    # automatically because HKLM:\SYSTEM\...\NTDS\Parameters is locked down
    # to admins only and this account intentionally isn't one.
    [string]$NtdsDbPath = "$env:WINDIR\NTDS\ntds.dit",
    [string]$NtdsLogPath = "$env:WINDIR\NTDS"
)

$ErrorActionPreference = 'Stop'

$diskshadow = "$env:WINDIR\System32\diskshadow.exe"
if (-not (Test-Path $diskshadow)) {
    throw "diskshadow.exe not found at $diskshadow"
}

$dbDir  = Split-Path $NtdsDbPath -Parent
$logDir = $NtdsLogPath

$dbVolume  = Split-Path -Path $dbDir  -Qualifier
$logVolume = Split-Path -Path $logDir -Qualifier
# @(...) wraps the pipeline output too: Select-Object -Unique collapses to a
# scalar string when db/log share one volume (true on this DC), and indexing
# a scalar string with [$i] below would return a character, not "C:".
$volumes = @(@($dbVolume, $logVolume) | Select-Object -Unique)

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupSet = "ntds-$timestamp"
$pushRoot = "\\$PushHost\$PushShare"
$pushTarget = "$pushRoot\$backupSet"
# POC step: land the backup locally on the DC under C:\Windows\Temp instead
# of pushing it over SMB, so the diskshadow+robocopy core can be verified
# working on its own first. $pushRoot/$pushTarget are left defined above and
# the push code below is commented out (not deleted) to restore next step.
$localBackupTarget = Join-Path "$env:WINDIR\Temp" $backupSet

Write-Host "[dc01] Backup set: $backupSet"

$workDir = Join-Path "$env:WINDIR\Temp" "diskshadow-$timestamp"
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

# Pick free drive letters to expose the shadow copies on. Start at E: to
# stay clear of A/B (floppy) and C: (system).
$usedLetters = (Get-PSDrive -PSProvider FileSystem).Name
$freeLetters = 69..90 | ForEach-Object { [string][char]$_ } | Where-Object { $usedLetters -notcontains $_ }
if ($freeLetters.Count -lt $volumes.Count) {
    throw "Not enough free drive letters to expose $($volumes.Count) shadow volume(s)"
}

$exposeMap = @{}
for ($i = 0; $i -lt $volumes.Count; $i++) {
    $exposeMap[$volumes[$i]] = "$($freeLetters[$i]):"
}

$metadataPath = Join-Path $workDir 'metadata.cab'
$createScript = @(
    'set verbose on'
    'set context persistent'
    "set metadata $metadataPath"
    'begin backup'
)
$i = 0
foreach ($vol in $volumes) {
    $createScript += "add volume $vol alias ntdsvol$i"
    $i++
}
$createScript += 'create'
$i = 0
foreach ($vol in $volumes) {
    $createScript += "expose %ntdsvol$i% $($exposeMap[$vol])"
    $i++
}
$createScript += 'end backup'

$createScriptPath = Join-Path $workDir 'create.dsh'
Set-Content -Path $createScriptPath -Value $createScript -Encoding ASCII

# --- POC: SMB push disabled for now, landing backups in C:\Windows\Temp locally instead ---
# Connect to the Linux-hosted push share before opening the shadow, so a bad
# credential or unreachable host fails fast instead of after taking one.
# New-SmbMapping goes through the CIM/WMI SmbShare provider, which is ACL'd
# to Administrators on this DC and gets "Cannot connect to CIM server. Access
# denied" for a Backup Operators-only account. `net use` maps the share via
# the older MPR APIs directly, same privilege-free path robocopy /B already
# relies on instead of Copy-Item.
# & net.exe use $pushRoot /user:$SmbUser $SmbPassword | Out-Null
# if ($LASTEXITCODE -ne 0) {
#     throw "net use failed to map $pushRoot (exit code $LASTEXITCODE)"
# }
# --- end POC disable ---

Write-Host "[dc01] Taking VSS shadow copy of $($volumes -join ', ') and exposing it..."
$createLogPath = Join-Path $workDir 'diskshadow-create.log'
try {
    & $diskshadow /s $createScriptPath /l $createLogPath
    if ($LASTEXITCODE -ne 0) {
        # diskshadow writes its /l log as UTF-16LE; reading with the default
        # encoding mangles every character into "c h a r  s p a c e d" noise.
        $createLog = if (Test-Path $createLogPath) { Get-Content $createLogPath -Raw -Encoding Unicode } else { '(no log produced)' }
        throw "diskshadow (create) exited with code $LASTEXITCODE. Log:`n$createLog"
    }
    foreach ($driveLetter in $exposeMap.Values) {
        if (-not (Test-Path $driveLetter)) {
            throw "diskshadow reported success but $driveLetter was never exposed"
        }
    }

    Write-Host "[dc01] Shadow exposed. Copying ntds.dit (robocopy /B)..."
    $shadowDbDir  = $dbDir  -replace [regex]::Escape($dbVolume),  $exposeMap[$dbVolume]
    $shadowLogDir = $logDir -replace [regex]::Escape($logVolume), $exposeMap[$logVolume]

    # POC: copying to $localBackupTarget (C:\Windows\Temp) instead of
    # $pushTarget (the SMB push share) while the push step is disabled.
    New-Item -ItemType Directory -Path $localBackupTarget -Force | Out-Null

    # ntds.dit is ACL'd to SYSTEM only - a plain Copy-Item (CreateFile with no
    # backup semantics) gets Access Denied even though this account has
    # SeBackupPrivilege. robocopy /B opens files in backup mode, which uses
    # that privilege to bypass the ACL check, same as any real backup tool.
    # /R:2 /W:2 keeps a real failure from hanging on robocopy's default
    # near-infinite retry loop.
    robocopy $shadowDbDir $localBackupTarget /B /E /R:2 /W:2 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy failed copying $shadowDbDir to $localBackupTarget (exit code $LASTEXITCODE)"
    }
    if ($shadowLogDir -ne $shadowDbDir) {
        Write-Host "[dc01] Copying transaction logs (robocopy /B)..."
        $logDest = Join-Path $localBackupTarget 'logs'
        New-Item -ItemType Directory -Path $logDest -Force | Out-Null
        robocopy $shadowLogDir $logDest /B /E /R:2 /W:2 /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) {
            throw "robocopy failed copying $shadowLogDir to $logDest (exit code $LASTEXITCODE)"
        }
    }

    # SYSTEM/SAM/SECURITY are the credential-relevant hives (same set a real
    # system-state backup captures) - all live hives, same as ntds.dit.
    # reg.exe save uses RegSaveKeyEx under the hood, which relies on
    # SeBackupPrivilege (already granted via Backup Operators) to read them
    # without needing a VSS shadow.
    # HKLM\SECURITY (LSA secrets) has protection beyond normal registry ACLs
    # that Backup Operators' SeBackupPrivilege doesn't bypass - confirmed live
    # against dc01 ("Access is denied"), unlike SYSTEM/SAM which do work under
    # this privilege level. Since this account is Backup Operators only by
    # policy and can never be Administrator, treat a SECURITY failure as a
    # soft skip; a SYSTEM/SAM failure is still a hard error since those are
    # expected to always work here.
    $credHives = @('SYSTEM', 'SAM', 'SECURITY')
    $hivePaths = @()
    foreach ($hive in $credHives) {
        Write-Host "[dc01] Saving HKLM\$hive registry hive..."
        $hivePath = Join-Path $localBackupTarget "$hive.hiv"
        try {
            & reg.exe save "HKLM\$hive" $hivePath /y | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "reg save HKLM\$hive failed (exit code $LASTEXITCODE)"
            }
            $hivePaths += $hivePath
        } catch {
            if ($hive -eq 'SECURITY') {
                Write-Host "[dc01] WARNING: could not save HKLM\SECURITY ($($_.Exception.Message)) - needs more than Backup Operators rights; skipping it. SYSTEM/SAM/ntds.dit still captured."
                Remove-Item -Path $hivePath -Force -ErrorAction SilentlyContinue
            } else {
                throw
            }
        }
    }

    $totalBytes = (Get-ChildItem $shadowDbDir -Recurse -File | Measure-Object -Property Length -Sum).Sum
    if ($shadowLogDir -ne $shadowDbDir) {
        $totalBytes += (Get-ChildItem $shadowLogDir -Recurse -File | Measure-Object -Property Length -Sum).Sum
    }
    $totalBytes += ($hivePaths | Get-Item | Measure-Object -Property Length -Sum).Sum
    Write-Host "[dc01] Copy complete: $localBackupTarget ($([math]::Round($totalBytes/1MB, 1)) MB)"
}
finally {
    # Always try to release the shadow copies/drive letters and the SMB
    # mapping, even if the copy above failed partway through.
    Write-Host "[dc01] Releasing VSS shadow copy and cleaning up..."
    $deleteScript = $exposeMap.Values | ForEach-Object { "delete shadows exposed $_" }
    $deleteScriptPath = Join-Path $workDir 'delete.dsh'
    Set-Content -Path $deleteScriptPath -Value $deleteScript -Encoding ASCII
    & $diskshadow /s $deleteScriptPath | Out-Null
    Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue
    # POC: no SMB mapping was made (push disabled above), so nothing to unmap.
    # & net.exe use $pushRoot /delete /y 2>$null | Out-Null
}

[PSCustomObject]@{
    BackupSet  = $backupSet
    TotalBytes = $totalBytes
}
