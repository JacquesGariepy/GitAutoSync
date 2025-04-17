# GitAutoSync &nbsp;– Continuous Local ↔ GitHub Mirroring for Windows

> **Keep a folder and a GitHub repository in perfect two‑way sync, 24/7, with
> zero manual Git commands.**  
> Enterprise‑grade: self‑installs Git, logs to Windows Event Log, prevents
> duplicate instances, supports encryption, metrics, proxies, CI/CD, and more.

---

## Table of Contents
1. [Key Features](#key-features)  
2. [System Requirements](#system-requirements)  
3. [Quick‑Start (60 seconds)](#quick-start-60seconds)  
4. [Command‑Line Reference](#command-line-reference)  
5. [How It Works](#how-it-works)  
6. [Installation & Scheduling](#installation--scheduling)  
7. [Advanced Scenarios](#advanced-scenarios)  
8. [Troubleshooting](#troubleshooting)  
9. [Security & Compliance Notes](#security--compliance-notes)  
10. [FAQ](#faq)  
11. [License](#license)

---

## Key Features
| Category          | Details |
|-------------------|---------|
| **Self‑contained**| Detects `git.exe`; if absent, silently installs **Git for Windows** via **winget** (user scope, no admin rights). |
| **First‑run logic** | • Empty folder → auto‑clone. <br>• Existing non‑repo folder → `git init`, add remote, fetch, checkout. <br>• Existing repo → used as‑is. |
| **Continuous loop**| Adds **all** changes (`add ‑A` + `add .`), commits, pushes; then fetches and pulls when the remote is ahead. |
| **Safe pulls**    | Uses *`git pull --rebase --autostash`* so unstaged edits never block the loop. |
| **Reliability**   | • Global **mutex** (`Global\GitAutoSync`) prevents double execution. <br>• Exponential‑backoff retry for all Git commands. |
| **Observability** | • Rotating transcript logs under `%ProgramData%\GitAutoSync\Logs`. <br>• Error entries in **Windows Event Log** (`Source: GitAutoSync`). <br>• CSV metrics (cycle time, error count) ready for Prometheus / Power BI. |
| **Security options** | • `‑Encrypt` turns on **EFS** encryption for the root folder. <br>• `‑ComplianceMode` enforces `user.name/email`, adds *Signed‑off‑by*, and rejects empty commits. |
| **User switches** | Verbose coloured output, full **dry‑run** mode, configurable delay, custom Git path, proxy friendly. |
| **Packaging ready** | Script is Task‑Scheduler friendly; can be wrapped in MSI or `ps2exe` for mass deployment. |

---

## System Requirements
| Component | Minimum |
|-----------|---------|
| OS        | Windows 10 / 11 (PowerShell 5 or later) |
| GitHub    | Personal Access Token (*repo:contents read/write* or equivalent fine‑grained scope) stored by Git Credential Manager **or** embedded in remote URL for testing. |
| Network   | HTTPS access to `github.com` or your GitHub Enterprise Server. |
| Optional  | **winget** (bundled with modern Windows) for automatic Git install. |

---

## Quick‑Start (60 seconds)

```powershell
# 1 · Store your PAT once (no admin needed)
git credential-manager-core store
  protocol=https
  host=github.com
  username=token
  password=ghp_yourPAThere

# 2 · Pick a folder or create an empty one
$root = "C:\Work\SharedRepo"

# 3 · Launch continuous sync
powershell -ExecutionPolicy Bypass `
  -File C:\GitAutoSync.ps1 `
  -Root  $root `
  -Repo  "https://github.com/your-org/your-repo.git" `
  -Verbose
```

Within one loop (default 15 s) every file you drop into **SharedRepo** is committed
and visible on GitHub; remote commits land back in the folder automatically.

---

## Command‑Line Reference

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `‑Repo` | `$Env:GITHUB_REPO` | HTTPS remote URL (`.git` optional). Mandatory on first run if folder isn’t already a repo. |
| `‑Root` | `%USERPROFILE%\Bridge` | Local directory to mirror (created if missing). |
| `‑Branch` | `main` | Branch to track. |
| `‑DelaySec` | `15` | Loop interval in seconds. |
| `‑GitExe` | auto‑detect | Explicit path to `git.exe` (portable Git, network share, etc.). |
| `‑InstallGitIfMissing` | **true** | Auto‑install Git via winget when absent. Disable with `‑InstallGitIfMissing:$false`. |
| `‑Verbose` | off | Colour output for push/pull cycles. |
| `‑DryRun` | off | Print actions, perform **no** changes (safe test mode). |
| `‑Encrypt` | off | Encrypt `$Root` with Windows EFS on first run. |
| `‑ComplianceMode` | off | Force corporate commit rules (Signed‑off‑by, no empty commit, ensure user/email). |
| `‑RetryMax` | `5` | Maximum retries per Git command before logging an error. |
| `‑LogDir` | `%ProgramData%\GitAutoSync\Logs` | Transcript destination (rotates daily). |
| `‑MetricCsv` | `%ProgramData%\GitAutoSync\metrics.csv` | CSV metrics file path. |
| `‑EventLog` | **true** | Write errors to Windows Event Log (`Application`). |

*All parameters are optional; unset ones fall back as shown.*

---

## How It Works

```
┌────────────────────────────────────────────────────────────────────┐
│   LOOP (every DelaySec seconds)                                   │
│                                                                    │
│  1 · git add -A            \                                       │
│  2 · git add .              > stage EVERYTHING (new/ignored/etc.)  │
│  3 · git pull --rebase --autostash                                 │
│  4 · git commit  (time‑stamped AutoSync message)                   │
│  5 · git push                                                   -> │
│  6 · git fetch + compare ahead; if remote ahead → pull --rebase    │
└────────────────────────────────────────────────────────────────────┘
```

* Untracked or Git‑ignored artefacts are still captured.  
* `--autostash` shelves surprise changes, so `pull --rebase` never aborts.  
* If offline, pushes/pulls retry every cycle until success.

---

## Installation & Scheduling

### Task Scheduler (GUI)

1. **Open** *taskschd.msc* → *Create Task*.  
2. **General** → “Run whether user is logged on or not”, “Run with highest privileges” (optional).  
3. **Triggers** → *At log‑on* (or *On system startup* for service‑style).  
4. **Actions** →  
   ```
   Program/script: powershell.exe
   Arguments    : -WindowStyle Hidden -ExecutionPolicy Bypass `
                  -File "C:\GitAutoSync.ps1" `
                  -Root "D:\Sync" `
                  -Repo "https://github.com/acme/sync.git" `
                  -DelaySec 30 `
                  -Verbose
   ```
5. OK → enter your Windows password to save.

### CLI (SCHTASKS)

```cmd
SCHTASKS /Create /SC ONLOGON /TN "GitAutoSync" ^
        /TR "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\GitAutoSync.ps1 -Root D:\Sync -Repo https://github.com/acme/sync.git"
```

### Service wrapper (nssm)

```
nssm install GitAutoSync "powershell.exe" ^
  "-ExecutionPolicy","Bypass","-File","C:\GitAutoSync.ps1","-Root","D:\Sync"
nssm start GitAutoSync
```

---

## Advanced Scenarios

| Scenario | Command / Tip |
|----------|---------------|
| **Portable Git from USB** | `-GitExe "E:\PortableGit\cmd\git.exe"` |
| **Corporate proxy** | `git config --global http.proxy http://proxy:8080` (script inherits). |
| **Large File Support** | Enable Git LFS once (`git lfs install`) – AutoSync commits LFS pointers transparently. |
| **Encrypt the mirror** | Run the script with `‑Encrypt` on first start; Windows EFS keeps files at rest encrypted. |
| **Compliance guard** | Add `‑ComplianceMode`; blocks empty commits and appends Signed‑off‑by with your Windows user. |
| **Dry‑run test** | `‑DryRun` prints every Git command but doesn’t touch disk or remote. |
| **Metrics integration** | The CSV (`metrics.csv`) can be tailed by *Telegraf*, imported into *Power BI*, or scraped by *Prometheus node‑exporter textfile*. |
| **Auto‑update** | Wrap the script in a self‑updater (compare local hash vs. GitHub release asset, replace, restart). |

---

## Troubleshooting

| Symptom | Cause | Remedy |
|---------|-------|--------|
| *Git prompts for credentials each loop* | PAT not stored | Run `git credential-manager-core store` again, or embed PAT in remote URL for quick test. |
| `cannot pull with rebase: You have unstaged changes` | Locked/readonly files bypass staging | Investigate `git status`; ensure AV doesn’t lock files; `--autostash` normally prevents this. |
| `fatal: not a git repository` on restart | Folder init/clone failed earlier | Delete folder or rerun script with correct `-Repo`, PAT, or proxy. |
| Winget install fails | Company policy blocks winget | Install Git manually (installer or PortableGit) and pass `‑GitExe`; disable auto‑install. |
| High CPU / disk usage | Very low `‑DelaySec` + huge repo | Increase delay or enable shallow clone (`git clone --filter=blob:none --depth 1`) before running script. |

---

## Security & Compliance Notes

* **Credential storage** – relies on Microsoft **Git Credential Manager**, which encrypts secrets in Windows Credential Vault.  
* **Encryption** – toggle `‑Encrypt` to enable **EFS** on `$Root`; only your account can read files at rest.  
* **Audit trail** – every AutoSync commit is time‑stamped; transcripts & Event Log provide additional forensics.  
* **Proxy & TLS inspection** – ensure corporate MITM root CA is in Windows cert store; otherwise GitHub SSL will fail.  
* **Least privilege** – no admin rights needed; Git installs per‑user, script runs under user account or service identity.  

---

## FAQ

**Q : Can I run GitAutoSync on two PCs pointing at the same repo?**  
A : Yes. Each instance commits local changes; the other pulls them on the next cycle. Use `--autostash` (default) to minimise conflict risk.

---

**Q : What happens on a merge conflict?**  
A : The loop pauses; conflicting files contain standard Git markers. Resolve and commit manually—the loop then resumes.

---

**Q : How can I pause sync temporarily?**  
A : Stop the Task Scheduler task (or Windows service). When restarted, pending commits will be pushed.

---

**Q : Does it work with Bitbucket or Azure Repos?**  
A : Yes—as long as the remote is reachable over HTTPS and credentials are handled by Git.

---

## License

**MIT** – free for personal or commercial use.  
Provided **“as‑is”** without warranty; use at your own risk.
