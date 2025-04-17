```markdown
# GitAutoSync v6
*Autonomous bidirectional folder ⇆ Git(Hub/Enterprise) synchroniser for Windows*  
Released **2025‑04‑17** &nbsp;•&nbsp; Licence [MIT](#licence)

> Effortlessly mirrors every change between a local directory and any HTTPS Git
> remote. Handles installation, conflicts, logging, encryption, auditing — and
> keeps running as a background service.

---

## Table of Contents
1. [Key Features](#key-features)  
2. [System Requirements](#system-requirements)  
3. [Quick‑Start (under 60 s)](#quick-start-under-60-s)  
4. [Command‑Line Reference](#command-line-reference)  
5. [Unattended Conflict Resolution Policies](#unattended-conflict-resolution-policies)  
6. [How It Works](#how-it-works)  
7. [Installation & Scheduling](#installation--scheduling)  
8. [Advanced Scenarios](#advanced-scenarios)  
9. [Troubleshooting](#troubleshooting)  
10. [Security & Compliance Notes](#security--compliance-notes)  
11. [FAQ](#faq)  
12. [Licence](#licence)

---

## Key Features
| | |
|---|---|
| **Self‑contained** | Detects `git.exe`; if absent, silently installs **Git for Windows** via **winget** (user scope). |
| **Trusted single service** | Global mutex prevents duplicate instances. |
| **Smart first run** | Empty folder → auto‑clone.<br>Non‑repo folder → `git init`, add remote, fetch, checkout.<br>Existing repo → re‑use. |
| **Continuous loop** | Adds **all** changes (`add ‑A` + `add .`), commits, pushes, then fetches & pulls when the remote is ahead. |
| **Autostash safe‑pull** | Uses `git pull --rebase --autostash` – local edits never block the loop. |
| **Automatic conflict solver** | Configurable `‑ConflictPolicy` (LocalWins • RemoteWins • NewestCommit • NewestMTime • HostPriority). |
| **Observability** | Rotating transcripts `<ProgramData>\GitAutoSync\Logs`, Windows **Event Log**, CSV metrics. |
| **Security toggles** | EFS encryption (`‑Encrypt`), compliance guard (Signed‑off‑by, no empty commit), dry‑run mode. |
| **Proxy & portable friendly** | Inherits global Git proxy; accepts any custom `git.exe` path. |

---

## System Requirements
| Component | Minimum |
|---|---|
| **OS** | Windows 10/11 with PowerShell 5+. |
| **Git remote** | PAT with *repo → contents read/write* stored by Git Credential Manager **or** embedded in remote URL. |
| **Network** | HTTPS access to GitHub/ GHES / Bitbucket / Azure Repos. |
| **Optional** | `winget` for auto‑installation (bundled with modern Windows). |

---

## Quick‑Start (under 60 s)

```powershell
# 1 · Store your PAT once
git credential-manager-core store
  protocol=https
  host=github.com
  username=token
  password=ghp_yourTokenHere

# 2 · Choose the folder to sync
$root = "D:\Sync"

# 3 · Run GitAutoSync
powershell -ExecutionPolicy Bypass `
  -File C:\GitAutoSync.ps1 `
  -Root  $root `
  -Repo  "https://github.com/your‑org/your‑repo.git" `
  -Verbose
```

Within 15 s every file in **D:\Sync** is pushed to GitHub; remote commits flow
back automatically.

---

## Command‑Line Reference

| Parameter | Default | Description |
|-----------|---------|-------------|
| `‑Repo` | `$Env:GITHUB_REPO` | Remote HTTPS URL (`.git` optional). Required on first run when folder isn’t already a repo. |
| `‑Root` | `%USERPROFILE%\Bridge` | Local directory to mirror (auto‑created). |
| `‑Branch` | `main` | Branch to track. |
| `‑DelaySec` | `15` | Loop interval (seconds). |
| `‑GitExe` | auto | Custom path to *git.exe* (portable version, network share…). |
| `‑InstallGitIfMissing` | **true** | Use **winget** to install Git if not found. Disable with `‑InstallGitIfMissing:$false`. |
| `‑Verbose` | off | Colour logs for each push/pull. |
| `‑DryRun` | off | Simulate, no modifications. |
| `‑Encrypt` | off | Enable EFS encryption on `‑Root`. |
| `‑ComplianceMode` | off | Set `user.name/email`; add Signed‑off‑by; block empty commits. |
| `‑RetryMax` | `5` | Max retries for each Git command. |
| `‑ConflictPolicy` | `LocalWins` | Conflict strategy (see below). |
| `‑HostPriority` | `0` | Integer priority for *HostPriority* policy. |
| `‑LogDir` | ProgramData path | Transcript directory. |
| `‑MetricCsv` | `metrics.csv` | CSV metrics file. |
| `‑EventLog` | **true** | Log errors to Windows Event Log. |

---

## Unattended Conflict Resolution Policies

| Policy | Rule when same line edited both sides |
|---|---|
| `LocalWins` (default) | Keep local version (ours). |
| `RemoteWins` | Keep remote version (theirs). |
| `NewestCommit` | Compare Git commit timestamp; keep newer commit. |
| `NewestMTime` | Compare filesystem last‑write time; keep newer file. |
| `HostPriority` | Higher `‑HostPriority` value wins (ties favour remote). |

If auto‑resolution fails (rare binary conflict), the loop pauses; manual
resolution then `git rebase --continue` resumes normal operation.

---

## How It Works

```
add -A + add .     ➜  stage *everything*
pull --rebase --autostash
└─ if exit ≠ 0  ➜ auto‑resolve conflicts  ➜ rebase --continue
commit   "AutoSync <timestamp>"
push
fetch + ahead? ➜ pull --rebase --autostash (with auto‑resolve if needed)
```

*Autostash* avoids “unstaged changes” errors; retries with exponential back‑off
handle flaky networks.

---

## Installation & Scheduling

<details>
<summary><strong>Task Scheduler (GUI)</strong></summary>

1. **Create Task** → run with highest privileges (optional).  
2. Trigger : **At log‑on** (or **On startup** for a service).  
3. Action :

```text
Program/script : powershell.exe
Arguments      : -WindowStyle Hidden -ExecutionPolicy Bypass `
                 -File "C:\GitAutoSync.ps1" `
                 -Root "D:\Sync" `
                 -Repo "https://github.com/acme/repo.git" `
                 -ConflictPolicy HostPriority -HostPriority 50
```
</details>

<details>
<summary><strong>SCHTASKS CLI</strong></summary>

```cmd
SCHTASKS /Create /SC ONLOGON /TN GitAutoSync ^
 /TR "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\GitAutoSync.ps1 -Root D:\Sync -Repo https://github.com/acme/repo.git"
```
</details>

<details>
<summary><strong>Run as Windows service (nssm)</strong></summary>

```cmd
nssm install GitAutoSync "powershell.exe" ^
  "-ExecutionPolicy","Bypass","-File","C:\GitAutoSync.ps1","-Root","D:\Sync"
nssm start GitAutoSync
```
</details>

---

## Advanced Scenarios

| Need | How |
|------|-----|
| Portable Git on USB | `‑GitExe "E:\PortableGit\cmd\git.exe"` |
| Corporate proxy | `git config --global http.proxy http://proxy:8080` |
| Shallow clone for huge repo | Pre‑clone with `--depth 1 --filter=blob:none`, then run script. |
| Kiosk: remote overwrites edits | `‑ConflictPolicy RemoteWins` |
| Priority matrix | Server `‑HostPriority 100`, laptops 10; use `HostPriority` policy. |
| Dry run validation | `‑DryRun -Verbose` |
| Metrics to Prometheus | Point node‑exporter textfile collector to `metrics.csv`. |

---

## Troubleshooting

| Issue | Cause | Fix |
|---|---|---|
| Git asks for credentials each loop | PAT not stored | Re‑run `git credential-manager-core store`. |
| “unstaged changes” pull error | File locked by AV | Ensure autostash (default) ; check AV exclusions. |
| `fatal: not a git repository` | Previous clone failed | Delete folder or rerun with correct parameters. |
| winget blocked | Policy prohibits | Manually install Git; set `‑GitExe`; disable auto‑install. |
| High CPU on huge repo | Delay too low | Increase `‑DelaySec` or use shallow clone. |

---

## Security & Compliance Notes
* **Credentials** stored by Git Credential Manager → encrypted in Windows vault.
* `‑Encrypt` turns on EFS so only the account/service can read files at rest.
* `‑ComplianceMode` enforces corporate commit hygiene.
* Logs + Event‑Log provide audit trail.

---

## FAQ

**Can multiple PCs run GitAutoSync on the same repo ?**  
Yes. Each instance re‑bases and pushes; conflicts settle via your chosen policy.

**How to pause sync ?**  
Stop/disable the Task Scheduler task or service; restart to resume.

**Other Git servers ?**  
Any HTTPS Git remote works (GitHub, GHES, Bitbucket, Azure Repos, Gitea…).

---

## Licence
Released under the **MIT Licence** — see `LICENSE` file for details.
```
