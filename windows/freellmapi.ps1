<#
.SYNOPSIS
  FreeLLMAPI manager for Windows PowerShell (5.1 or 7+).
.DESCRIPTION
  Upstream: https://github.com/tashfeenahmed/freellmapi (MIT)
  Independent from OmniRoute: own directory, data, env file, PID, logs and port (default 3001).
  Installs from source (git + Node + npm). The upstream project also ships a Windows .exe desktop
  installer (GitHub Releases) - simpler, but not scriptable, and it manages its own data dir.
.EXAMPLE
  .\freellmapi.ps1 install
  .\freellmapi.ps1 start
  .\freellmapi.ps1 test-model -KeyFile $env:USERPROFILE\secrets\freellmapi.key
  .\freellmapi.ps1 update -Ref v0.16.12 ; .\freellmapi.ps1 rollback -WithData
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('install', 'start', 'stop', 'restart', 'status', 'health', 'test-model', 'backup', 'list-backups',
                 'restore', 'update', 'rollback', 'rebuild', 'quota-report', 'logs', 'uninstall', 'help')]
    [string]$Action = 'help',
    [string]$Ref,
    [string]$KeyFile,
    [string]$Model = 'auto',
    [string]$BaseUrl,
    [string]$Archive,
    [switch]$WithData,
    [switch]$Yes,
    [switch]$Json,
    [switch]$ListModels
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/Common.ps1')

$Name = 'freellmapi'
$RepoUrl = if ($env:FREELLMAPI_REPO_URL) { $env:FREELLMAPI_REPO_URL } else { 'https://github.com/tashfeenahmed/freellmapi.git' }
if ($Ref) { $FreeLlmApiRef = $Ref }
$Src   = Join-Path $GwHome 'freellmapi'
$Data  = Join-Path $GwHome 'freellmapi-data'
$EnvF  = Join-Path $GwConfigDir 'freellmapi.env'
$Log   = Join-Path $GwLogDir 'freellmapi.log'
$Port  = $FreeLlmApiPort
if (-not $BaseUrl) { $BaseUrl = "http://127.0.0.1:$Port" }

function Test-Prereqs {
    if (-not (Test-Command node)) { Stop-Script "node not found. Install Node.js LTS (winget install OpenJS.NodeJS.LTS); need $($NodeRangeText.freellmapi)" }
    foreach ($t in 'npm', 'git') { if (-not (Test-Command $t)) { Stop-Script "$t not found. winget install Git.Git / OpenJS.NodeJS.LTS" } }
    $v = Get-NodeVersion
    if (-not (Test-NodeForFreeLlmApi $v)) { Stop-Script "Node $v unsupported by FreeLLMAPI; need $($NodeRangeText.freellmapi)" }
    Assert-DistinctPorts
}

function Initialize-EnvFile {
    Initialize-Dirs
    if (-not (Test-Path $Data)) { New-Item -ItemType Directory -Path $Data | Out-Null }
    Set-OwnerOnly $Data
    if (Test-Path $EnvF) { Write-Info "keeping existing $EnvF (encryption key preserved)"; return }
    $pairs = [ordered]@{
        ENCRYPTION_KEY  = New-HexSecret 32
        NODE_ENV        = 'production'
        HOST            = $GatewayBindHost
        PORT            = "$Port"
        FREEAPI_DB_PATH = (Join-Path $Data 'freeapi.db')
    }
    Write-EnvFile $EnvF $pairs 'FreeLLMAPI runtime config - generated locally. SECRET: never commit.'
    Write-Ok "wrote $EnvF (owner-only)"
}

function Build-App {
    Write-Info 'npm install (a failing optional better-sqlite3 build is not fatal where node:sqlite is used)'
    Invoke-Native 'npm' @('install', '--no-audit', '--no-fund') $Src
    Write-Info 'npm run build'
    Invoke-Native 'npm' @('run', 'build') $Src
    Set-Content (Join-Path $GwStateDir 'freellmapi.node_version') ([string](Get-NodeVersion))
}

# Native modules (better-sqlite3) are compiled for one Node ABI; refuse to start under a different Node.
function Assert-NodeUnchanged {
    $f = Join-Path $GwStateDir 'freellmapi.node_version'
    if (-not (Test-Path $f)) { return }
    $built = (Get-Content $f -TotalCount 1).Trim()
    if ($built -ne [string](Get-NodeVersion)) { Stop-Script "Node changed since FreeLLMAPI was built ($built -> $(Get-NodeVersion)). Switch back, or run: .\freellmapi.ps1 rebuild" }
}

function Invoke-Rebuild {
    Test-Prereqs
    if (-not (Test-Path (Join-Path $Src '.git'))) { Stop-Script 'not installed' }
    Stop-GwProcess $Name $Port
    try { Invoke-Native 'npm' @('rebuild') $Src } catch { Write-Warn 'npm rebuild reported errors (continuing to build)' }
    Build-App
    Write-Ok "rebuilt for Node $(Get-NodeVersion). Start with: .\freellmapi.ps1 start"
}
function Get-Head { Get-NativeOutput 'git' @('rev-parse', 'HEAD') $Src }

function Invoke-Install {
    Test-Prereqs; Initialize-Dirs
    if (Test-Path (Join-Path $Src '.git')) { Write-Info "source already at $Src; use 'update' to move it" }
    else {
        Write-Info "cloning $RepoUrl ($FreeLlmApiRef)"
        $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        & git clone --depth 1 --branch $FreeLlmApiRef $RepoUrl $Src 2>$null
        $ok = ($LASTEXITCODE -eq 0); $ErrorActionPreference = $old
        if (-not $ok) { Invoke-Native 'git' @('clone', $RepoUrl, $Src); Invoke-Native 'git' @('checkout', $FreeLlmApiRef) $Src }
    }
    Initialize-EnvFile
    Build-App
    Set-Content (Join-Path $GwStateDir 'freellmapi.installed_commit') (Get-Head)
    Write-Ok "FreeLLMAPI installed at $((Get-Head).Substring(0, 7)). Start with: .\freellmapi.ps1 start"
    Write-Info "Next: open $BaseUrl , create the dashboard account, add provider keys (see docs/PROVIDERS-AND-COSTS.md)."
}

function Invoke-Start {
    if (-not (Test-Path (Join-Path $Src 'server/dist/index.js'))) { Stop-Script 'not built; run: .\freellmapi.ps1 install' }
    Assert-DistinctPorts
    Assert-NodeUnchanged
    if (Get-GwProcess $Name) { Write-Ok "already running (pid $((Get-GwProcess $Name).Id))"; return }
    if (Test-PortInUse $Port) { Stop-Script "port $Port is already in use by something else; set FREELLMAPI_PORT to another value" }
    Invoke-WithEnv (Read-EnvFile $EnvF) {
        Start-GwProcess $Name $Log 'node' @('server/dist/index.js') $Src | Out-Null
    }
    Write-Info "waiting for $BaseUrl/api/ping ..."
    if (Wait-ForHttp "$BaseUrl/api/ping" 60) { Write-Ok "running (pid $((Get-GwProcess $Name).Id)) on ${GatewayBindHost}:$Port" }
    else {
        Write-Err 'did not become healthy; last log lines:'
        foreach ($f in $Log, ([IO.Path]::ChangeExtension($Log, '.err.log'))) { if (Test-Path $f) { Get-Content $f -Tail 15 } }
        Stop-Script 'start failed'
    }
}

function Invoke-Status {
    $p = Get-GwProcess $Name
    if ($p) { Write-Ok "running pid $($p.Id), port $Port" } else { Write-Warn 'not running' }
    if (Test-Path (Join-Path $Src '.git')) { Write-Info "version: $(Get-NativeOutput 'git' @('describe', '--tags', '--always') $Src)" }
    if (Test-Path $EnvF) { Write-Info "config: $EnvF" }
}

function Invoke-Health {
    $c = Get-HttpStatus "$BaseUrl/api/ping"
    if ($c -eq 200) { Write-Ok 'GET /api/ping -> 200 (public liveness probe)' } else { Stop-Script "GET /api/ping -> $c" }
    $d = Get-HttpStatus "$BaseUrl/"
    if ($d -eq 200) { Write-Ok 'dashboard served at / -> 200' } else { Write-Warn "dashboard / -> $d" }
    $a = Get-HttpStatus "$BaseUrl/v1/models"
    switch ($a) { { $_ -in 401, 403 } { Write-Ok "/v1/models rejects anonymous requests ($a)" } 200 { Write-Warn '/v1/models answered anonymously - check auth!' } default { Write-Info "/v1/models anonymous -> $a" } }
}

function Invoke-TestModel {
    $key = Get-ApiKey 'FREELLMAPI_KEY' $KeyFile
    $rc = Test-ModelRequest $BaseUrl $key $Model
    if ($rc -ne 0) { Stop-Script "model test failed (code $rc)" }
}

function Invoke-Backup([string]$Label = 'manual') {
    Initialize-Dirs
    if (Get-GwProcess $Name) { Write-Warn 'gateway is running; stop it first for a fully consistent SQLite copy (continuing)' }
    $out = New-GwBackup $Name $Label $EnvF $Data
    if ($out) { Write-Ok "backup: $out"; Write-Warn 'This archive contains your ENCRYPTION_KEY and encrypted provider keys. Keep it private; never commit it.' }
    $out
}

function Invoke-Restore {
    $a = if ($Archive) { $Archive } else { Get-LatestBackup $Name }
    if (-not $a) { Stop-Script 'no backup to restore' }
    if (-not (Confirm-Action "Restore $a over current FreeLLMAPI config+data?" $Yes.IsPresent)) { Stop-Script 'aborted' }
    Stop-GwProcess $Name $Port
    Invoke-Backup 'pre-restore' | Out-Null
    Restore-GwBackup $a $Name $EnvF $Data
    Write-Ok "restored $a (a pre-restore backup was taken). Start with: .\freellmapi.ps1 start"
}

function Invoke-Update {
    Test-Prereqs
    if (-not (Test-Path (Join-Path $Src '.git'))) { Stop-Script 'not installed' }
    $was = [bool](Get-GwProcess $Name)
    Stop-GwProcess $Name $Port
    Invoke-Backup 'pre-update' | Out-Null
    Set-Content (Join-Path $GwStateDir 'freellmapi.prev_commit') (Get-Head)
    Write-Info "previous commit recorded: $((Get-Head).Substring(0, 12))"
    Invoke-Native 'git' @('fetch', '--depth', '1', 'origin', $FreeLlmApiRef) $Src
    Invoke-Native 'git' @('checkout', '-f', 'FETCH_HEAD') $Src
    Build-App
    Set-Content (Join-Path $GwStateDir 'freellmapi.installed_commit') (Get-Head)
    Write-Ok "updated to $((Get-Head).Substring(0, 7)); if it misbehaves: .\freellmapi.ps1 rollback [-WithData]"
    if ($was) { Invoke-Start }
}

function Invoke-Rollback {
    $f = Join-Path $GwStateDir 'freellmapi.prev_commit'
    if (-not (Test-Path $f)) { Stop-Script "no recorded previous version (run 'update' first, or checkout a commit manually in $Src)" }
    $sha = (Get-Content $f -TotalCount 1).Trim()
    $q = "Roll FreeLLMAPI code back to $($sha.Substring(0, 12))" + $(if ($WithData) { ' and restore the pre-update data backup?' } else { '?' })
    if (-not (Confirm-Action $q $Yes.IsPresent)) { Stop-Script 'aborted' }
    Stop-GwProcess $Name $Port
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & git -C $Src cat-file -e "$sha^{commit}" 2>$null; $have = ($LASTEXITCODE -eq 0); $ErrorActionPreference = $old
    if (-not $have) { Invoke-Native 'git' @('fetch', '--depth', '1', 'origin', $sha) $Src }
    Invoke-Native 'git' @('checkout', '-f', $sha) $Src
    Build-App
    if ($WithData) {
        $a = Get-LatestBackup $Name '*-pre-update.zip'
        if (-not $a) { Stop-Script 'no pre-update backup found' }
        Invoke-Backup 'pre-rollback' | Out-Null
        Restore-GwBackup $a $Name $EnvF $Data
        Write-Ok "data restored from $a"
    } else { Write-Info 'data left as-is. Newer DB migrations may not be reversible; use -WithData if the old version fails to start.' }
    Set-Content (Join-Path $GwStateDir 'freellmapi.installed_commit') (Get-Head)
    Write-Ok "rolled back to $($sha.Substring(0, 12)). Start with: .\freellmapi.ps1 start"
}

# Read-only quota/usage/availability report (tools/quota-report.mjs): GET requests to documented status
# endpoints only, never a model request. The key goes to Node via the environment, never argv or disk.
function Invoke-QuotaReport {
    if (-not (Test-Command node)) { Stop-Script 'node not found' }
    $key = Get-ApiKey 'FREELLMAPI_KEY' $KeyFile
    $qa = @((Join-Path $PSScriptRoot '../tools/quota-report.mjs'), '--gateway', 'freellmapi', '--base-url', $BaseUrl)
    if ($Json) { $qa += '--json' }
    if ($ListModels) { $qa += '--list-models' }
    Invoke-WithEnv ([ordered]@{ FREELLMAPI_KEY = $key }) { Invoke-Native 'node' $qa }
}

function Invoke-Uninstall {
    if (-not (Confirm-Action "Remove FreeLLMAPI code at $Src? (config, data and backups are KEPT)" $Yes.IsPresent)) { Stop-Script 'aborted' }
    Stop-GwProcess $Name $Port
    Remove-Item $Src -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "code removed. Kept: $EnvF, $Data, $(Join-Path $GwBackupDir $Name). Delete those manually only if you are sure."
}

switch ($Action) {
    'install'      { Invoke-Install }
    'start'        { Invoke-Start }
    'stop'         { Stop-GwProcess $Name $Port }
    'restart'      { Stop-GwProcess $Name $Port; Invoke-Start }
    'status'       { Invoke-Status }
    'health'       { Invoke-Health }
    'test-model'   { Invoke-TestModel }
    'backup'       { Invoke-Backup | Out-Null }
    'list-backups' { $d = Join-Path $GwBackupDir $Name; if (Test-Path $d) { Get-ChildItem $d -Filter *.zip | Sort-Object LastWriteTime -Descending | ForEach-Object FullName } else { Write-Info "no backups for $Name" } }
    'restore'      { Invoke-Restore }
    'update'       { Invoke-Update }
    'rollback'     { Invoke-Rollback }
    'rebuild'      { Invoke-Rebuild }
    'quota-report' { Invoke-QuotaReport }
    'logs'         { if (Test-Path $Log) { Get-Content $Log -Tail 80 } else { Write-Info "no log yet ($Log)" } }
    'uninstall'    { Invoke-Uninstall }
    default        { Get-Help $PSCommandPath -Examples }
}
