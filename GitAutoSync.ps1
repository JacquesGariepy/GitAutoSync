<# =======================================================================
 GitAutoSync.ps1 – Continuous two‑way synchronisation between a local
 folder and a private (or public) GitHub repository – zero manual steps.
 -----------------------------------------------------------------------
 • Installs Git automatically with winget (silent) if it is missing.
 • First run: clones the repo into $Root (if the folder is empty)
   or initialises + links a pre‑existing folder.
 • Runs an infinite loop:
     1) git add  (all changes, even ignored ones)
     2) git pull --rebase --autostash
     3) git commit --allow-empty
     4) git push
     5) fetch → pull --rebase --autostash (if remote ahead)
 ======================================================================== #>

param(
    [string]$Repo      = $env:GITHUB_REPO,                # https://github.com/org/repo.git
    [string]$Root      = "$env:USERPROFILE\Bridge",
    [string]$Branch    = "main",
    [int]   $DelaySec  = 15,
    [string]$GitExe    = $null,                           # Force a specific git.exe path
    [switch]$Verbose,                                     # Extra console output
    [switch]$InstallGitIfMissing = $true                  # Use winget to install Git
)

# ───────────────────────── 1. Locate or install Git ──────────────────────────
function Install-GitIfNeeded {
    if (-not $InstallGitIfMissing) { return }
    Write-Host "Git not found – installing via winget…" -ForegroundColor Cyan
    $winget = (Get-Command winget -ErrorAction SilentlyContinue).Source
    if (-not $winget) { throw "Git missing and winget not available. Please install Git manually." }
    Start-Process -FilePath $winget -ArgumentList 'install --id Git.Git --source winget --scope User --silent --accept-package-agreements --accept-source-agreements' -Wait -NoNewWindow
    Write-Host "Git installed." -ForegroundColor Green
}

if (-not $GitExe) {
    $pathsToTry = @(
        "$env:ProgramFiles\Git\cmd\git.exe",
        "$env:ProgramFiles(x86)\Git\cmd\git.exe",
        "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe",
        (Get-Command git -ErrorAction SilentlyContinue).Source
    )
    $GitExe = $pathsToTry | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}

if (-not (Test-Path $GitExe)) {
    Install-GitIfNeeded
    $GitExe = (Get-Command git -ErrorAction Stop).Source
}
Write-Host "Using Git executable: $GitExe" -ForegroundColor Yellow

# ───────────────────────── 2. Prepare local folder ───────────────────────────
if (-not (Test-Path $Root)) { New-Item -ItemType Directory -Path $Root | Out-Null }
Set-Location $Root

$hasGit = Test-Path ".git"
if (-not $hasGit) {
    if ((Get-ChildItem -Recurse -Force | Measure-Object).Count -eq 0) {
        if (-not $Repo) { throw "First‑time clone requires -Repo." }
        & $GitExe clone $Repo . | Write-Output
    } else {
        if (-not $Repo) { throw "Cannot initialise: provide -Repo or empty the folder." }
        & $GitExe init
        & $GitExe remote add origin $Repo
        & $GitExe fetch origin $Branch
        try { & $GitExe checkout -b $Branch --track origin/$Branch }
        catch { & $GitExe checkout -b $Branch }
    }
}

# ───────────────────────── 3. Continuous sync loop ───────────────────────────
while ($true) {
    try {
        & $GitExe add -A      # staged & deletions
        & $GitExe add . 2>$null

        $needsCommit = (& $GitExe diff --cached --name-only).Length -gt 0
        if ($needsCommit) {
            & $GitExe pull --rebase --autostash origin $Branch
            & $GitExe commit -m "AutoSync $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" --allow-empty
            & $GitExe push origin $Branch
            if ($Verbose) { Write-Host "[PUSH] $(Get-Date -Format T)" -ForegroundColor Green }
        }

        & $GitExe fetch origin $Branch 2>$null
        $ahead = (& $GitExe rev-list --left-right --count HEAD...origin/$Branch)[1]
        if ($ahead -ne 0) {
            & $GitExe pull --rebase --autostash origin $Branch
            if ($Verbose) { Write-Host "[PULL] $(Get-Date -Format T)" -ForegroundColor Cyan }
        }
    }
    catch {
        Write-Warning "[AutoSync] $($_.Exception.Message)"
    }
    Start-Sleep -Seconds $DelaySec
}
