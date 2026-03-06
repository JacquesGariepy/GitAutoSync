
# GitAutoSync
*Autonomous bidirectional folder ⇆ Git(Hub/Enterprise) synchronizer for Windows*  
Released **2026-03-16** • License [MIT](#license)

> Continuously mirrors changes between a local directory and a Git remote, with real-time file watching, periodic scans, persisted state, queue-based processing, conflict policies, integrity checks, structured logging, quarantine, and unattended recovery. Designed for Windows workstations, servers, Task Scheduler, NSSM, or WinSW.

---

## Table of Contents
1. [Key Features](#key-features)  
2. [System Requirements](#system-requirements)  
3. [Synchronization Model](#synchronization-model)  
4. [Quick Start](#quick-start)  
5. [Two-PC Setup](#two-pc-setup)  
6. [Command-Line Reference](#command-line-reference)  
7. [Conflict Resolution Policies](#conflict-resolution-policies)  
8. [How It Works](#how-it-works)  
9. [Control Commands](#control-commands)  
10. [Installation and Scheduling](#installation-and-scheduling)  
11. [Advanced Scenarios](#advanced-scenarios)  
12. [Status, Logs, and Metrics](#status-logs-and-metrics)  
13. [Troubleshooting](#troubleshooting)  
14. [Security and Compliance Notes](#security-and-compliance-notes)  
15. [FAQ](#faq)  
16. [License](#license)

---

## Key Features

| Area | Description |
|---|---|
| **Real-time sync engine** | Uses `FileSystemWatcher` for near-real-time detection of file create, modify, delete, and rename events. |
| **Periodic safety scan** | Performs full recursive scans at intervals to recover from missed events, watcher overflow, or external changes. |
| **Persistent local state** | Maintains a JSON state database with tracked files, hashes, timestamps, last seen cycle, conflicts, quarantine records, and HEAD metadata. |
| **Transactional queue** | Uses a persisted operation queue for staged processing of local adds, modifications, deletes, renames, scans, and sync cycles. |
| **Smart first run** | Empty folder → auto-clone. Non-repo folder → `git init`, add remote, fetch, checkout. Existing repo → reuse. |
| **Single-instance safety** | Global mutex prevents duplicate instances on the same machine. |
| **Conflict handling** | Supports unattended conflict resolution policies: `LocalWins`, `RemoteWins`, `NewestCommit`, `NewestMTime`, `HostPriority`, `ManualFreeze`. |
| **Rename detection** | Detects rename and move operations using scan-time hash matching between deleted and added files. |
| **Dangerous delete protection** | If deletions exceed a threshold, sync enters safe pause and can move affected files to quarantine instead of blindly propagating destruction. |
| **Integrity verification** | Verifies local and remote HEAD state and records integrity check timestamps. |
| **Repository health checks** | Detects broken repo state, missing remotes, lock files, branch issues, and can attempt controlled repair. |
| **Auto-recovery** | Can retry, repair, or optionally re-clone in severe corruption scenarios. |
| **Observability** | Structured JSON logs, CSV metrics, status JSON, transaction journal, conflict resolution audit file, optional Windows Event Log. |
| **Security controls** | Remote allowlist, optional EFS encryption, secret scan before staging, log redaction, compliance metadata, credential-friendly design. |
| **Large file awareness** | Warns on oversized files and supports Git LFS-friendly workflows. |
| **Profile support** | Includes `Workstation`, `Server`, `ReadOnly`, `Mirror`, `LocalPriority`, and `RemotePriority` profiles. |
| **Control inbox** | Pause, resume, force sync, status refresh, and stop through simple JSON control files. |
| **Dry-run mode** | Simulates actions without modifying the working tree or remote. |

---

## System Requirements

| Component | Minimum |
|---|---|
| **OS** | Windows 10/11 with PowerShell 5+ |
| **Git** | Git for Windows, installed or auto-installed via `winget` |
| **Remote** | HTTPS Git remote supported by GitHub, GitHub Enterprise, GitLab, Azure Repos, Bitbucket, Gitea, or similar |
| **Authentication** | Working Git credentials on every machine that runs the synchronizer |
| **Optional** | `winget` for automatic Git installation |
| **Optional** | Git Credential Manager for secure token storage |
| **Optional** | Git LFS for large file workflows |

---

## Synchronization Model

GitAutoSync is not just a loop that runs `git add`, `pull`, and `push`. It is an eventually-consistent or near-real-time Windows synchronizer built on top of Git.

### Core semantics
- One local root folder is mapped to one Git remote branch.
- Local file system events are captured and normalized into queued operations.
- The queue is persisted to disk for crash recovery.
- Periodic scans correct watcher drift and detect renames.
- Local staged changes are integrated with remote changes using `pull --rebase --autostash`.
- Conflicts are resolved by policy when possible.
- Integrity checks validate convergence after sync cycles.

### Supported modes
- `EventuallyConsistent`
- `NearRealtime`
- `MirrorReplica`

### Supported directions
- `Bidirectional`
- `PushOnly`
- `PullOnly`

---

## Quick Start

### 1. Ensure Git authentication works
On each machine, verify:

```powershell
git ls-remote https://github.com/your-org/your-repo.git
````

Then verify that `git pull` and `git push` work normally in a test repo.

### 2. Choose a local folder

Example:

```powershell
$root = "D:\Sync"
```

### 3. Run GitAutoSync

```powershell
powershell.exe -ExecutionPolicy Bypass `
  -File C:\Tools\GitAutoSync_Enterprise_vNext.ps1 `
  -Repo "https://github.com/your-org/your-repo.git" `
  -Root $root `
  -Branch "main" `
  -Profile Workstation `
  -ConflictPolicy HostPriority `
  -HostPriority 100 `
  -VerboseMode
```

On first run:

* empty folder → clone
* non-repo folder with files → initialize repo, attach remote, fetch, checkout
* existing repo → reuse it

---

## Two-PC Setup

This is the correct setup when the same project must stay synchronized across two Windows machines.

### Requirements

Both PCs must use:

* the **same remote repository**
* the **same branch**
* a **valid Git authentication setup**
* a **coherent conflict policy**

### Recommended policy

Use `HostPriority` with different priorities per machine.

Example:

* primary workstation: `-HostPriority 100`
* secondary workstation: `-HostPriority 50`

This ensures deterministic conflict resolution when the same file is edited on both machines around the same time.

### PC 1

```powershell
powershell.exe -ExecutionPolicy Bypass `
  -File "C:\Tools\GitAutoSync_Enterprise_vNext.ps1" `
  -Repo "https://github.com/your-org/your-repo.git" `
  -Root "C:\Projects\MyProject" `
  -Branch "main" `
  -Profile Workstation `
  -ConflictPolicy HostPriority `
  -HostPriority 100 `
  -DelaySec 10 `
  -FullScanIntervalSec 300 `
  -VerboseMode
```

### PC 2

```powershell
powershell.exe -ExecutionPolicy Bypass `
  -File "C:\Tools\GitAutoSync_Enterprise_vNext.ps1" `
  -Repo "https://github.com/your-org/your-repo.git" `
  -Root "D:\Work\MyProject" `
  -Branch "main" `
  -Profile Workstation `
  -ConflictPolicy HostPriority `
  -HostPriority 50 `
  -DelaySec 10 `
  -FullScanIntervalSec 300 `
  -VerboseMode
```

### Startup order

If the remote repository is empty and PC 1 already contains the project files:

1. Start GitAutoSync on **PC 1** first
2. Wait for the first successful push
3. Start GitAutoSync on **PC 2**

If the remote repository already contains the source of truth:

* start both normally

### Do not do this

* Do not use different branches unless that is intentional
* Do not use conflicting policies like `LocalWins` on one machine and `RemoteWins` on the other
* Do not run two synchronizer instances against the same root on the same machine
* Do not assume authentication is configured just because the script starts

---

## Command-Line Reference

| Parameter                       | Default                | Description                                                                                               |
| ------------------------------- | ---------------------- | --------------------------------------------------------------------------------------------------------- |
| `-Repo`                         | `$env:GITHUB_REPO`     | Remote repository URL. Required on first initialization if the folder is not already connected to a repo. |
| `-Root`                         | `%USERPROFILE%\Bridge` | Local root folder to synchronize.                                                                         |
| `-Branch`                       | `main`                 | Branch to track.                                                                                          |
| `-Profile`                      | `Workstation`          | Sync profile: `Workstation`, `Server`, `ReadOnly`, `Mirror`, `LocalPriority`, `RemotePriority`.           |
| `-DelaySec`                     | `15`                   | Main loop interval in seconds.                                                                            |
| `-FullScanIntervalSec`          | `300`                  | Full scan interval used as watcher fallback and reconciliation pass.                                      |
| `-DebounceMs`                   | `1500`                 | Event debounce window for burst changes.                                                                  |
| `-GitExe`                       | auto                   | Explicit path to `git.exe`.                                                                               |
| `-InstallGitIfMissing`          | `true`                 | Auto-install Git with `winget` if missing.                                                                |
| `-VerboseMode`                  | off                    | Console diagnostics.                                                                                      |
| `-DryRun`                       | off                    | Simulate without making changes.                                                                          |
| `-Encrypt`                      | off                    | Enable EFS encryption on the root directory.                                                              |
| `-ComplianceMode`               | off                    | Configure `user.name`, `user.email`, and commit hygiene metadata.                                         |
| `-ReadOnlyMode`                 | off                    | Prevent pushing local changes.                                                                            |
| `-EnableWatcher`                | on                     | Enable `FileSystemWatcher`.                                                                               |
| `-EnableControlInbox`           | on                     | Enable local JSON control commands.                                                                       |
| `-EnableEventLog`               | on                     | Write selected messages to Windows Event Log.                                                             |
| `-EnableStructuredJsonLog`      | on                     | Write structured JSON logs.                                                                               |
| `-EnablePeriodicIntegrityCheck` | on                     | Perform HEAD and sync integrity checks.                                                                   |
| `-EnableSecretScan`             | on                     | Scan files for possible secrets before staging.                                                           |
| `-AllowAutoRepair`              | on                     | Allow controlled repo repair attempts.                                                                    |
| `-AllowAutoReclone`             | off                    | Allow destructive backup-and-reclone recovery path.                                                       |
| `-RetryMax`                     | `5`                    | Maximum Git command retry attempts.                                                                       |
| `-RetryBaseSeconds`             | `2`                    | Retry backoff base.                                                                                       |
| `-BatchWindowSec`               | `8`                    | Commit batching window.                                                                                   |
| `-NetworkFailurePauseSec`       | `60`                   | Pause after network failure.                                                                              |
| `-DangerousDeleteThreshold`     | `50`                   | Number of deletions that triggers safe pause/quarantine protection.                                       |
| `-LargeFileThresholdMB`         | `50`                   | Large file warning threshold.                                                                             |
| `-MaxFilesPerCycle`             | `5000`                 | Maximum files inspected per scan cycle.                                                                   |
| `-MaxQueueItems`                | `50000`                | Maximum persisted queued operations.                                                                      |
| `-HealthCheckEveryCycles`       | `20`                   | Repository health check cadence.                                                                          |
| `-ConflictPolicy`               | `LocalWins`            | Conflict strategy.                                                                                        |
| `-HostPriority`                 | `0`                    | Host priority used with `HostPriority` policy.                                                            |
| `-SyncModel`                    | `EventuallyConsistent` | Synchronization behavior model.                                                                           |
| `-SyncDirection`                | `Bidirectional`        | Push/pull behavior.                                                                                       |
| `-RemoteAllowList`              | common Git hosts       | Allowed remote hosts.                                                                                     |
| `-IgnoreGlobs`                  | built-in list          | Exclusion patterns.                                                                                       |
| `-IncludeGlobs`                 | `*`                    | Inclusion patterns.                                                                                       |
| `-ProtectedDeletePaths`         | `.git\*`               | Paths never deleted by destructive propagation logic.                                                     |
| `-SecretRegexes`                | built-in patterns      | Secret detection regexes.                                                                                 |
| `-StateDir`                     | ProgramData path       | State storage root.                                                                                       |
| `-LogDir`                       | ProgramData path       | Log directory.                                                                                            |
| `-MetricCsv`                    | ProgramData path       | CSV metrics file.                                                                                         |
| `-StateFile`                    | ProgramData path       | Persisted sync state.                                                                                     |
| `-QueueFile`                    | ProgramData path       | Persisted operation queue.                                                                                |
| `-StatusFile`                   | ProgramData path       | Status snapshot file.                                                                                     |
| `-ResolutionAuditFile`          | ProgramData path       | Conflict resolution audit journal.                                                                        |
| `-TransactionLogFile`           | ProgramData path       | Operation transaction log.                                                                                |
| `-StructuredLogFile`            | ProgramData path       | Structured JSON log file.                                                                                 |
| `-QuarantineDir`                | ProgramData path       | Quarantine location for dangerous or protected files.                                                     |
| `-ControlInboxDir`              | ProgramData path       | Directory for control commands.                                                                           |
| `-SnapshotDir`                  | ProgramData path       | Periodic local snapshots.                                                                                 |

---

## Conflict Resolution Policies

| Policy         | Behavior                                                                  |
| -------------- | ------------------------------------------------------------------------- |
| `LocalWins`    | Keeps local content (`ours`) during Git conflict resolution.              |
| `RemoteWins`   | Keeps remote content (`theirs`).                                          |
| `NewestCommit` | Compares commit timestamps and keeps the newer side.                      |
| `NewestMTime`  | Compares filesystem last-write time and keeps the newer side.             |
| `HostPriority` | Uses the higher `-HostPriority` value.                                    |
| `ManualFreeze` | Records the conflict and pauses automatic resolution for manual handling. |

### Conflict classes recognized by the engine

* `add_add`
* `modify_modify`
* `delete_modify`
* `modify_delete`
* Git unmerged conflicts detected during rebase/pull

### Recommended for multi-machine use

`HostPriority`

Example:

* desktop: `100`
* laptop: `50`
* server mirror: `200`

---

## How It Works

### High-level pipeline

```text
FileSystemWatcher events
        ↓
Debounce and deduplicate
        ↓
Persist queued operations
        ↓
Periodic full scan fallback
        ↓
Stage local changes
        ↓
fetch origin <branch>
        ↓
pull --rebase --autostash
        ↓
auto-resolve conflicts if policy allows
        ↓
commit local batch
        ↓
push origin <branch>
        ↓
integrity check
        ↓
status/log/metrics update
```

### First-run behavior

* **Empty folder**: clone
* **Non-repo folder with files**: initialize repo, add remote, fetch, create or track branch
* **Existing repo**: reuse it

### Safety mechanisms

* global mutex
* persisted queue and state
* health checks
* repair attempts
* delete threshold protection
* quarantine
* redacted structured logging
* control inbox for pause/resume/stop

---

## Control Commands

If control inbox is enabled, GitAutoSync watches:

```text
C:\ProgramData\GitAutoSync\control
```

Drop a JSON file ending with `.cmd.json`.

### Pause

```json
{ "command": "pause" }
```

### Resume

```json
{ "command": "resume" }
```

### Force sync

```json
{ "command": "force-sync" }
```

### Refresh status

```json
{ "command": "status" }
```

### Stop

```json
{ "command": "stop" }
```

---

## Installation and Scheduling

### Task Scheduler

Program:

```text
powershell.exe
```

Arguments:

```text
-WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\Tools\GitAutoSync_Enterprise_vNext.ps1" -Repo "https://github.com/acme/repo.git" -Root "D:\Sync" -Branch "main" -Profile Workstation -ConflictPolicy HostPriority -HostPriority 100
```

### SCHTASKS

```cmd
SCHTASKS /Create /SC ONLOGON /TN GitAutoSync ^
 /TR "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\Tools\GitAutoSync_Enterprise_vNext.ps1 -Repo https://github.com/acme/repo.git -Root D:\Sync -Branch main -Profile Workstation -ConflictPolicy HostPriority -HostPriority 100"
```

### NSSM

```cmd
nssm install GitAutoSync "powershell.exe" ^
  "-ExecutionPolicy","Bypass","-File","C:\Tools\GitAutoSync_Enterprise_vNext.ps1","-Repo","https://github.com/acme/repo.git","-Root","D:\Sync","-Branch","main","-Profile","Workstation","-ConflictPolicy","HostPriority","-HostPriority","100"
nssm start GitAutoSync
```

### WinSW

Use `powershell.exe` as the executable and pass the same arguments through the WinSW XML configuration.

---

## Advanced Scenarios

| Need                                   | How                                                                                    |
| -------------------------------------- | -------------------------------------------------------------------------------------- |
| **Portable Git**                       | `-GitExe "E:\PortableGit\cmd\git.exe"`                                                 |
| **Corporate proxy**                    | Configure Git globally, for example `git config --global http.proxy http://proxy:8080` |
| **Read-only mirror**                   | `-Profile ReadOnly -SyncDirection PullOnly`                                            |
| **Server mirror**                      | `-Profile Mirror -ConflictPolicy HostPriority -HostPriority 200`                       |
| **Primary workstation wins conflicts** | `-ConflictPolicy HostPriority -HostPriority 100`                                       |
| **Secondary workstation yields**       | `-ConflictPolicy HostPriority -HostPriority 50`                                        |
| **Remote should always win**           | `-ConflictPolicy RemoteWins`                                                           |
| **Dry validation**                     | `-DryRun -VerboseMode`                                                                 |
| **Aggressive detection**               | lower `-DelaySec`, keep watcher enabled                                                |
| **Huge repo**                          | pre-clone shallow if appropriate, raise scan interval, tune exclusions                 |
| **Large binaries**                     | install Git LFS and track relevant extensions before using the synchronizer            |
| **Compliance/audit mode**              | `-ComplianceMode -EnableStructuredJsonLog -EnableEventLog`                             |

---

## Status, Logs, and Metrics

Default files under:

```text
C:\ProgramData\GitAutoSync
```

### Important files

| File                     | Purpose                             |
| ------------------------ | ----------------------------------- |
| `status.json`            | Current runtime state               |
| `state.json`             | Persistent synchronization state    |
| `queue.json`             | Persistent operation queue          |
| `metrics.csv`            | Metrics suitable for parsing/export |
| `transactions.jsonl`     | Operation transaction log           |
| `resolution-audit.jsonl` | Conflict resolution audit trail     |
| `Logs\structured.jsonl`  | Structured logs                     |
| `Quarantine\`            | Safeguarded files                   |
| `snapshots\`             | Periodic snapshots                  |

### Read current status

```powershell
Get-Content "C:\ProgramData\GitAutoSync\status.json" -Raw
```

### Example checks

* last cycle time
* queue length
* current and remote HEAD
* pending conflicts
* last push/pull timestamps
* current runtime state

---

## Troubleshooting

| Issue                                  | Cause                                                       | Fix                                                                                  |
| -------------------------------------- | ----------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| Git prompts for credentials repeatedly | Authentication not configured properly                      | Configure Git Credential Manager or another valid Git auth mechanism on that machine |
| Remote access fails                    | Network, proxy, PAT, or remote URL problem                  | Test with `git ls-remote`, then `git pull` and `git push` manually                   |
| Watcher misses changes                 | Event overflow or burst activity                            | Full scan fallback will recover; tune `-FullScanIntervalSec` and exclusions          |
| Sync pauses after many deletions       | Dangerous delete threshold triggered                        | Inspect state, quarantine, and logs before resuming                                  |
| Conflicts keep recurring               | Two machines are editing the same files at the same time    | Use `HostPriority`, separate roles, or reduce concurrent editing                     |
| `fatal: not a git repository`          | Folder initialization failed or `.git` is damaged           | Re-run initialization, inspect logs, or allow controlled recovery                    |
| Repo lock files remain                 | Previous crash or interrupted Git operation                 | Health check/repair may clear lock files; inspect `.git\*.lock` if needed            |
| Large files slow down sync             | Git not optimized for large binary churn                    | Use Git LFS and adjust thresholds/exclusions                                         |
| Secret scan blocks commits             | File content matches secret detection patterns              | Remove the secret, change patterns carefully, or exclude the file                    |
| High CPU or disk usage                 | Too many files, too-frequent scans, insufficient exclusions | Increase `-DelaySec`, tune `-IgnoreGlobs`, reduce scan pressure                      |

---

## Security and Compliance Notes

* Git credentials are not provisioned automatically. Every machine must already be able to authenticate to the remote.
* `-Encrypt` enables EFS on the root folder.
* Secret scan prevents obvious leaks from being staged automatically.
* Structured logs redact matching secret patterns.
* Remote allowlist prevents accidental synchronization to untrusted hosts.
* Compliance mode configures author metadata and improves audit traceability.
* Conflict resolution decisions are written to an audit journal.
* Transaction and status files provide a verifiable operational trace.

---

## FAQ

### Can multiple PCs run GitAutoSync on the same repo?

Yes. That is a supported scenario. Use the same remote and branch, valid Git credentials on every machine, and a deterministic conflict policy such as `HostPriority`.

### What is the recommended setup for two PCs?

Use `HostPriority`, for example:

* main workstation: `100`
* secondary workstation: `50`

Start the machine that already contains the authoritative local project first if the remote is empty.

### How do I pause synchronization?

Create a JSON control file with:

```json
{ "command": "pause" }
```

### How do I resume?

Create:

```json
{ "command": "resume" }
```

### How do I stop the service cleanly?

Create:

```json
{ "command": "stop" }
```

Or stop the scheduled task, NSSM service, WinSW service, or PowerShell process.

### Can it run as a background service?

Yes. It is designed for Task Scheduler, NSSM, WinSW, or long-running PowerShell sessions.

### Does it support GitHub Enterprise or other Git servers?

Yes, any compatible HTTPS Git remote can work, subject to authentication and remote allowlist policy.

### Is it a full replacement for a distributed file system?

No. It is a Git-based synchronizer with queueing, conflict policies, integrity checks, and recovery controls. It is best suited to Git-friendly project trees.

---

## License

Released under the **MIT License**. See `LICENSE` for details.
