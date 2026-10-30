<#
.SYNOPSIS
  OmniRoute manager for Windows PowerShell (5.1 or 7+).
.DESCRIPTION
  Upstream: https://github.com/cheaper-inference/OmniRoute (npm package: omniroute)
  Independent from FreeLLMAPI: own npm prefix, data dir, env file, PID, logs and port (default 20128).
  Installs into an isolated prefix (no global npm state). Needs Node >=22.22.2 <23 or >=24 <27.
.EXAMPLE
  .\omniroute.ps1 install
  .\omniroute.ps1 start
  .\omniroute.ps1 credentials
  .\omniroute.ps1 test-model -Model <provider/model> -KeyFile $env:USERPROFILE\secrets\omniroute.key
  .\omniroute.ps1 update ; .\omniroute.ps1 rollback -WithData
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('install', 'start', 'stop', 'restart', 'status', 'health', 'test-model', 'credentials', 'backup',
                 'list-backups', 'restore', 'update', 'rollback', 'rebuild', 'quota-report', 'logs', 'uninstall', 'help')]
    [string]$Action = 'help',
    [string]$Version,
    [string]$KeyFile,
    [string]$Model,
    [string]$BaseUrl,
    [string]$Archive,
    [switch]$WithData,
    [switch]$Yes,
    [switch]$Json,
    [double]$MaxAgeMin = 0,
    [string]$TokenFile
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/Common.ps1')

$Name = 'omniroute'
if ($Version) { $OmniRouteVersion = $Version }
$Prefix = Join-Path $GwHome 'omniroute'
$Data   = Join-Path $GwHome 'omniroute-data'
$EnvF   = Join-Path $GwConfigDir 'omniroute.env'
$Log    = Join-Path $GwLogDir 'omniroute.log'
$Port   = $OmniRoutePort
$Entry  = Join-Path $Prefix 'node_modules/omniroute/bin/omniroute.mjs'
$AllowScripts = 'omniroute,keytar,onnxruntime-node,@parcel/watcher,@swc/core,protobufjs,esbuild'
if (-not $BaseUrl) { $BaseUrl = "http://127.0.0.1:$Port" }

function Get-InstalledVersion {
    $pj = Join-Path $Prefix 'node_modules/omniroute/package.json'
    if (Test-Path $pj) { (Get-Content $pj -Raw | ConvertFrom-Json).version }
}

function Test-Prereqs {
    foreach ($t in 'node', 'npm') { if (-not (Test-Command $t)) { Stop-Script "$t not found. Install Node.js (winget install OpenJS.NodeJS.LTS); need $($NodeRangeText.omniroute)" } }
    $v = Get-NodeVersion
    if (-not (Test-NodeForOmniRoute $v)) { Stop-Script "Node $v unsupported by OmniRoute; need $($NodeRangeText.omniroute)" }
    Assert-DistinctPorts
}

function Initialize-EnvFile {
    Initialize-Dirs
    if (-not (Test-Path $Data)) { New-Item -ItemType Directory -Path $Data | Out-Null }
    Set-OwnerOnly $Data
    if (Test-Path $EnvF) { Write-Info "keeping existing $EnvF (encryption key + password preserved)"; return }
    $pairs = [ordered]@{
        JWT_SECRET             = New-HexSecret 48
        API_KEY_SECRET         = New-HexSecret 32
        STORAGE_ENCRYPTION_KEY = New-HexSecret 32
        INITIAL_PASSWORD       = New-HexSecret 12
        REQUIRE_API_KEY        = 'true'
        AUTH_COOKIE_SECURE     = 'false'
        DATA_DIR               = $Data
        OMNIROUTE_SERVER_HOST  = $GatewayBindHost
        OMNIROUTE_HEADLESS     = '1'
        PORT                   = "$Port"
    }
    Write-EnvFile $EnvF $pairs 'OmniRoute runtime config - generated locally. SECRET: never commit.'
    Write-Ok "wrote $EnvF (owner-only)"
}

function Install-OmniRoutePackage([string]$Ver) {
    if (-not (Test-Path $Prefix)) { New-Item -ItemType Directory -Path $Prefix | Out-Null }
    $npmArgs = @('install', '--prefix', $Prefix, '--no-audit', '--no-fund', "omniroute@$Ver")
    $major = [int]((& npm -v).Split('.')[0])
    # npm >= 11 blocks lifecycle scripts unless allowed (upstream README, Quick Start).
    if ($major -ge 11) { $npmArgs += "--allow-scripts=$AllowScripts" }
    Invoke-Native 'npm' $npmArgs
    Set-Content (Join-Path $GwStateDir 'omniroute.node_version') ([string](Get-NodeVersion))
}

# Native modules are compiled for one Node ABI; refuse to start under a different Node.
function Assert-NodeUnchanged {
    $f = Join-Path $GwStateDir 'omniroute.node_version'
    if (-not (Test-Path $f)) { return }
    $built = (Get-Content $f -TotalCount 1).Trim()
    if ($built -ne [string](Get-NodeVersion)) { Stop-Script "Node changed since OmniRoute was installed ($built -> $(Get-NodeVersion)). Switch back, or run: .\omniroute.ps1 rebuild" }
}

function Invoke-Rebuild {
    Test-Prereqs
    if (-not (Test-Path $Entry)) { Stop-Script 'not installed' }
    Stop-GwProcess $Name $Port
    try { Invoke-Native 'npm' @('rebuild', '--prefix', $Prefix) } catch { Write-Warn "npm rebuild reported errors; if start fails, run: .\omniroute.ps1 install -Version $(Get-InstalledVersion)" }
    Set-Content (Join-Path $GwStateDir 'omniroute.node_version') ([string](Get-NodeVersion))
    Write-Ok "rebuilt for Node $(Get-NodeVersion). Start with: .\omniroute.ps1 start"
}

function Invoke-Install {
    Test-Prereqs; Initialize-Dirs; Initialize-EnvFile
    Write-Info "installing omniroute@$OmniRouteVersion into $Prefix (isolated; no global npm state)"
    Install-OmniRoutePackage $OmniRouteVersion
    if (-not (Test-Path $Entry)) { Stop-Script "install finished but $Entry is missing" }
    Set-Content (Join-Path $GwStateDir 'omniroute.installed_version') (Get-InstalledVersion)
    Write-Ok "OmniRoute $(Get-InstalledVersion) installed. Start with: .\omniroute.ps1 start"
    Write-Info "Dashboard login password: run '.\omniroute.ps1 credentials' (printed on demand)."
}

function Invoke-Credentials {
    if (-not (Test-Path $EnvF)) { Stop-Script 'not installed' }
    Write-Warn 'Printing a secret to your terminal; do not paste it into chats or commits.'
    Write-Host "dashboard: http://127.0.0.1:$Port"
    Write-Host "password : $(Get-EnvValue $EnvF 'INITIAL_PASSWORD')"
    Write-Info 'INITIAL_PASSWORD only applies until you change it in Dashboard -> Settings -> Security.'
}

function Invoke-Start {
    if (-not (Test-Path $Entry)) { Stop-Script 'not installed; run: .\omniroute.ps1 install' }
    Assert-DistinctPorts
    Assert-NodeUnchanged
    if (Get-GwProcess $Name) { Write-Ok "already running (pid $((Get-GwProcess $Name).Id))"; return }
    if (Test-PortInUse $Port) { Stop-Script "port $Port is already in use by something else; set OMNIROUTE_PORT to another value" }
    Invoke-WithEnv (Read-EnvFile $EnvF) {
        Start-GwProcess $Name $Log 'node' @($Entry, 'serve', '--port', "$Port", '--no-open') $null | Out-Null
    }
    Write-Info "waiting for $BaseUrl/api/health/ping (first start can take a minute) ..."
    if (Wait-ForHttp "$BaseUrl/api/health/ping" 120) { Write-Ok "running (pid $((Get-GwProcess $Name).Id)) on ${GatewayBindHost}:$Port" }
    else {
        Write-Err 'did not become healthy; last log lines:'
        foreach ($f in $Log, ([IO.Path]::ChangeExtension($Log, '.err.log'))) { if (Test-Path $f) { Get-Content $f -Tail 15 } }
        Stop-Script 'start failed'
    }
}

function Invoke-Status {
    $p = Get-GwProcess $Name
    if ($p) { Write-Ok "running pid $($p.Id), port $Port" } else { Write-Warn 'not running' }
    if (Test-Path $Entry) { Write-Info "version: $(Get-InstalledVersion)" }
    if (Test-Path $EnvF) { Write-Info "config: $EnvF" }
}

function Invoke-Health {
    $c = Get-HttpStatus "$BaseUrl/api/health/ping"
    if ($c -eq 200) { Write-Ok 'GET /api/health/ping -> 200 (liveness + DB)' } else { Stop-Script "GET /api/health/ping -> $c" }
    $a = Get-HttpStatus "$BaseUrl/v1/models"
    switch ($a) { { $_ -in 401, 403 } { Write-Ok "/v1/models rejects anonymous requests ($a)" } 200 { Write-Warn '/v1/models answered anonymously - REQUIRE_API_KEY not effective!' } default { Write-Info "/v1/models anonymous -> $a" } }
}

function Invoke-TestModel {
    # No default model on purpose: on a fresh install "auto" may route to keyless/web-session providers
    # you never chose (observed: Cloudflare Playground needing Playwright). Pick a model YOU connected.
    if (-not $Model) { Stop-Script "pass -Model <provider/model> for a provider you connected (list: GET $BaseUrl/v1/models with your key). Use -Model auto only if you accept automatic routing." }
    $key = Get-ApiKey 'OMNIROUTE_KEY' $KeyFile
    $rc = Test-ModelRequest $BaseUrl $key $Model
    if ($rc -ne 0) { Stop-Script "model test failed (code $rc)" }
}

function Invoke-Backup([string]$Label = 'manual') {
    Initialize-Dirs
    if (Get-GwProcess $Name) { Write-Warn 'gateway is running; stop it first for a fully consistent SQLite copy (continuing)' }
    $out = New-GwBackup $Name $Label $EnvF $Data
    if ($out) { Write-Ok "backup: $out"; Write-Warn 'This archive contains STORAGE_ENCRYPTION_KEY, secrets and encrypted provider credentials. Keep it private; never commit it.' }
    $out
}

function Invoke-Restore {
    $a = if ($Archive) { $Archive } else { Get-LatestBackup $Name }
    if (-not $a) { Stop-Script 'no backup to restore' }
    if (-not (Confirm-Action "Restore $a over current OmniRoute config+data?" $Yes.IsPresent)) { Stop-Script 'aborted' }
    Stop-GwProcess $Name $Port
    Invoke-Backup 'pre-restore' | Out-Null
    Restore-GwBackup $a $Name $EnvF $Data
    Write-Ok "restored $a (a pre-restore backup was taken). Start with: .\omniroute.ps1 start"
}

function Invoke-Update {
    Test-Prereqs
    if (-not (Test-Path $Entry)) { Stop-Script 'not installed' }
    $was = [bool](Get-GwProcess $Name)
    Stop-GwProcess $Name $Port
    Invoke-Backup 'pre-update' | Out-Null
    Set-Content (Join-Path $GwStateDir 'omniroute.prev_version') (Get-InstalledVersion)
    Write-Info "previous version recorded: $(Get-Content (Join-Path $GwStateDir 'omniroute.prev_version'))"
    Install-OmniRoutePackage $OmniRouteVersion
    Set-Content (Join-Path $GwStateDir 'omniroute.installed_version') (Get-InstalledVersion)
    Write-Ok "updated to $(Get-InstalledVersion); if it misbehaves: .\omniroute.ps1 rollback [-WithData]"
    if ($was) { Invoke-Start }
}

function Invoke-Rollback {
    $f = Join-Path $GwStateDir 'omniroute.prev_version'
    if (-not (Test-Path $f)) { Stop-Script "no recorded previous version (run 'update' first, or: npm install --prefix $Prefix omniroute@<version>)" }
    $v = (Get-Content $f -TotalCount 1).Trim()
    if (-not $v) { Stop-Script 'recorded version is empty' }
    $q = "Roll OmniRoute back to $v" + $(if ($WithData) { ' and restore the pre-update data backup?' } else { '?' })
    if (-not (Confirm-Action $q $Yes.IsPresent)) { Stop-Script 'aborted' }
    Stop-GwProcess $Name $Port
    Install-OmniRoutePackage $v
    if ($WithData) {
        $a = Get-LatestBackup $Name '*-pre-update.zip'
        if (-not $a) { Stop-Script 'no pre-update backup found' }
        Invoke-Backup 'pre-rollback' | Out-Null
        Restore-GwBackup $a $Name $EnvF $Data
        Write-Ok "data restored from $a"
    } else { Write-Info 'data left as-is. Newer DB migrations may not be reversible; use -WithData if the old version fails to start.' }
    Set-Content (Join-Path $GwStateDir 'omniroute.installed_version') (Get-InstalledVersion)
    Write-Ok "rolled back to $(Get-InstalledVersion). Start with: .\omniroute.ps1 start"
}

# Read-only quota/usage report (tools/quota-report.mjs): GET requests to documented status endpoints only,
# never a model request. Credential: a READ-scope access token (Dashboard -> Settings -> Access Tokens) from
# $env:OMNIROUTE_MGMT_TOKEN, -TokenFile, or a hidden prompt (Enter skips). Passed to Node via the environment only.
function Invoke-QuotaReport {
    if (-not (Test-Command node)) { Stop-Script 'node not found' }
    $tok = $env:OMNIROUTE_MGMT_TOKEN
    if (-not $tok -and $TokenFile) {
        if (-not (Test-Path $TokenFile)) { Stop-Script "token file not found: $TokenFile" }
        $tok = (Get-Content $TokenFile -TotalCount 1).Trim()
    }
    if (-not $tok -and (Test-Interactive)) {
        $sec = Read-Host 'Read-scope access token (input hidden; Enter to skip)' -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { $tok = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    if (-not $tok) { Write-Warn 'no OMNIROUTE_MGMT_TOKEN: only public health endpoints can be reported; the rest will show as Unknown' }
    $qa = @((Join-Path $PSScriptRoot '../tools/quota-report.mjs'), '--gateway', 'omniroute', '--base-url', $BaseUrl)
    if ($Json) { $qa += '--json' }
    if ($MaxAgeMin -gt 0) { $qa += @('--max-age-min', "$MaxAgeMin") }
    Invoke-WithEnv ([ordered]@{ OMNIROUTE_MGMT_TOKEN = [string]$tok }) { Invoke-Native 'node' $qa }
}

function Invoke-Uninstall {
    if (-not (Confirm-Action "Remove OmniRoute code at $Prefix? (config, data and backups are KEPT)" $Yes.IsPresent)) { Stop-Script 'aborted' }
    Stop-GwProcess $Name $Port
    Remove-Item $Prefix -Recurse -Force -ErrorAction SilentlyContinue
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
    'credentials'  { Invoke-Credentials }
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
