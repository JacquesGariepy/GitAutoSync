# GitAutoSync – Continuous Local ↔ GitHub Mirroring

> **Sync every file you drop in a folder to a private (or public) repo — no manual Git commands ever again.**

---

## Table of Contents
1. [Key Features](#key-features)  
2. [System Requirements](#system-requirements)  
3. [One‑Minute Quick‑Start](#one-minute-quick-start)  
4. [All Command‑Line Options](#all-command-line-options)  
5. [How It Works](#how-it-works)  
6. [Installing & Running Automatically](#installing--running-automatically)  
7. [Advanced Scenarios](#advanced-scenarios)  
8. [Troubleshooting Guide](#troubleshooting-guide)  
9. [Security & Compliance](#security--compliance)  
10. [FAQ](#faq)  
11. [License](#license)

---

## Key Features
| Capability | Details |
|------------|---------|
| **Zero‑touch install** | Detects `git.exe`; if missing, silently installs latest Git for Windows via **winget** (user scope, no admin). |
| **First‑run smarts** | • Empty folder → automatic `clone`.<br>• Folder with files → `git init`, set *origin*, fetch, checkout.<br>• Existing repo → uses as‑is. |
| **Realtime loop** | Adds **all** changes (new, modified, deleted, ignored), commits, pushes.<br>Pulls any upstream commits on every cycle. |
| **Safe pulls** | Uses `pull --rebase --autostash` — never blocks on “unstaged changes”. |
| **Customisable** | Override root path, repo URL, branch, loop delay, commit message, Git executable, proxy, log verbosity. |
| **Headless scheduling** | Designed for Task Scheduler / Group Policy Run‑keys / `shell:startup`. |
| **Verbose telemetry** | Optional colour messages for each push/pull with timestamps. |
| **Self‑healing** | Recovers from network drops; retries on next iteration. |
| **Works offline** | Commits accumulate locally; pushes once connectivity is back. |
| **Portable‑Git friendly** | Accepts any `git.exe` path (USB stick, network share, chocolatey, MSYS2). |

---

## System Requirements
|            | Minimum |
|------------|---------|
| **OS**     | Windows 10/11 (PowerShell 5+). |
| **Network**| HTTPS access to `github.com` (or your GHES). |
| **GitHub** | Personal Access Token (classic or fine‑grained) with **`repo`** → *contents: read/write*. |
| **Optional** | `winget` (bundled in Win 10/11) for automatic Git installation. |

> **Note:** behind a corporate proxy, configure `git config --global http.proxy` first.

---

## One‑Minute Quick‑Start

1. **Store your PAT once**  
   ```powershell
   git credential-manager-core store
   # protocol=https / host=github.com / username=token / password=ghp_***
   ```

2. **Create (or choose) a folder**, e.g. `C:\Work\SharedRepo`.

3. **Run GitAutoSync** (PowerShell):
   ```powershell
   powershell -ExecutionPolicy Bypass `
     -File C:\GitAutoSync.ps1 `
     -Root "C:\Work\SharedRepo" `
     -Repo "https://github.com/your‑org/your‑repo.git"
   ```
   > After ~15 s any file you drop into `SharedRepo` is committed & visible on GitHub.

---

## All Command‑Line Options

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `‑Repo` | `$Env:GITHUB_REPO` | HTTPS URL to repo. Needed on first run if folder isn’t already a repo. |
| `‑Root` | `%USERPROFILE%\Bridge` | Local directory to mirror. Created if missing. |
| `‑Branch` | `main` | Branch to follow. Auto‑creates if absent locally. |
| `‑DelaySec` | `15` | Loop interval in seconds. Use higher values on low‑power devices. |
| `‑GitExe` | *auto‑detect* | Explicit path for custom / portable Git. |
| `‑InstallGitIfMissing` | **true** | Toggle silent winget install. Use `‑InstallGitIfMissing:$false` to disable. |
| `‑Verbose` | off | Colour log lines for every push (`[PUSH]`) and pull (`[PULL]`). |

> Any switch can be set permanently with environment variables or Task Scheduler arguments.

---

## How It Works

```text
          ┌─ (Loop every X s) ──────────────────────────────────────┐
  Local ⇆ │ 1. git add -A  &  git add .   → Stage EVERY change      │
  Folder  │ 2. git pull --rebase --autostash  ← remote/main         │
          │ 3. git commit -m "AutoSync YYYY‑MM‑DD HH:MM:SS"         │
          │ 4. git push origin <branch>                             │
          │ 5. git fetch + compare ahead count → pull if remote > 0 │
          └──────────────────────────────────────────────────────────┘
```

* All untracked & ignored files are captured thanks to the dual `git add`.  
* `--autostash` temporarily shelves surprise edits, so pulls never abort.  
* If network is down, steps 2 & 4 fail silently; next cycle retries.

---

## Installing & Running Automatically

### Task Scheduler (recommended)

1. *Create Task* → General → “Run whether user is logged on or not”.  
2. Trigger → *At log‑on*.  
3. Action →  
   ```
   Program/script: powershell.exe
   Arguments    : -WindowStyle Hidden -ExecutionPolicy Bypass `
                   -File "C:\GitAutoSync.ps1" `
                   -Root "D:\Sync" `
                   -Repo "https://github.com/acme/sync.git" `
                   -DelaySec 30
   ```

### Group Policy / Logon Script

Add the same command string to *User Configuration → Windows Settings → Scripts (Logon)*.

### `shell:startup`

Drop a `.bat` or shortcut into the Startup folder invoking the same PowerShell command.

---

## Advanced Scenarios

### 1. Using **Git Portable** from USB

```powershell
powershell -ExecutionPolicy Bypass `
  -File GitAutoSync.ps1 `
  -Root "E:\Docs" `
  -Repo "https://github.com/org/docs.git" `
  -GitExe "F:\PortableGit\cmd\git.exe"
```

### 2. Large binaries → Git LFS

Enable LFS on the repo (`git lfs install`) once; the script pushes LFS pointers transparently.

### 3. Custom commit message template

Set env var `GITAUTOSYNC_PREFIX="💾 Sync"` → script prefixes every commit message.

### 4. Shallow clone for huge repos

Pre‑clone manually with `--depth 1`, then run GitAutoSync (it respects existing config).

### 5. Service‑style run via **nssm**

```
nssm install GitAutoSyncService "powershell.exe" ^
  "-ExecutionPolicy","Bypass","-File","C:\GitAutoSync.ps1","-Root","D:\Sync"
nssm start GitAutoSyncService
```

### 6. Mirror to **GitHub Enterprise Server**

Just use your GHES URL. PAT scopes are identical.

---

## Troubleshooting Guide

| Issue | Reason | Fix |
|-------|--------|-----|
| *Git keeps asking for username/password* | PAT not stored | Run `git credential-manager-core store` or embed PAT in remote URL (for testing). |
| `cannot pull with rebase: You have unstaged changes` | Line‑ending re‑writes, locked files | Turns rare with `--autostash`; if it appears, check file permissions, global `.gitignore`, or set `core.autocrlf`. |
| `fatal: not a git repository` on restart | Folder created but clone failed (auth/proxy) | Delete folder or re‑run with correct PAT, proxy, or `‑Repo`. |
| Winget install fails | No Internet or policy blocks | Install Git manually (PortableGit zip) and pass `‑GitExe`. |
| Corporate proxy blocks GitHub | HTTPS MITM | `git config --global http.proxy http://proxy:8080` or whitelist GitHub. |
| High CPU on tight loop | Delay too low | Increase `‑DelaySec` to 60‑120 s. |

---

## Security & Compliance

* **Credential storage** – relies on Microsoft Git Credential Manager (encrypted in Windows Credential Vault).  
* **Winget silent mode** – uses `--accept-package-agreements` to conform with enterprise policies.  
* **Least privilege** – no admin rights required; installs Git under user scope.  
* **Audit trail** – every commit carries timestamp + machine identity (Git user.name/email).  
* **Exclusions** – add `*.log`, `.DS_Store`, temp folders to `.gitignore` as needed.

---

## FAQ

**Q : Can I synchronise two PCs both running GitAutoSync?**  
A : Yes. Each instance commits its local changes; the other fetches and pulls them on the next cycle.

**Q : What happens during merge conflicts?**  
A : Rare, because each instance rebases its work. If a conflict occurs, the loop pauses with git’s standard conflict markers. Resolve, commit, the loop resumes.

**Q : Can I disable the auto Git install?**  
A : Run with `‑InstallGitIfMissing:$false` and supply `‑GitExe` or ensure Git is on PATH.

**Q : Does it work with Bitbucket or Azure DevOps?**  
A : Yes. Any HTTPS remote accepted by Git works, provided credentials are handled.

---

## License

**MIT** – free for personal or commercial use; provided “as‑is” without warranty.
