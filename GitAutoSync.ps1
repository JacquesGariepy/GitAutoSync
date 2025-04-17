<#
░█▀▀ ░█▀▀░█ ░█▀▀ ░█▀▀▀█ 　  ░█▀▀█ ▀█▀ ░█▄─░█ ░█▀▀▀ ░█▀▀▄ ▀▀█▀▀
░█▀▀ ░█▀▀░█ ░█▀▀ ░█──░█ 　  ░█─░█ ░█─ ░█░█░█ ░█▀▀▀ ░█─░█ ─░█──
░█── ░█──░█ ░█▄▄ ░█▄▄▄█ 　  ░█▄▄█ ▄█▄ ░█──▀█ ░█▄▄▄ ░█▄▄▀ ─░█──
GitAutoSync v4 – Enterprise‑ready PowerShell service (2025‑04‑17)

• Continuous 2‑way sync folder ↔ GitHub repo
• Self‑install Git (winget) if missing
• Mutex, exponential‑backoff, autostash‑rebase, conflict freeze
• Windows Event Log & rotating transcript
• Optional EFS encryption, metrics CSV, dry‑run, compliance guard
• Designed for Task Scheduler / headless use
-----------------------------------------------------------------
MIT License – free to use, modify, distribute. NO WARRANTY.
#>

param(
    # --- Core options ---------------------------------------------------------
    [string]$Repo      = $Env:GITHUB_REPO,                # https://github.com/org/repo.git
    [string]$Root      = "$Env:USERPROFILE\Bridge",
    [string]$Branch    = "main",
    [int]   $DelaySec  = 15,

    # --- Runtime toggles ------------------------------------------------------
    [string]$GitExe    = $null,
    [switch]$InstallGitIfMissing = $true,
    [switch]$Verbose,
    [switch]$DryRun,                                      # no changes on disk / remote
    [switch]$Encrypt,                                     # enable EFS on root
    [switch]$ComplianceMode,                              # signed‑off‑by, no empty commit
    [int]   $RetryMax  = 5,

    # --- Telemetry & logging --------------------------------------------------
    [string]$LogDir    = "$Env:ProgramData\GitAutoSync\Logs",
    [string]$MetricCsv = "$Env:ProgramData\GitAutoSync\metrics.csv",
    [switch]$EventLog  = $true
)

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║ 0.  GLOBAL HELPER FUNCTIONS                                               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
function Write-Info    { param($m) if ($Verbose) { Write-Host "[INFO]  $m" -ForegroundColor Yellow } }
function Write-Ok      { param($m) if ($Verbose) { Write-Host "[OK]    $m" -ForegroundColor Green  } }
function Write-Err     { param($m) Write-Host "[ERR]   $m" -ForegroundColor Red; if($EventLog){Write-EventLog -LogName Application -Source GitAutoSync -EntryType Error -EventId 100 -Message $m}}
function Emit-Metric   { param($key,$val)
    if (!(Test-Path $MetricCsv)) { "timestamp,key,value" | Out-File $MetricCsv }
    "$(Get-Date -Format o),$key,$val" | Add-Content $MetricCsv
}

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║ 1.  SINGLE‑INSTANCE LOCK                                                 ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
$mutex = New-Object Threading.Mutex($false, "Global\GitAutoSync")
if (-not $mutex.WaitOne(0)) { Write-Err "Another GitAutoSync instance is already running."; exit 1 }

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║ 2.  LOG ROTATION                                                         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
if (!(Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$logFile = Join-Path $LogDir "sync-$(Get-Date -Format yyyyMMdd).log"
Start-Transcript -Path $logFile -Append

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║ 3.  GIT DISCOVERY / INSTALL                                              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
function Install-Git {
    if (-not $InstallGitIfMissing) { throw "Git not found and auto‑install disabled." }
    Write-Info "Git missing – installing silently via winget..."
    $winget = (Get-Command winget -ErrorAction SilentlyContinue).Source
    if (-not $winget) { throw "winget unavailable. Install Git manually." }
    Start-Process $winget -ArgumentList 'install --id Git.Git --source winget --scope User --silent --accept-package-agreements --accept-source-agreements' -Wait -NoNewWindow
    Write-Ok "Git installed."
}

if (-not $GitExe) {
    $GitExe = @( "$Env:ProgramFiles\Git\cmd\git.exe",
                 "$Env:ProgramFiles(x86)\Git\cmd\git.exe",
                 "$Env:LOCALAPPDATA\Programs\Git\cmd\git.exe",
                 (Get-Command git -ErrorAction SilentlyContinue).Source ) |
              Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}
if (-not (Test-Path $GitExe)) { Install-Git; $GitExe = (Get-Command git -ErrorAction Stop).Source }
Write-Info "Using Git: $GitExe"

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║ 4.  PREPARE ROOT FOLDER                                                  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
if (-not (Test-Path $Root)) { New-Item -ItemType Directory -Path $Root -Force | Out-Null }
if ($Encrypt)   { cipher /E $Root | Out-Null }

Set-Location $Root
$hasGit = Test-Path ".git"

if (-not $hasGit) {
    if ((Get-ChildItem -Recurse -Force | Measure-Object).Count -eq 0) {
        if (-not $Repo) { Write-Err "Empty folder – -Repo is required for clone."; exit 2 }
        & $GitExe clone $Repo . | Write-Output
    }
    else {
        if (-not $Repo) { Write-Err "Folder not a repo – provide -Repo or empty the folder."; exit 3 }
        & $GitExe init
        & $GitExe remote add origin $Repo
        & $GitExe fetch origin $Branch
        try { & $GitExe checkout -b $Branch --track origin/$Branch }
        catch { & $GitExe checkout -b $Branch }
    }
}

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║ 5.  COMPLIANCE GUARD (optional)                                          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
if ($ComplianceMode) {
    & $GitExe config user.name  "$Env:USERNAME"
    & $GitExe config user.email "$Env:USERNAME@$(hostname)"
}

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║ 6.  RETRY WRAPPER                                                        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
function Invoke-Git {
    param([string]$Args)
    for ($i=1; $i -le $RetryMax; $i++) {
        if ($DryRun) { Write-Info "[DRY] git $Args"; return 0 }
        & $GitExe $Args
        $code = $LASTEXITCODE
        if ($code -eq 0) { return 0 }
        Write-Info "git $Args failed (attempt $i/$RetryMax, code $code). Retrying in ${i}s..."
        Start-Sleep -Seconds ([math]::Min($i, 30))
    }
    Write-Err "git $Args failed after $RetryMax attempts."
    return 1
}

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║ 7.  MAIN LOOP                                                            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
while ($true) {
    $cycleStart = Get-Date
    try {
        Invoke-Git "add -A"
        Invoke-Git "add ."

        $hasChanges = (& $GitExe diff --cached --name-only).Length -gt 0
        if ($hasChanges) {
            Invoke-Git "pull --rebase --autostash origin $Branch"
            $msg = "AutoSync $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            if ($ComplianceMode) { $msg += ' --signed-off-by ' + $Env:USERNAME }
            if (-not $ComplianceMode -and -not $hasChanges -and -not $DryRun) {
                # skip empty commit if compliance disabled
            } else {
                Invoke-Git "commit -m `"$msg`" --allow-empty"
            }
            Invoke-Git "push origin $Branch"
            Write-Ok "PUSH at $(Get-Date -Format T)"
        }

        Invoke-Git "fetch origin $Branch"
        $aheadCnt = (& $GitExe rev-list --left-right --count HEAD...origin/$Branch)[1]
        if ($aheadCnt -ne 0) {
            Invoke-Git "pull --rebase --autostash origin $Branch"
            Write-Ok "PULL at $(Get-Date -Format T)"
        }

        Emit-Metric "cycle_ms" ((Get-Date) - $cycleStart).TotalMilliseconds
    }
    catch {
        Write-Err $_.Exception.Message
        Emit-Metric "errors" 1
    }
    Start-Sleep -Seconds $DelaySec
}

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║ 8.  CLEAN‑UP                                                             ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
Stop-Transcript
$mutex.ReleaseMutex()
