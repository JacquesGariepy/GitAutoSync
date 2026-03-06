<#
GitAutoSync - use at your own risk                                       
#>

[CmdletBinding()]
param(
    [string]$Repo = $env:GITHUB_REPO,
    [string]$Root = "$env:USERPROFILE\Bridge",
    [string]$Branch = "main",
    [ValidateSet('Workstation','Server','ReadOnly','Mirror','LocalPriority','RemotePriority')]
    [string]$Profile = 'Workstation',
    [int]$DelaySec = 15,
    [int]$FullScanIntervalSec = 300,
    [int]$DebounceMs = 1500,
    [string]$GitExe = $null,
    [switch]$InstallGitIfMissing = $true,
    [switch]$VerboseMode,
    [switch]$DryRun,
    [switch]$Encrypt,
    [switch]$ComplianceMode,
    [switch]$ReadOnlyMode,
    [switch]$EnableWatcher = $true,
    [switch]$EnableControlInbox = $true,
    [switch]$EnableEventLog = $true,
    [switch]$EnableStructuredJsonLog = $true,
    [switch]$EnablePeriodicIntegrityCheck = $true,
    [switch]$EnableSecretScan = $true,
    [switch]$AllowAutoRepair = $true,
    [switch]$AllowAutoReclone = $false,
    [int]$RetryMax = 5,
    [int]$RetryBaseSeconds = 2,
    [int]$BatchWindowSec = 8,
    [int]$NetworkFailurePauseSec = 60,
    [int]$DangerousDeleteThreshold = 50,
    [int]$LargeFileThresholdMB = 50,
    [int]$MaxFilesPerCycle = 5000,
    [int]$MaxQueueItems = 50000,
    [int]$HealthCheckEveryCycles = 20,
    [ValidateSet('LocalWins','RemoteWins','NewestCommit','NewestMTime','HostPriority','ManualFreeze')]
    [string]$ConflictPolicy = 'LocalWins',
    [int]$HostPriority = 0,
    [ValidateSet('EventuallyConsistent','NearRealtime','MirrorReplica')]
    [string]$SyncModel = 'EventuallyConsistent',
    [ValidateSet('Bidirectional','PushOnly','PullOnly')]
    [string]$SyncDirection = 'Bidirectional',
    [string[]]$RemoteAllowList = @('github.com','ssh.dev.azure.com','dev.azure.com','gitlab.com'),
    [string[]]$IgnoreGlobs = @('.git\*','*.tmp','*.temp','~$*','*.lock','Thumbs.db','.DS_Store','node_modules\*','bin\*','obj\*','.vs\*','.idea\*'),
    [string[]]$IncludeGlobs = @('*'),
    [string[]]$ProtectedDeletePaths = @('.git\*'),
    [string[]]$SecretRegexes = @(
        'ghp_[A-Za-z0-9]{36,}',
        'github_pat_[A-Za-z0-9_]{20,}',
        'AKIA[0-9A-Z]{16}',
        '(?i)-----BEGIN (RSA|DSA|EC|OPENSSH|PGP) PRIVATE KEY-----',
        '(?i)(password|passwd|pwd|secret|token|apikey|api_key)\s*[:=]\s*[^\s]+'
    ),
    [string]$StateDir = "$env:ProgramData\GitAutoSync",
    [string]$LogDir = "$env:ProgramData\GitAutoSync\Logs",
    [string]$MetricCsv = "$env:ProgramData\GitAutoSync\metrics.csv",
    [string]$StateFile = "$env:ProgramData\GitAutoSync\state.json",
    [string]$QueueFile = "$env:ProgramData\GitAutoSync\queue.json",
    [string]$StatusFile = "$env:ProgramData\GitAutoSync\status.json",
    [string]$ResolutionAuditFile = "$env:ProgramData\GitAutoSync\resolution-audit.jsonl",
    [string]$TransactionLogFile = "$env:ProgramData\GitAutoSync\transactions.jsonl",
    [string]$StructuredLogFile = "$env:ProgramData\GitAutoSync\Logs\structured.jsonl",
    [string]$QuarantineDir = "$env:ProgramData\GitAutoSync\Quarantine",
    [string]$ControlInboxDir = "$env:ProgramData\GitAutoSync\control",
    [string]$SnapshotDir = "$env:ProgramData\GitAutoSync\snapshots"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Globals
$script:Version = 'vNext-1.0'
$script:InstanceId = [guid]::NewGuid().Guid
$script:HostName = $env:COMPUTERNAME
$script:StopRequested = $false
$script:Cycle = 0
$script:LastFullScanUtc = [datetime]::MinValue
$script:LastNetworkFailureUtc = $null
$script:LastWatcherEventUtc = [datetime]::MinValue
$script:Watcher = $null
$script:WatcherHandlers = @()
$script:FSWBuffer = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
$script:Mutex = $null
$script:CurrentBackoffSec = $RetryBaseSeconds
$script:RecentSyncWrites = [System.Collections.Concurrent.ConcurrentDictionary[string,datetime]]::new()
$script:PendingRenames = [System.Collections.Concurrent.ConcurrentDictionary[string,hashtable]]::new()
$script:StateLock = New-Object object
$script:QueueLock = New-Object object
$script:State = $null
$script:Queue = $null
$script:Status = $null
#endregion Globals

#region Utility
function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-ConsoleInfo { param([string]$Message) if ($VerboseMode) { Write-Host "[INFO] $Message" -ForegroundColor Yellow } }
function Write-ConsoleOk   { param([string]$Message) if ($VerboseMode) { Write-Host "[ OK ] $Message" -ForegroundColor Green } }
function Write-ConsoleWarn { param([string]$Message) Write-Host "[WARN] $Message" -ForegroundColor DarkYellow }
function Write-ConsoleErr  { param([string]$Message) Write-Host "[ERR ] $Message" -ForegroundColor Red }

function Redact-Text {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }
    $t = $Text
    foreach ($rx in $SecretRegexes) {
        try { $t = [regex]::Replace($t, $rx, '[REDACTED]') } catch {}
    }
    if ($Repo) {
        try {
            $uri = [Uri]$Repo
            if ($uri.UserInfo) {
                $u = [regex]::Escape($uri.UserInfo)
                $t = [regex]::Replace($t, $u, '[REDACTED-USERINFO]')
            }
        } catch {}
    }
    return $t
}

function Write-StructuredLog {
    param(
        [ValidateSet('debug','info','warn','error')][string]$Level,
        [string]$Event,
        [hashtable]$Data = @{}
    )
    $payload = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        level = $Level
        event = $Event
        cycle = $script:Cycle
        instance_id = $script:InstanceId
        host = $script:HostName
        version = $script:Version
        data = $Data
    }
    $line = ($payload | ConvertTo-Json -Depth 10 -Compress)
    if ($EnableStructuredJsonLog) {
        Add-Content -LiteralPath $StructuredLogFile -Value (Redact-Text $line)
    }
}

function Write-AppLog {
    param(
        [ValidateSet('INFO','WARN','ERROR','DEBUG')][string]$Level,
        [string]$Message,
        [int]$EventId = 1000,
        [hashtable]$Data = @{}
    )
    $safe = Redact-Text $Message
    switch ($Level) {
        'INFO'  { Write-ConsoleInfo $safe }
        'WARN'  { Write-ConsoleWarn $safe }
        'ERROR' { Write-ConsoleErr  $safe }
        'DEBUG' { if ($VerboseMode) { Write-Host "[DBG ] $safe" -ForegroundColor DarkCyan } }
    }
    Write-StructuredLog -Level ($Level.ToLower()) -Event $safe -Data $Data
    if ($EnableEventLog) {
        try {
            if (-not [System.Diagnostics.EventLog]::SourceExists('GitAutoSync')) {
                try { New-EventLog -LogName Application -Source 'GitAutoSync' } catch {}
            }
            if ([System.Diagnostics.EventLog]::SourceExists('GitAutoSync')) {
                $etype = switch ($Level) {
                    'INFO' {'Information'}
                    'WARN' {'Warning'}
                    default {'Error'}
                }
                Write-EventLog -LogName Application -Source 'GitAutoSync' -EntryType $etype -EventId $EventId -Message $safe
            }
        } catch {}
    }
}

function Write-Metric {
    param([string]$Key, [object]$Value)
    if (-not (Test-Path -LiteralPath $MetricCsv)) {
        'timestamp,key,val' | Out-File -LiteralPath $MetricCsv -Encoding utf8
    }
    $line = '{0},{1},{2}' -f (Get-Date).ToString('o'), $Key, ($Value -replace ',', ';')
    Add-Content -LiteralPath $MetricCsv -Value $line
}

function ConvertTo-NormalizedRelativePath {
    param([Parameter(Mandatory)][string]$FullPath)
    $rootNormalized = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $fullNormalized = [IO.Path]::GetFullPath($FullPath)
    if ($fullNormalized.StartsWith($rootNormalized, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rel = $fullNormalized.Substring($rootNormalized.Length)
    } else {
        $rel = $fullNormalized
    }
    $rel = $rel -replace '/', '\'
    return $rel.TrimStart('\')
}

function Test-GlobMatch {
    param([string]$RelativePath, [string[]]$Globs)
    foreach ($g in $Globs) {
        $pattern = '^' + ([regex]::Escape($g).Replace('\*','.*').Replace('\?','.')) + '$'
        if ($RelativePath -imatch $pattern) { return $true }
    }
    return $false
}

function Test-IgnoredPath {
    param([string]$RelativePath)
    if (Test-GlobMatch -RelativePath $RelativePath -Globs $ProtectedDeletePaths) { return $true }
    if (-not (Test-GlobMatch -RelativePath $RelativePath -Globs $IncludeGlobs)) { return $true }
    if (Test-GlobMatch -RelativePath $RelativePath -Globs $IgnoreGlobs) { return $true }
    return $false
}

function Get-FileHashSafe {
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    } catch {
        return $null
    }
}

function Get-FileTypeStrategy {
    param([string]$RelativePath)
    $ext = [IO.Path]::GetExtension($RelativePath).ToLowerInvariant()
    switch ($ext) {
        '.txt' { 'text' }
        '.md'  { 'text' }
        '.ps1' { 'text' }
        '.psm1' { 'text' }
        '.json' { 'text' }
        '.xml' { 'text' }
        '.yml' { 'text' }
        '.yaml' { 'text' }
        '.cs' { 'text' }
        '.vb' { 'text' }
        '.ts' { 'text' }
        '.tsx' { 'text' }
        '.js' { 'text' }
        '.jsx' { 'text' }
        '.docx' { 'binary' }
        '.xlsx' { 'binary' }
        '.pptx' { 'binary' }
        '.zip' { 'binary' }
        '.db' { 'blocked' }
        '.sqlite' { 'blocked' }
        default { 'auto' }
    }
}

function Test-RecentSelfWrite {
    param([string]$RelativePath)
    if ($script:RecentSyncWrites.ContainsKey($RelativePath)) {
        $dt = $script:RecentSyncWrites[$RelativePath]
        if (((Get-Date) - $dt).TotalSeconds -lt 5) { return $true }
        $null = $script:RecentSyncWrites.TryRemove($RelativePath, [ref]$dt)
    }
    return $false
}

function Mark-RecentSelfWrite {
    param([string]$RelativePath)
    $script:RecentSyncWrites[$RelativePath] = Get-Date
}

function Save-JsonFile {
    param([string]$Path, [object]$Object)
    $tmp = "$Path.tmp"
    $Object | ConvertTo-Json -Depth 20 | Out-File -LiteralPath $tmp -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Append-JsonLine {
    param([string]$Path, [hashtable]$Object)
    Add-Content -LiteralPath $Path -Value (($Object | ConvertTo-Json -Depth 15 -Compress))
}
#endregion Utility

#region Persistent State
function New-DefaultState {
    return [ordered]@{
        schema_version = 1
        repo = $Repo
        root = $Root
        branch = $Branch
        profile = $Profile
        sync_model = $SyncModel
        sync_direction = $SyncDirection
        instance_history = @()
        last_start_utc = $null
        last_successful_cycle_utc = $null
        last_integrity_check_utc = $null
        last_full_scan_utc = $null
        network_state = 'unknown'
        files = @{}
        pending_conflicts = @{}
        quarantined = @{}
        last_remote_head = $null
        last_local_head = $null
        last_cycle_id = $null
    }
}

function Load-State {
    if (Test-Path -LiteralPath $StateFile) {
        try {
            return (Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json -Depth 25 | ConvertTo-Hashtable)
        } catch {
            Write-AppLog -Level ERROR -Message "State file corrupted. Creating backup and reinitializing." -EventId 1101
            Copy-Item -LiteralPath $StateFile -Destination ($StateFile + '.corrupt.' + (Get-Date -Format yyyyMMddHHmmss)) -Force
        }
    }
    return (New-DefaultState)
}

function Save-State {
    [System.Threading.Monitor]::Enter($script:StateLock)
    try {
        Save-JsonFile -Path $StateFile -Object $script:State
    } finally {
        [System.Threading.Monitor]::Exit($script:StateLock)
    }
}

function New-DefaultQueue {
    return [ordered]@{
        schema_version = 1
        items = @()
    }
}

function Load-Queue {
    if (Test-Path -LiteralPath $QueueFile) {
        try {
            return (Get-Content -LiteralPath $QueueFile -Raw | ConvertFrom-Json -Depth 25 | ConvertTo-Hashtable)
        } catch {
            Write-AppLog -Level ERROR -Message "Queue file corrupted. Reinitializing queue." -EventId 1102
            Copy-Item -LiteralPath $QueueFile -Destination ($QueueFile + '.corrupt.' + (Get-Date -Format yyyyMMddHHmmss)) -Force
        }
    }
    return (New-DefaultQueue)
}

function Save-Queue {
    [System.Threading.Monitor]::Enter($script:QueueLock)
    try {
        if ($script:Queue.items.Count -gt $MaxQueueItems) {
            throw "Queue overflow: $($script:Queue.items.Count) > $MaxQueueItems"
        }
        Save-JsonFile -Path $QueueFile -Object $script:Queue
    } finally {
        [System.Threading.Monitor]::Exit($script:QueueLock)
    }
}

function Initialize-Status {
    $script:Status = [ordered]@{
        version = $script:Version
        started_utc = (Get-Date).ToString('o')
        last_cycle_utc = $null
        cycle = 0
        state = 'starting'
        queue_length = 0
        last_error = $null
        last_successful_push_utc = $null
        last_successful_pull_utc = $null
        last_integrity_check_utc = $null
        network_state = 'unknown'
        repo_health = 'unknown'
        current_head = $null
        remote_head = $null
        pending_conflicts = 0
        pending_local_changes = 0
        host = $script:HostName
        instance_id = $script:InstanceId
        dry_run = [bool]$DryRun
        sync_model = $SyncModel
        sync_direction = $SyncDirection
    }
    Save-JsonFile -Path $StatusFile -Object $script:Status
}

function Save-Status {
    $script:Status.queue_length = $script:Queue.items.Count
    $script:Status.pending_conflicts = $script:State.pending_conflicts.Count
    $script:Status.cycle = $script:Cycle
    $script:Status.network_state = $script:State.network_state
    Save-JsonFile -Path $StatusFile -Object $script:Status
}

function ConvertTo-Hashtable {
    param([Parameter(ValueFromPipeline=$true)]$InputObject)
    process {
        if ($null -eq $InputObject) { return $null }
        if ($InputObject -is [System.Collections.IDictionary]) {
            $h = @{}
            foreach ($k in $InputObject.Keys) {
                $h[$k] = ConvertTo-Hashtable $InputObject[$k]
            }
            return $h
        }
        if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
            $list = @()
            foreach ($item in $InputObject) { $list += ,(ConvertTo-Hashtable $item) }
            return $list
        }
        if ($InputObject.PSObject -and $InputObject.PSObject.Properties.Count -gt 0) {
            $h = @{}
            foreach ($p in $InputObject.PSObject.Properties) {
                $h[$p.Name] = ConvertTo-Hashtable $p.Value
            }
            return $h
        }
        return $InputObject
    }
}
#endregion Persistent State

#region Transaction Queue
function Enqueue-Op {
    param(
        [Parameter(Mandatory)][string]$Type,
        [hashtable]$Payload = @{},
        [int]$Priority = 100
    )
    [System.Threading.Monitor]::Enter($script:QueueLock)
    try {
        $item = [ordered]@{
            id = [guid]::NewGuid().Guid
            type = $Type
            payload = $Payload
            created_utc = (Get-Date).ToString('o')
            status = 'pending'
            priority = $Priority
            retries = 0
        }
        $script:Queue.items += $item
        $script:Queue.items = @($script:Queue.items | Sort-Object priority, created_utc)
        Save-Queue
        Append-JsonLine -Path $TransactionLogFile -Object @{ timestamp=(Get-Date).ToString('o'); op='enqueue'; item=$item }
        return $item
    } finally {
        [System.Threading.Monitor]::Exit($script:QueueLock)
    }
}

function Complete-Op {
    param([string]$Id, [string]$Result = 'success', [string]$ErrorMessage = $null)
    [System.Threading.Monitor]::Enter($script:QueueLock)
    try {
        foreach ($i in $script:Queue.items) {
            if ($i.id -eq $Id) {
                $i.status = $Result
                $i.completed_utc = (Get-Date).ToString('o')
                if ($ErrorMessage) { $i.error = $ErrorMessage }
                break
            }
        }
        $script:Queue.items = @($script:Queue.items | Where-Object { $_.status -eq 'pending' -or $_.status -eq 'running' })
        Save-Queue
        Append-JsonLine -Path $TransactionLogFile -Object @{ timestamp=(Get-Date).ToString('o'); op='complete'; id=$Id; result=$Result; error=$ErrorMessage }
    } finally {
        [System.Threading.Monitor]::Exit($script:QueueLock)
    }
}

function Get-NextOps {
    param([int]$Max = 200)
    [System.Threading.Monitor]::Enter($script:QueueLock)
    try {
        $pending = @($script:Queue.items | Where-Object { $_.status -eq 'pending' } | Sort-Object priority, created_utc | Select-Object -First $Max)
        foreach ($p in $pending) { $p.status = 'running'; $p.started_utc = (Get-Date).ToString('o') }
        Save-Queue
        return $pending
    } finally {
        [System.Threading.Monitor]::Exit($script:QueueLock)
    }
}
#endregion Transaction Queue

#region Profiles / Semantics
function Apply-ProfileDefaults {
    switch ($Profile) {
        'ReadOnly' {
            $script:Status.state = 'readonly'
            $script:State.sync_direction = 'PullOnly'
        }
        'Mirror' {
            $script:State.sync_model = 'MirrorReplica'
        }
        'LocalPriority' {
            $script:State.sync_direction = 'Bidirectional'
            if ($ConflictPolicy -eq 'RemoteWins') { $script:State.conflict_policy_effective = 'LocalWins' }
        }
        'RemotePriority' {
            $script:State.sync_direction = 'Bidirectional'
            if ($ConflictPolicy -eq 'LocalWins') { $script:State.conflict_policy_effective = 'RemoteWins' }
        }
        default { }
    }
}
#endregion Profiles / Semantics

#region Git
function Install-Git {
    if (-not $InstallGitIfMissing) { throw 'Git not found and auto-install disabled.' }
    $winget = (Get-Command winget -ErrorAction SilentlyContinue).Source
    if (-not $winget) { throw 'winget unavailable. Install Git manually.' }
    Write-AppLog -Level INFO -Message 'Installing Git via winget.' -EventId 1201
    if (-not $DryRun) {
        $p = Start-Process -FilePath $winget -ArgumentList 'install --id Git.Git --scope User --silent --accept-package-agreements --accept-source-agreements' -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -ne 0) { throw "winget install failed: $($p.ExitCode)" }
    }
}

function Resolve-GitExe {
    if ($GitExe -and (Test-Path -LiteralPath $GitExe)) { return $GitExe }
    $candidates = @(
        "$env:ProgramFiles\Git\cmd\git.exe",
        "$env:ProgramFiles(x86)\Git\cmd\git.exe",
        "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe"
    )
    $cmd = Get-Command git -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }
    $found = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if (-not $found) {
        Install-Git
        $cmd2 = Get-Command git -ErrorAction Stop
        $found = $cmd2.Source
    }
    return $found
}

function Test-RemoteAllowed {
    if (-not $Repo) { return $false }
    foreach ($allowed in $RemoteAllowList) {
        if ($Repo -match [regex]::Escape($allowed)) { return $true }
    }
    return $false
}

function Invoke-Git {
    param(
        [Parameter(Mandatory)][string[]]$Args,
        [switch]$IgnoreFailure,
        [int]$MaxAttempts = $RetryMax
    )
    $joined = ($Args -join ' ')
    if ($DryRun) {
        Write-AppLog -Level INFO -Message "[DRY] git $joined" -EventId 1202
        return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
    }
    $attempt = 0
    $last = $null
    while ($attempt -lt $MaxAttempts) {
        $attempt++
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:Git
        $psi.WorkingDirectory = $Root
        foreach ($a in $Args) { [void]$psi.ArgumentList.Add($a) }
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        $last = [pscustomobject]@{ ExitCode = $proc.ExitCode; StdOut = $stdout; StdErr = $stderr; Args = $Args }
        if ($proc.ExitCode -eq 0) {
            return $last
        }
        $combined = (($stdout + "`n" + $stderr).Trim())
        Write-AppLog -Level WARN -Message "git $joined failed attempt $attempt/$MaxAttempts: $combined" -EventId 1203
        Start-Sleep -Seconds ([Math]::Min(60, $RetryBaseSeconds * [Math]::Pow(2, [Math]::Min($attempt, 5)) + (Get-Random -Minimum 0 -Maximum 3)))
    }
    if (-not $IgnoreFailure) {
        throw "git $joined failed after $MaxAttempts attempts. $($last.StdErr)"
    }
    return $last
}

function Get-CurrentHead {
    try { return (Invoke-Git -Args @('rev-parse','HEAD') -MaxAttempts 1).StdOut.Trim() } catch { return $null }
}

function Get-RemoteHead {
    try { return (Invoke-Git -Args @('rev-parse',"origin/$Branch") -MaxAttempts 1).StdOut.Trim() } catch { return $null }
}

function Ensure-GitRepo {
    if (-not (Test-RemoteAllowed)) {
        throw "Remote repo not in allowlist: $Repo"
    }
    if (-not (Test-Path -LiteralPath $Root)) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
    }
    if ($Encrypt) {
        try { cipher /E $Root | Out-Null } catch { Write-AppLog -Level WARN -Message 'EFS encryption could not be applied.' -EventId 1204 }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Root '.git'))) {
        $nonRepoHasFiles = ((Get-ChildItem -LiteralPath $Root -Force -Recurse -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0)
        if (-not $Repo) { throw '-Repo required for initialization.' }
        if (-not $nonRepoHasFiles) {
            Invoke-Git -Args @('clone',$Repo,'.') | Out-Null
        } else {
            Invoke-Git -Args @('init') | Out-Null
            try { Invoke-Git -Args @('remote','remove','origin') -IgnoreFailure | Out-Null } catch {}
            Invoke-Git -Args @('remote','add','origin',$Repo) | Out-Null
            Invoke-Git -Args @('fetch','origin',$Branch) -IgnoreFailure | Out-Null
            $checkout = Invoke-Git -Args @('checkout','-b',$Branch,'--track',"origin/$Branch") -IgnoreFailure
            if ($checkout.ExitCode -ne 0) {
                Invoke-Git -Args @('checkout','-b',$Branch) | Out-Null
            }
        }
    }
    if ($ComplianceMode) {
        Invoke-Git -Args @('config','user.name',$env:USERNAME) -IgnoreFailure | Out-Null
        Invoke-Git -Args @('config','user.email',"$($env:USERNAME)@$($env:COMPUTERNAME)") -IgnoreFailure | Out-Null
    }
}

function Test-RepoHealth {
    $issues = @()
    try {
        if (-not (Test-Path -LiteralPath (Join-Path $Root '.git'))) { $issues += 'missing_git_dir' }
        $status = Invoke-Git -Args @('status','--porcelain=v1') -IgnoreFailure -MaxAttempts 1
        if ($status.ExitCode -ne 0) { $issues += 'status_failed' }
        $remote = Invoke-Git -Args @('remote','get-url','origin') -IgnoreFailure -MaxAttempts 1
        if ($remote.ExitCode -ne 0) { $issues += 'missing_remote_origin' }
        $branchCheck = Invoke-Git -Args @('rev-parse','--verify',$Branch) -IgnoreFailure -MaxAttempts 1
        if ($branchCheck.ExitCode -ne 0) { $issues += 'missing_local_branch' }
        $fsck = Invoke-Git -Args @('fsck','--no-reflogs') -IgnoreFailure -MaxAttempts 1
        if ($fsck.ExitCode -ne 0) { $issues += 'fsck_failed' }
        $lockFiles = Get-ChildItem -LiteralPath (Join-Path $Root '.git') -Filter '*.lock' -Force -ErrorAction SilentlyContinue
        if ($lockFiles) { $issues += 'git_lock_present' }
    } catch {
        $issues += 'repo_health_exception'
    }
    if ($issues.Count -eq 0) {
        $script:Status.repo_health = 'healthy'
        return $true
    }
    $script:Status.repo_health = ($issues -join ',')
    Write-AppLog -Level WARN -Message ("Repository health issues: " + ($issues -join ', ')) -EventId 1205
    if ($AllowAutoRepair) {
        Invoke-ControlledRepair -Issues $issues
    }
    return $false
}

function Invoke-ControlledRepair {
    param([string[]]$Issues)
    Write-AppLog -Level WARN -Message ('Attempting controlled repair: ' + ($Issues -join ', ')) -EventId 1206
    try {
        if ($Issues -contains 'git_lock_present') {
            Get-ChildItem -LiteralPath (Join-Path $Root '.git') -Filter '*.lock' -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        }
        Invoke-Git -Args @('gc','--prune=now') -IgnoreFailure -MaxAttempts 1 | Out-Null
        Invoke-Git -Args @('remote','prune','origin') -IgnoreFailure -MaxAttempts 1 | Out-Null
    } catch {
        Write-AppLog -Level ERROR -Message ('Controlled repair failed: ' + $_.Exception.Message) -EventId 1207
    }
}
#endregion Git

#region Secret Scan / Large Files / Normalization
function Test-FileForSecrets {
    param([string]$Path)
    if (-not $EnableSecretScan) { return $false }
    try {
        $fi = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($fi.Length -gt 2MB) { return $false }
        $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        foreach ($rx in $SecretRegexes) {
            if ($text -match $rx) { return $true }
        }
    } catch {}
    return $false
}

function Test-LargeFile {
    param([string]$Path)
    try {
        $fi = Get-Item -LiteralPath $Path -ErrorAction Stop
        return ($fi.Length -ge ($LargeFileThresholdMB * 1MB))
    } catch {
        return $false
    }
}

function Normalize-WorkingTreeSettings {
    Invoke-Git -Args @('config','core.autocrlf','false') -IgnoreFailure -MaxAttempts 1 | Out-Null
    Invoke-Git -Args @('config','core.longpaths','true') -IgnoreFailure -MaxAttempts 1 | Out-Null
    Invoke-Git -Args @('config','core.quotepath','false') -IgnoreFailure -MaxAttempts 1 | Out-Null
}
#endregion Secret Scan / Large Files / Normalization

#region Snapshot / Scan / Rename detection
function Get-LocalSnapshot {
    $files = @{}
    $all = Get-ChildItem -LiteralPath $Root -Force -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First $MaxFilesPerCycle
    foreach ($f in $all) {
        $rel = ConvertTo-NormalizedRelativePath -FullPath $f.FullName
        if ($rel.StartsWith('.git\', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        if (Test-IgnoredPath -RelativePath $rel) { continue }
        $strategy = Get-FileTypeStrategy -RelativePath $rel
        $files[$rel] = [ordered]@{
            path = $rel
            size = $f.Length
            mtime_utc = $f.LastWriteTimeUtc.ToString('o')
            hash = if ($strategy -eq 'binary' -and $f.Length -gt 20MB) { $null } else { Get-FileHashSafe -Path $f.FullName }
            exists = $true
            strategy = $strategy
            readonly = $f.IsReadOnly
        }
    }
    return $files
}

function Save-Snapshot {
    param([hashtable]$Snapshot)
    Ensure-Directory -Path $SnapshotDir
    $name = Join-Path $SnapshotDir ('snapshot-' + (Get-Date -Format yyyyMMddHHmmss) + '.json')
    Save-JsonFile -Path $name -Object $Snapshot
}

function Compare-Snapshots {
    param([hashtable]$OldSnapshot, [hashtable]$NewSnapshot)
    $changes = [ordered]@{ added=@(); modified=@(); deleted=@(); renamed=@() }
    $oldKeys = @($OldSnapshot.Keys)
    $newKeys = @($NewSnapshot.Keys)
    foreach ($k in $newKeys) {
        if (-not $OldSnapshot.ContainsKey($k)) {
            $changes.added += $k
        } else {
            $o = $OldSnapshot[$k]
            $n = $NewSnapshot[$k]
            if (($o.hash -and $n.hash -and $o.hash -ne $n.hash) -or ($o.mtime_utc -ne $n.mtime_utc) -or ($o.size -ne $n.size)) {
                $changes.modified += $k
            }
        }
    }
    foreach ($k in $oldKeys) {
        if (-not $NewSnapshot.ContainsKey($k)) { $changes.deleted += $k }
    }

    # rename heuristic using exact hash among deleted vs added
    $addedLookup = @{}
    foreach ($a in $changes.added) {
        $h = $NewSnapshot[$a].hash
        if ($h) { if (-not $addedLookup.ContainsKey($h)) { $addedLookup[$h] = @() }; $addedLookup[$h] += $a }
    }
    $stillAdded = New-Object System.Collections.ArrayList
    [void]$stillAdded.AddRange($changes.added)
    $stillDeleted = New-Object System.Collections.ArrayList
    [void]$stillDeleted.AddRange($changes.deleted)
    foreach ($d in @($changes.deleted)) {
        $h = $OldSnapshot[$d].hash
        if ($h -and $addedLookup.ContainsKey($h) -and $addedLookup[$h].Count -gt 0) {
            $newPath = $addedLookup[$h][0]
            $changes.renamed += @{ old = $d; new = $newPath; hash = $h }
            [void]$stillDeleted.Remove($d)
            [void]$stillAdded.Remove($newPath)
            $addedLookup[$h] = @($addedLookup[$h] | Where-Object { $_ -ne $newPath })
        }
    }
    $changes.added = @($stillAdded)
    $changes.deleted = @($stillDeleted)
    return $changes
}
#endregion Snapshot / Scan / Rename detection

#region Watcher
function Start-RootWatcher {
    if (-not $EnableWatcher) { return }
    $script:Watcher = New-Object IO.FileSystemWatcher $Root, '*'
    $script:Watcher.IncludeSubdirectories = $true
    $script:Watcher.EnableRaisingEvents = $true
    $script:Watcher.InternalBufferSize = 65536

    $handler = {
        param($sender, $eventArgs)
        try {
            $full = $eventArgs.FullPath
            if (-not $full) { return }
            $rel = ConvertTo-NormalizedRelativePath -FullPath $full
            if ([string]::IsNullOrWhiteSpace($rel)) { return }
            if ($rel.StartsWith('.git\', [System.StringComparison]::OrdinalIgnoreCase)) { return }
            if (Test-IgnoredPath -RelativePath $rel) { return }
            if (Test-RecentSelfWrite -RelativePath $rel) { return }
            $script:FSWBuffer.Enqueue([ordered]@{
                time_utc = (Get-Date).ToString('o')
                type = $eventArgs.ChangeType.ToString()
                full = $full
                rel = $rel
            })
            $script:LastWatcherEventUtc = Get-Date
        } catch {}
    }
    $renamed = {
        param($sender, $eventArgs)
        try {
            $oldRel = ConvertTo-NormalizedRelativePath -FullPath $eventArgs.OldFullPath
            $newRel = ConvertTo-NormalizedRelativePath -FullPath $eventArgs.FullPath
            if (Test-IgnoredPath -RelativePath $oldRel -and Test-IgnoredPath -RelativePath $newRel) { return }
            $script:FSWBuffer.Enqueue([ordered]@{
                time_utc = (Get-Date).ToString('o')
                type = 'Renamed'
                old_rel = $oldRel
                rel = $newRel
                full = $eventArgs.FullPath
            })
            $script:LastWatcherEventUtc = Get-Date
        } catch {}
    }
    $errorHandler = {
        Write-AppLog -Level WARN -Message 'FileSystemWatcher overflow or error detected. Scheduling full scan.' -EventId 1301
        Enqueue-Op -Type 'full_scan' -Priority 1 | Out-Null
    }

    $script:WatcherHandlers += Register-ObjectEvent -InputObject $script:Watcher -EventName Changed -Action $handler
    $script:WatcherHandlers += Register-ObjectEvent -InputObject $script:Watcher -EventName Created -Action $handler
    $script:WatcherHandlers += Register-ObjectEvent -InputObject $script:Watcher -EventName Deleted -Action $handler
    $script:WatcherHandlers += Register-ObjectEvent -InputObject $script:Watcher -EventName Renamed -Action $renamed
    $script:WatcherHandlers += Register-ObjectEvent -InputObject $script:Watcher -EventName Error   -Action $errorHandler
}

function Stop-RootWatcher {
    foreach ($h in $script:WatcherHandlers) {
        try { Unregister-Event -SubscriptionId $h.Id -ErrorAction SilentlyContinue } catch {}
        try { Remove-Job -Id $h.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
    $script:WatcherHandlers = @()
    if ($script:Watcher) {
        try { $script:Watcher.EnableRaisingEvents = $false; $script:Watcher.Dispose() } catch {}
        $script:Watcher = $null
    }
}

function Drain-WatcherBuffer {
    $events = @()
    while ($true) {
        $item = $null
        if (-not $script:FSWBuffer.TryDequeue([ref]$item)) { break }
        $events += $item
    }
    if ($events.Count -eq 0) { return @() }

    # debounce and deduplicate by rel+type
    Start-Sleep -Milliseconds $DebounceMs
    while ($true) {
        $item = $null
        if (-not $script:FSWBuffer.TryDequeue([ref]$item)) { break }
        $events += $item
    }
    $dedup = @{}
    foreach ($e in $events) {
        $key = if ($e.type -eq 'Renamed') { "R|$($e.old_rel)|$($e.rel)" } else { "$($e.type)|$($e.rel)" }
        $dedup[$key] = $e
    }
    return @($dedup.Values)
}
#endregion Watcher

#region Conflict Detection / Resolution
function Get-ConflictType {
    param(
        [string]$RelativePath,
        [bool]$LocalExists,
        [bool]$RemoteExists,
        [bool]$BaseExists,
        [string]$LocalHash,
        [string]$RemoteHash,
        [string]$BaseHash
    )
    if (-not $BaseExists -and $LocalExists -and $RemoteExists -and $LocalHash -ne $RemoteHash) { return 'add_add' }
    if ($BaseExists -and -not $LocalExists -and $RemoteExists) { return 'delete_modify' }
    if ($BaseExists -and $LocalExists -and -not $RemoteExists) { return 'modify_delete' }
    if ($BaseExists -and $LocalExists -and $RemoteExists -and $LocalHash -ne $RemoteHash -and $LocalHash -ne $BaseHash -and $RemoteHash -ne $BaseHash) { return 'modify_modify' }
    return 'none'
}

function Audit-Resolution {
    param([string]$Path,[string]$ConflictType,[string]$Decision,[hashtable]$Extra)
    Append-JsonLine -Path $ResolutionAuditFile -Object @{
        timestamp = (Get-Date).ToString('o')
        path = $Path
        conflict_type = $ConflictType
        decision = $Decision
        host = $script:HostName
        instance_id = $script:InstanceId
        policy = $ConflictPolicy
        extra = $Extra
    }
}

function Resolve-GitConflictFile {
    param([string]$RelativePath,[string]$ConflictType)
    $decision = $null
    switch ($ConflictPolicy) {
        'LocalWins' {
            Invoke-Git -Args @('checkout','--ours','--',$RelativePath) | Out-Null
            Invoke-Git -Args @('add','--',$RelativePath) | Out-Null
            $decision = 'ours'
        }
        'RemoteWins' {
            Invoke-Git -Args @('checkout','--theirs','--',$RelativePath) | Out-Null
            Invoke-Git -Args @('add','--',$RelativePath) | Out-Null
            $decision = 'theirs'
        }
        'NewestCommit' {
            $l = Invoke-Git -Args @('log','-1','--format=%ct','--',$RelativePath) -IgnoreFailure -MaxAttempts 1
            $r = Invoke-Git -Args @('log','-1','--format=%ct',"origin/$Branch",'--',$RelativePath) -IgnoreFailure -MaxAttempts 1
            $lt = [int]([string]::IsNullOrWhiteSpace($l.StdOut) ? '0' : $l.StdOut.Trim())
            $rt = [int]([string]::IsNullOrWhiteSpace($r.StdOut) ? '0' : $r.StdOut.Trim())
            if ($lt -ge $rt) {
                Invoke-Git -Args @('checkout','--ours','--',$RelativePath) | Out-Null
                $decision = 'ours'
            } else {
                Invoke-Git -Args @('checkout','--theirs','--',$RelativePath) | Out-Null
                $decision = 'theirs'
            }
            Invoke-Git -Args @('add','--',$RelativePath) | Out-Null
        }
        'NewestMTime' {
            $full = Join-Path $Root $RelativePath
            $localM = if (Test-Path -LiteralPath $full) { (Get-Item -LiteralPath $full).LastWriteTimeUtc } else { [datetime]::MinValue }
            $tmp = Join-Path $env:TEMP ('gas-' + [IO.Path]::GetRandomFileName())
            try {
                if (-not $DryRun) {
                    $show = Invoke-Git -Args @('show',":$RelativePath") -IgnoreFailure -MaxAttempts 1
                    if ($show.ExitCode -eq 0) { $show.StdOut | Out-File -LiteralPath $tmp -Encoding utf8 }
                }
                $remoteM = if (Test-Path -LiteralPath $tmp) { (Get-Item -LiteralPath $tmp).LastWriteTimeUtc } else { [datetime]::MinValue }
                if ($localM -ge $remoteM) {
                    Invoke-Git -Args @('checkout','--ours','--',$RelativePath) | Out-Null
                    $decision = 'ours'
                } else {
                    Invoke-Git -Args @('checkout','--theirs','--',$RelativePath) | Out-Null
                    $decision = 'theirs'
                }
                Invoke-Git -Args @('add','--',$RelativePath) | Out-Null
            } finally {
                if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
            }
        }
        'HostPriority' {
            $remoteMsg = Invoke-Git -Args @('log','-1','--format=%B',"origin/$Branch",'--',$RelativePath) -IgnoreFailure -MaxAttempts 1
            $matches = [regex]::Match($remoteMsg.StdOut,'HostPriority=(\d+)')
            $remotePriority = if ($matches.Success) { [int]$matches.Groups[1].Value } else { 0 }
            if ($HostPriority -ge $remotePriority) {
                Invoke-Git -Args @('checkout','--ours','--',$RelativePath) | Out-Null
                $decision = 'ours'
            } else {
                Invoke-Git -Args @('checkout','--theirs','--',$RelativePath) | Out-Null
                $decision = 'theirs'
            }
            Invoke-Git -Args @('add','--',$RelativePath) | Out-Null
        }
        'ManualFreeze' {
            $script:State.pending_conflicts[$RelativePath] = @{ type = $ConflictType; detected_utc = (Get-Date).ToString('o') }
            Audit-Resolution -Path $RelativePath -ConflictType $ConflictType -Decision 'manual_freeze' -Extra @{}
            return $false
        }
    }
    Audit-Resolution -Path $RelativePath -ConflictType $ConflictType -Decision $decision -Extra @{}
    return $true
}

function Auto-Resolve-RebaseConflicts {
    $conflictList = Invoke-Git -Args @('diff','--name-only','--diff-filter=U') -IgnoreFailure -MaxAttempts 1
    $paths = @($conflictList.StdOut -split "`r?`n" | Where-Object { $_ })
    if ($paths.Count -eq 0) { return $true }
    foreach ($p in $paths) {
        $ok = Resolve-GitConflictFile -RelativePath $p -ConflictType 'git_unmerged'
        if (-not $ok) { return $false }
    }
    Invoke-Git -Args @('rebase','--continue') -IgnoreFailure | Out-Null
    return $true
}
#endregion Conflict Detection / Resolution

#region Dangerous Deletes / Quarantine
function Quarantine-Path {
    param([string]$RelativePath)
    $src = Join-Path $Root $RelativePath
    if (-not (Test-Path -LiteralPath $src)) { return }
    Ensure-Directory -Path $QuarantineDir
    $dest = Join-Path $QuarantineDir ((Get-Date -Format yyyyMMddHHmmss) + '__' + ($RelativePath -replace '[\\/:*?"<>|]','_'))
    Move-Item -LiteralPath $src -Destination $dest -Force
    $script:State.quarantined[$RelativePath] = @{ moved_to = $dest; utc = (Get-Date).ToString('o') }
    Write-AppLog -Level WARN -Message "Moved to quarantine: $RelativePath" -EventId 1401
}

function Protect-DangerousDeletes {
    param([string[]]$DeletedPaths)
    if ($DeletedPaths.Count -lt $DangerousDeleteThreshold) { return $true }
    Write-AppLog -Level ERROR -Message "Dangerous delete threshold exceeded: $($DeletedPaths.Count) deletions. Entering safe pause." -EventId 1402
    foreach ($p in $DeletedPaths | Select-Object -First 100) {
        if (-not (Test-IgnoredPath -RelativePath $p)) {
            $full = Join-Path $Root $p
            if (Test-Path -LiteralPath $full) { Quarantine-Path -RelativePath $p }
        }
    }
    $script:Status.state = 'paused_dangerous_delete'
    Save-Status
    return $false
}
#endregion Dangerous Deletes / Quarantine

#region Network / Control Inbox
function Test-NetworkAndRemote {
    try {
        $r = Invoke-Git -Args @('ls-remote','--heads','origin',$Branch) -IgnoreFailure -MaxAttempts 1
        if ($r.ExitCode -eq 0) {
            $script:State.network_state = 'online'
            return $true
        }
    } catch {}
    $script:State.network_state = 'offline'
    return $false
}

function Ensure-ControlInbox {
    if ($EnableControlInbox) { Ensure-Directory -Path $ControlInboxDir }
}

function Process-ControlInbox {
    if (-not $EnableControlInbox) { return }
    $files = Get-ChildItem -LiteralPath $ControlInboxDir -Filter '*.cmd.json' -File -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        try {
            $cmd = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
            switch ($cmd.command) {
                'pause' { $script:Status.state = 'paused_manual'; Write-AppLog -Level WARN -Message 'Paused by control inbox.' -EventId 1501 }
                'resume' { $script:Status.state = 'running'; Write-AppLog -Level INFO -Message 'Resumed by control inbox.' -EventId 1502 }
                'force-sync' { Enqueue-Op -Type 'full_scan' -Priority 1 | Out-Null; Enqueue-Op -Type 'sync_cycle' -Priority 1 | Out-Null }
                'status' { Save-Status }
                'stop' { $script:StopRequested = $true }
                default { Write-AppLog -Level WARN -Message ("Unknown control command: " + $cmd.command) -EventId 1503 }
            }
        } catch {
            Write-AppLog -Level ERROR -Message ("Failed control command: " + $_.Exception.Message) -EventId 1504
        } finally {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}
#endregion Network / Control Inbox

#region Working Tree Decision Engine
function Update-StateFromSnapshot {
    param([hashtable]$Snapshot)
    foreach ($k in $Snapshot.Keys) {
        $script:State.files[$k] = $Snapshot[$k]
        $script:State.files[$k].last_seen_cycle = $script:Cycle
    }
    $stateKeys = @($script:State.files.Keys)
    foreach ($k in $stateKeys) {
        if (-not $Snapshot.ContainsKey($k)) {
            $script:State.files[$k].exists = $false
            $script:State.files[$k].deleted_seen_cycle = $script:Cycle
        }
    }
}

function Enqueue-ChangesFromSnapshotDiff {
    param([hashtable]$Diff,[hashtable]$Snapshot)
    foreach ($p in $Diff.added) {
        Enqueue-Op -Type 'local_add' -Payload @{ path=$p; file=$Snapshot[$p] } -Priority 50 | Out-Null
    }
    foreach ($p in $Diff.modified) {
        Enqueue-Op -Type 'local_modify' -Payload @{ path=$p; file=$Snapshot[$p] } -Priority 50 | Out-Null
    }
    foreach ($p in $Diff.deleted) {
        Enqueue-Op -Type 'local_delete' -Payload @{ path=$p } -Priority 50 | Out-Null
    }
    foreach ($r in $Diff.renamed) {
        Enqueue-Op -Type 'local_rename' -Payload @{ old=$r.old; new=$r.new; hash=$r.hash } -Priority 40 | Out-Null
    }
}

function Scan-WorkingTree {
    $oldSnapshot = @{}
    foreach ($k in $script:State.files.Keys) {
        if ($script:State.files[$k].exists) {
            $oldSnapshot[$k] = $script:State.files[$k]
        }
    }
    $newSnapshot = Get-LocalSnapshot
    $diff = Compare-Snapshots -OldSnapshot $oldSnapshot -NewSnapshot $newSnapshot
    if (-not (Protect-DangerousDeletes -DeletedPaths $diff.deleted)) {
        return
    }
    Update-StateFromSnapshot -Snapshot $newSnapshot
    Enqueue-ChangesFromSnapshotDiff -Diff $diff -Snapshot $newSnapshot
    $script:State.last_full_scan_utc = (Get-Date).ToString('o')
    $script:LastFullScanUtc = Get-Date
    Save-State
    Save-Snapshot -Snapshot $newSnapshot
    Write-Metric -Key 'scan_added' -Value $diff.added.Count
    Write-Metric -Key 'scan_modified' -Value $diff.modified.Count
    Write-Metric -Key 'scan_deleted' -Value $diff.deleted.Count
    Write-Metric -Key 'scan_renamed' -Value $diff.renamed.Count
}

function Stage-LocalChange {
    param([string]$RelativePath)
    if (Test-IgnoredPath -RelativePath $RelativePath) { return }
    $full = Join-Path $Root $RelativePath
    $strategy = Get-FileTypeStrategy -RelativePath $RelativePath
    if ($strategy -eq 'blocked') {
        Write-AppLog -Level WARN -Message "Blocked file type not staged: $RelativePath" -EventId 1601
        return
    }
    if (Test-Path -LiteralPath $full) {
        if (Test-FileForSecrets -Path $full) {
            Write-AppLog -Level ERROR -Message "Potential secret detected; refusing stage: $RelativePath" -EventId 1602
            return
        }
        if (Test-LargeFile -Path $full) {
            Write-AppLog -Level WARN -Message "Large file detected: $RelativePath. Consider Git LFS." -EventId 1603
        }
    }
    Invoke-Git -Args @('add','--',$RelativePath) | Out-Null
}

function Stage-DeleteChange {
    param([string]$RelativePath)
    Invoke-Git -Args @('rm','--ignore-unmatch','--',$RelativePath) -IgnoreFailure | Out-Null
}

function Stage-RenameChange {
    param([string]$OldPath,[string]$NewPath)
    if (Test-Path -LiteralPath (Join-Path $Root $OldPath)) {
        Invoke-Git -Args @('mv','--',$OldPath,$NewPath) -IgnoreFailure | Out-Null
    } else {
        Invoke-Git -Args @('add','--',$NewPath) -IgnoreFailure | Out-Null
        Invoke-Git -Args @('rm','--ignore-unmatch','--',$OldPath) -IgnoreFailure | Out-Null
    }
}
#endregion Working Tree Decision Engine

#region Sync Operations
function Get-QueuedChangeSummary {
    $pending = @($script:Queue.items | Where-Object { $_.status -eq 'pending' -and $_.type -like 'local_*' })
    return [ordered]@{
        adds = @($pending | Where-Object type -eq 'local_add').Count
        modifies = @($pending | Where-Object type -eq 'local_modify').Count
        deletes = @($pending | Where-Object type -eq 'local_delete').Count
        renames = @($pending | Where-Object type -eq 'local_rename').Count
    }
}

function Invoke-PrePullFetch {
    if (-not (Test-NetworkAndRemote)) {
        Write-AppLog -Level WARN -Message 'Remote unavailable. Queue retained for later.' -EventId 1701
        return $false
    }
    Invoke-Git -Args @('fetch','origin',$Branch) | Out-Null
    $script:Status.remote_head = Get-RemoteHead
    return $true
}

function Pull-RemoteChanges {
    if ($ReadOnlyMode -or $SyncDirection -eq 'PushOnly') { return }
    $res = Invoke-Git -Args @('pull','--rebase','--autostash','origin',$Branch) -IgnoreFailure
    if ($res.ExitCode -ne 0) {
        $ok = Auto-Resolve-RebaseConflicts
        if (-not $ok) { throw 'Conflict unresolved during pull/rebase.' }
    }
    $script:Status.last_successful_pull_utc = (Get-Date).ToString('o')
}

function Commit-LocalBatch {
    param([hashtable]$Summary)
    $hasStaged = (Invoke-Git -Args @('diff','--cached','--name-only') -MaxAttempts 1).StdOut.Trim()
    if ([string]::IsNullOrWhiteSpace($hasStaged)) { return $false }
    $msg = "AutoSync $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') host=$($script:HostName) instance=$($script:InstanceId) HostPriority=$HostPriority adds=$($Summary.adds) mods=$($Summary.modifies) dels=$($Summary.deletes) renames=$($Summary.renames)"
    if ($ComplianceMode) { $msg += " Signed-off-by: $($env:USERNAME)" }
    Invoke-Git -Args @('commit','-m',$msg) -IgnoreFailure | Out-Null
    return $true
}

function Push-LocalChanges {
    if ($ReadOnlyMode -or $SyncDirection -eq 'PullOnly') { return }
    Invoke-Git -Args @('push','origin',$Branch) | Out-Null
    $script:Status.last_successful_push_utc = (Get-Date).ToString('o')
}

function Verify-Integrity {
    if (-not $EnablePeriodicIntegrityCheck) { return }
    $local = Get-CurrentHead
    $remote = Get-RemoteHead
    $script:Status.current_head = $local
    $script:Status.remote_head = $remote
    $script:State.last_local_head = $local
    $script:State.last_remote_head = $remote
    if ($SyncDirection -eq 'Bidirectional' -or $SyncDirection -eq 'PushOnly') {
        if ($local -and $remote -and $local -ne $remote) {
            Write-AppLog -Level WARN -Message "Integrity mismatch local HEAD != remote HEAD ($local != $remote)" -EventId 1702
        }
    }
    $script:State.last_integrity_check_utc = (Get-Date).ToString('o')
    $script:Status.last_integrity_check_utc = $script:State.last_integrity_check_utc
}

function Process-QueuedOps {
    $ops = Get-NextOps -Max 500
    $summary = Get-QueuedChangeSummary
    foreach ($op in $ops) {
        try {
            switch ($op.type) {
                'full_scan' { Scan-WorkingTree }
                'local_add' { Stage-LocalChange -RelativePath $op.payload.path }
                'local_modify' { Stage-LocalChange -RelativePath $op.payload.path }
                'local_delete' { Stage-DeleteChange -RelativePath $op.payload.path }
                'local_rename' { Stage-RenameChange -OldPath $op.payload.old -NewPath $op.payload.new }
                'sync_cycle' { }
                default { Write-AppLog -Level WARN -Message ("Unhandled op type: " + $op.type) -EventId 1703 }
            }
            Complete-Op -Id $op.id -Result 'success'
        } catch {
            Complete-Op -Id $op.id -Result 'failed' -ErrorMessage $_.Exception.Message
            Write-AppLog -Level ERROR -Message ("Queue op failed: $($op.type): " + $_.Exception.Message) -EventId 1704
        }
    }

    if (-not (Invoke-PrePullFetch)) { return }
    if ($SyncDirection -ne 'PushOnly') { Pull-RemoteChanges }
    $committed = Commit-LocalBatch -Summary $summary
    if ($committed -and $SyncDirection -ne 'PullOnly') { Push-LocalChanges }
    Verify-Integrity
    Save-State
}
#endregion Sync Operations

#region Status / Auto-Recovery
function Get-SyncStatus {
    Save-Status
    return (Get-Content -LiteralPath $StatusFile -Raw)
}

function Attempt-AutoRecovery {
    Write-AppLog -Level WARN -Message 'Auto-recovery path invoked.' -EventId 1801
    try {
        Test-RepoHealth | Out-Null
    } catch {
        if ($AllowAutoReclone -and $Repo) {
            $backup = "$Root.recovery." + (Get-Date -Format yyyyMMddHHmmss)
            Write-AppLog -Level ERROR -Message "Repository unrecoverable. Backing up root to $backup and recloning." -EventId 1802
            if (-not $DryRun) {
                Move-Item -LiteralPath $Root -Destination $backup -Force
                New-Item -ItemType Directory -Path $Root -Force | Out-Null
                Invoke-Git -Args @('clone',$Repo,'.') | Out-Null
            }
        } else {
            Write-AppLog -Level ERROR -Message 'Auto-recovery could not complete and auto-reclone disabled.' -EventId 1803
        }
    }
}
#endregion Status / Auto-Recovery

#region Init / Cleanup
function Acquire-SingleInstanceMutex {
    $script:Mutex = [Threading.Mutex]::new($false, 'Global\GitAutoSyncEnterprise')
    if (-not $script:Mutex.WaitOne(0)) {
        throw 'Another instance is already running.'
    }
}

function Initialize-Environment {
    Ensure-Directory -Path $StateDir
    Ensure-Directory -Path $LogDir
    Ensure-Directory -Path $QuarantineDir
    Ensure-ControlInbox
    $script:Git = Resolve-GitExe
    Write-AppLog -Level INFO -Message ("Using Git: " + $script:Git) -EventId 1901
    Normalize-WorkingTreeSettings
    Ensure-GitRepo
    $script:State = Load-State
    $script:Queue = Load-Queue
    Initialize-Status
    $script:State.last_start_utc = (Get-Date).ToString('o')
    $script:State.instance_history += @{ timestamp=(Get-Date).ToString('o'); host=$script:HostName; instance=$script:InstanceId }
    Apply-ProfileDefaults
    Save-State
    Start-RootWatcher
}

function Cleanup-AndExit {
    param([int]$Code = 0)
    try {
        $script:Status.state = 'stopping'
        Save-Status
        Stop-RootWatcher
        Save-State
        Save-Queue
    } catch {}
    try {
        if ($script:Mutex) { $script:Mutex.ReleaseMutex() | Out-Null; $script:Mutex.Dispose() }
    } catch {}
    exit $Code
}
#endregion Init / Cleanup

#region Main Loop
try {
    Acquire-SingleInstanceMutex
    Initialize-Environment
    Write-AppLog -Level INFO -Message 'GitAutoSync Enterprise started.' -EventId 2001

    Enqueue-Op -Type 'full_scan' -Priority 1 | Out-Null

    while (-not $script:StopRequested) {
        $script:Cycle++
        $cycleStart = Get-Date
        try {
            Process-ControlInbox
            if ($script:Status.state -eq 'paused_manual' -or $script:Status.state -eq 'paused_dangerous_delete') {
                Save-Status
                Start-Sleep -Seconds $DelaySec
                continue
            }

            $events = Drain-WatcherBuffer
            foreach ($e in $events) {
                switch ($e.type) {
                    'Created'  { Enqueue-Op -Type 'local_add'    -Payload @{ path = $e.rel } -Priority 50 | Out-Null }
                    'Changed'  { Enqueue-Op -Type 'local_modify' -Payload @{ path = $e.rel } -Priority 50 | Out-Null }
                    'Deleted'  { Enqueue-Op -Type 'local_delete' -Payload @{ path = $e.rel } -Priority 50 | Out-Null }
                    'Renamed'  { Enqueue-Op -Type 'local_rename' -Payload @{ old = $e.old_rel; new = $e.rel } -Priority 40 | Out-Null }
                }
            }

            if (((Get-Date) - $script:LastFullScanUtc).TotalSeconds -ge $FullScanIntervalSec) {
                Enqueue-Op -Type 'full_scan' -Priority 10 | Out-Null
            }

            if (($script:Cycle % $HealthCheckEveryCycles) -eq 0) {
                Test-RepoHealth | Out-Null
            }

            $script:Status.state = 'running'
            Process-QueuedOps

            $script:State.last_successful_cycle_utc = (Get-Date).ToString('o')
            $script:Status.last_cycle_utc = $script:State.last_successful_cycle_utc
            $script:Status.last_error = $null
            Save-State
            Save-Status
            Write-Metric -Key 'cycle_ms' -Value [int](((Get-Date) - $cycleStart).TotalMilliseconds)
            Write-Metric -Key 'queue_length' -Value $script:Queue.items.Count
            Start-Sleep -Seconds $DelaySec
        } catch {
            $script:Status.last_error = $_.Exception.Message
            Save-Status
            Write-Metric -Key 'errors' -Value 1
            Write-AppLog -Level ERROR -Message ('Main loop error: ' + $_.Exception.Message) -EventId 2002
            Attempt-AutoRecovery
            Start-Sleep -Seconds ([Math]::Min(300, $NetworkFailurePauseSec))
        }
    }

    Write-AppLog -Level INFO -Message 'Stop requested.' -EventId 2003
    Cleanup-AndExit -Code 0
}
catch {
    Write-AppLog -Level ERROR -Message ('Fatal startup/runtime error: ' + $_.Exception.Message) -EventId 2004
    Cleanup-AndExit -Code 1
}
#endregion Main Loop
