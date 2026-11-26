# AD system-state backup POC (`dc01` lab)

Proof-of-concept tooling for backing up a Windows domain controller's AD
database (`ntds.dit`) and credential-relevant registry hives, run from a
Linux backup host, under an account that is **Backup Operators only, never
local Administrator** (company policy constraint, enforced throughout this
design - no step may require admin rights on the DC).

## Current status

The core backup step (take a VSS shadow, copy `ntds.dit` + transaction logs,
save registry hives) is validated and working end-to-end against `dc01`. The
original design also pushes the finished backup off the DC to this Linux
host over SMB; that step is currently **disabled** while the core backup was
debugged in isolation, so backups land locally on the DC instead. See
"What's disabled / next step" below.

## Layout

- **`backup-ntds.sh`** / **`backup-ntds.ps1`** (repo root) - the original,
  full design: Linux side stands up a throwaway SMB share (Impacket), sizes
  the backup, then runs the PS1 remotely over WinRM, which takes the backup
  and pushes it straight to that share. **Not currently runnable as-is** -
  see known issues below.
- **`manual-local-test/`** - the actively-tested working copy, used while the
  SMB push is disabled:
  - `backup-ntds.ps1` - same core backup logic, with the push code commented
    out (not deleted) and replaced with a local copy to
    `C:\Windows\Temp\<BackupSet>` on the DC.
  - `run-local-backup.sh` - connects to the DC over WinRM/HTTPS and runs the
    PS1 via `Invoke-Command -FilePath`, bypassing `backup-ntds.sh`'s SMB
    orchestration entirely. Prints live progress and a final summary line.
  - `verify-local-backup.sh` - optional: lists the files a given backup set
    produced on the DC, for confirmation without RDP'ing in.
- **`NOTES.md`** - running debug log: every bug found, root-caused, and
  fixed (or not), in chronological order. Read this for the *why* behind
  each design decision below.

## How to run it (current, local-backup-only state)

```bash
cd manual-local-test
./run-local-backup.sh dc01
```

By default this reads WinRM credentials from `/etc/adbackup/credentials`. To
pass them directly instead (skips the credentials file entirely):

```bash
./run-local-backup.sh -u username -p 'Passw0rd123' dc01
```

`-u`/`-p` must be used together. Note `-p` puts the password on the command
line (visible to other local users via `ps`, may land in shell history) -
fine for this lab, avoid it anywhere less trusted.

Prints progress as it runs and a final line like:

```
[..] Done. Backup set 'ntds-20261125-222058' (62 MB) is in C:\Windows\Temp\ntds-20261125-222058 on dc01
```

Take that `BackupSet` value and optionally confirm the files with
`verify-local-backup.sh` (same `-u`/`-p` fallback behavior as above - not
shown here, uses the credentials file by default):

```bash
./verify-local-backup.sh ntds-20261125-222058 dc01
```

This lists every file the run produced on the DC (name + size) - useful for
a closer look, but not required since the summary line above already
confirms success.

**One-time prereqs** (already done in this lab, documented for a fresh box):
- Either `/etc/adbackup/credentials`, containing `WINRM_USER=username` /
  `WINRM_PASS=...` - should be mode `600`, root-owned (**currently still
  `644`, world-readable - not yet fixed, see below**) - or pass `-u`/`-p` as
  shown above.
- PSWSMan PowerShell module installed:
  `sudo pwsh -c "Install-Module -Name PSWSMan -Scope AllUsers -Force"`.

## What the backup captures

All of the following land together in one folder
(`C:\Windows\Temp\ntds-<timestamp>\` on the DC):

- `ntds.dit` + transaction logs + checkpoint file - via an application-
  consistent VSS shadow copy (`diskshadow.exe`), copied out with
  `robocopy /B` (backup-mode copy, needed because `ntds.dit` is ACL'd to
  SYSTEM only and a plain `Copy-Item` gets Access Denied even with
  `SeBackupPrivilege`).
- `SYSTEM.hiv`, `SAM.hiv` - via `reg.exe save`, no VSS needed. Both succeed
  under Backup Operators.
- `SECURITY.hiv` - **does not** get captured. `reg.exe save HKLM\SECURITY`
  fails with `Access is denied`: LSA secrets have protection beyond normal
  registry ACLs that `SeBackupPrivilege` doesn't bypass the way it does for
  `SYSTEM`/`SAM`. Getting it would require real Administrator/SYSTEM rights,
  which conflicts with this project's core constraint, so the script logs a
  warning and continues rather than failing the whole backup.

This data set (`ntds.dit` + `SYSTEM`/`SAM`/`SECURITY` hives) is exactly what
offline AD credential extraction needs - that's inherent to backing up a
domain controller's system state, not specific to this tool. Treat the
output folder as highly sensitive: lab-only, and clean it up/secure it the
same way you would any other copy of domain credential material.

## Known issues / what's disabled

- **SMB push to Linux is disabled.** `backup-ntds.ps1`'s push block
  (`net.exe use` mapping + `robocopy` to the UNC share) is commented out, not
  deleted. Re-enabling it is the next step once the sudoers gap below is
  fixed.
- **`backup-ntds.sh`'s cleanup trap can't actually clean up.** It calls
  `sudo pkill -f "impacket-smbserver adbackup-push"` to stop the push-
  receiver on exit, but the sudoers NOPASSWD rule only covers
  `/usr/bin/impacket-smbserver` itself, not `pkill` - so the old server is
  left running on port 445 with a now-stale random password, and the next
  run's readiness check (a bare TCP connect) can't tell its own fresh server
  apart from the stale one. This is what originally looked like a bad-
  password bug (`System error 86`). Needs a narrowly-scoped second sudoers
  rule for the exact fixed `pkill` pattern, plus a pre-flight check that
  aborts loudly if port 445 is already in use.
- **`/etc/adbackup/credentials` is mode 644**, not `600` - any local user on
  the backup host can currently read the WinRM service account password.
  Needs `sudo chmod 600 /etc/adbackup/credentials`.
- **`SECURITY.hiv` can't be captured** under the Backup-Operators-only
  account model (see above) - accepted limitation, not a bug to fix.

See `NOTES.md` for the full chronological debugging history, including bugs
already found and fixed along the way (a `diskshadow` expose bug caused by a
PowerShell array-collapse edge case, UTF-16LE log-encoding misreads, orphaned
VSS shadow copies, and a CIM/WMI permission issue in the original SMB-mapping
approach).
