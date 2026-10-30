<#
.SYNOPSIS
  Offline unit tests for the PowerShell scripts. No installs, no network, no real secrets.
  Dependency-free (no Pester needed). Run:  pwsh -File tests/windows/run-tests.ps1
  (Windows PowerShell 5.1: powershell -ExecutionPolicy Bypass -File tests\windows\run-tests.ps1)
#>
$ErrorActionPreference = 'Stop'
$Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$Tmp = Join-Path ([IO.Path]::GetTempPath()) ("gwtest-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Tmp | Out-Null
$env:GW_HOME = Join-Path $Tmp 'gw'
foreach ($v in 'FREELLMAPI_PORT', 'OMNIROUTE_PORT', 'GATEWAY_BIND_HOST') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
$Shell = (Get-Process -Id $PID).Path   # re-launch scripts with the same PowerShell flavour
. (Join-Path $Root 'windows/lib/Common.ps1')
$ErrorActionPreference = 'Continue'

$script:Pass = 0; $script:Fail = 0; $mock = @()
function T([string]$Name, [scriptblock]$Body) {
    $ok = $false; $why = ''
    try { $ok = [bool](& $Body) } catch { $why = $_.Exception.Message }
    if ($ok) { $script:Pass++; Write-Host "ok   - $Name" } else { $script:Fail++; Write-Host "FAIL - $Name $why" -ForegroundColor Red }
}
function Throws([scriptblock]$Body) { try { & $Body *> $null; $false } catch { $true } }
function Run-Script([string]$File, [string[]]$ScriptArgs, [hashtable]$Env = @{}) {
    $saved = @{}; foreach ($k in $Env.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $Env[$k]) }
    # piped stdin => the child is non-interactive, as in CI
    try { $out = '' | & $Shell -NoProfile -File (Join-Path $Root "windows/$File") @ScriptArgs 2>&1 | Out-String; [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out } }
    finally { foreach ($k in $saved.Keys) { if ($null -eq $saved[$k]) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue } else { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } } }
}
function Start-Mock([int]$Port, [string]$Mode) {
    $p = Start-Process node -ArgumentList @((Join-Path $Root 'tests/mock-openai-server.mjs'), $Port, $Mode) -PassThru -RedirectStandardOutput (Join-Path $Tmp "mock$Port.log")
    for ($i = 0; $i -lt 30 -and (Get-HttpStatus "http://127.0.0.1:$Port/v1/models") -eq 0; $i++) { Start-Sleep -Milliseconds 200 }
    $p
}

try {
    Write-Host '# version helpers'
    T 'omniroute accepts 22.22.2'        { Test-NodeForOmniRoute ([version]'22.22.2') }
    T 'omniroute accepts 24.11.0'        { Test-NodeForOmniRoute ([version]'24.11.0') }
    T 'omniroute rejects 22.22.0'        { -not (Test-NodeForOmniRoute ([version]'22.22.0')) }
    T 'omniroute rejects 23.5.0 (gap)'   { -not (Test-NodeForOmniRoute ([version]'23.5.0')) }
    T 'omniroute rejects 27.0.0'         { -not (Test-NodeForOmniRoute ([version]'27.0.0')) }
    T 'freellmapi accepts 20.18.0'       { Test-NodeForFreeLlmApi ([version]'20.18.0') }
    T 'freellmapi rejects 25.0.0'        { -not (Test-NodeForFreeLlmApi ([version]'25.0.0')) }
    T 'freellmapi rejects 18.20.0'       { -not (Test-NodeForFreeLlmApi ([version]'18.20.0')) }

    Write-Host '# ports'
    T 'default ports distinct'           { Assert-DistinctPorts; $true }
    T 'equal ports refused'              { Throws { Assert-DistinctPorts 4000 4000 } }
    T 'privileged port refused'          { Throws { Assert-DistinctPorts 80 4000 } }
    $l = New-Object System.Net.Sockets.TcpListener ([Net.IPAddress]::Loopback, 0); $l.Start(); $busy = $l.LocalEndpoint.Port
    T 'Test-PortInUse detects listener'  { Test-PortInUse $busy }
    $l.Stop()
    T 'Test-PortInUse false when free'   { -not (Test-PortInUse $busy) }

    Write-Host '# env files & secrets'
    Initialize-Dirs
    $f = Join-Path $GwConfigDir 't.env'
    Write-EnvFile $f ([ordered]@{ A = '1'; B = 'x=y'; KEY_WITH_DOLLAR = '$(touch pwned)' }) 'test'
    T 'Get-EnvValue plain'               { (Get-EnvValue $f 'A') -eq '1' }
    T 'Get-EnvValue keeps "="'           { (Get-EnvValue $f 'B') -eq 'x=y' }
    T 'Read-EnvFile returns values literally' { (Read-EnvFile $f)['KEY_WITH_DOLLAR'] -eq '$(touch pwned)' }
    T 'New-HexSecret length'             { (New-HexSecret 32).Length -eq 64 }
    T 'New-HexSecret values differ'      { (New-HexSecret 16) -ne (New-HexSecret 16) }
    if (-not $script:IsWin) { T 'env file mode 600' { (& stat -c %a $f) -eq '600' }; T 'gw home mode 700' { (& stat -c %a $GwHome) -eq '700' } }
    T 'Invoke-WithEnv sets then restores' {
        $before = [Environment]::GetEnvironmentVariable('GW_T_SECRET')
        $inside = Invoke-WithEnv ([ordered]@{ GW_T_SECRET = 'abc' }) { $env:GW_T_SECRET }
        ($inside -eq 'abc') -and ($null -eq [Environment]::GetEnvironmentVariable('GW_T_SECRET')) -and ($null -eq $before) }

    Write-Host '# backup / restore'
    $data = Join-Path $Tmp 'data'; New-Item -ItemType Directory $data | Out-Null; Set-Content (Join-Path $data 'db') 'v1'
    $envf = Join-Path $Tmp 'cfg.env'; Set-Content $envf 'K=1'
    $a = New-GwBackup 'unit' 'test' $envf $data
    T 'backup archive created'           { Test-Path $a }
    Set-Content (Join-Path $data 'db') 'v2'; Set-Content $envf 'K=2'
    Restore-GwBackup $a 'unit' $envf $data
    T 'restore returns old data'         { (Get-Content (Join-Path $data 'db')).Trim() -eq 'v1' }
    T 'restore returns old env'          { (Get-Content $envf).Trim() -eq 'K=1' }
    Set-Content (Join-Path $data 'db-wal') 'stale'
    Restore-GwBackup $a 'unit' $envf $data
    T 'restore removes stale files (e.g. SQLite -wal)' { -not (Test-Path (Join-Path $data 'db-wal')) }
    T 'backup with nothing to save -> $null' { $null -eq (New-GwBackup 'unit' 'empty' (Join-Path $Tmp 'nope.env') (Join-Path $Tmp 'nope')) }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    function New-Zip([string]$Path, [string]$EntryName) {
        $z = [IO.Compression.ZipFile]::Open($Path, 'Create')
        try { $e = $z.CreateEntry($EntryName); $w = New-Object IO.StreamWriter ($e.Open()); $w.Write('x'); $w.Dispose() } finally { $z.Dispose() }
    }
    New-Zip (Join-Path $Tmp 'trav.zip') 'data/../../escape.txt'
    T "restore refuses '..' entries"     { Throws { Restore-GwBackup (Join-Path $Tmp 'trav.zip') 'unit' $envf $data } }
    New-Zip (Join-Path $Tmp 'other.zip') 'somewhere/else.txt'
    T 'restore refuses unexpected entries' { Throws { Restore-GwBackup (Join-Path $Tmp 'other.zip') 'unit' $envf $data } }
    T 'restore refuses missing archive'  { Throws { Restore-GwBackup (Join-Path $Tmp 'missing.zip') 'unit' $envf $data } }
    T 'Get-LatestBackup finds newest'    { [bool](Get-LatestBackup 'unit') }
    T 'no escape file written'           { -not (Test-Path (Join-Path $Tmp 'escape.txt')) }

    Write-Host '# process helpers'
    $sleeper = Start-Process node -ArgumentList @('-e', 'setTimeout(()=>{},60000)') -PassThru
    Set-Content (Get-PidFile 'unitproc') ("{0},{1}" -f $sleeper.Id, $sleeper.StartTime.ToUniversalTime().Ticks)
    T 'Get-GwProcess finds live pid'     { [bool](Get-GwProcess 'unitproc') }
    Stop-GwProcess 'unitproc' *> $null
    T 'process stopped and pid file removed' { (-not (Get-GwProcess 'unitproc')) -and (-not (Test-Path (Get-PidFile 'unitproc'))) }
    Set-Content (Get-PidFile 'unitproc') ("{0},{1}" -f $PID, 12345)   # live PID but wrong start time = reused PID
    T 'reused PID (start-time mismatch) is not treated as ours' { -not (Get-GwProcess 'unitproc') }
    Remove-Item (Get-PidFile 'unitproc') -ErrorAction SilentlyContinue
    # Process tree: parent that spawns a child; Stop-GwProcess must take both down.
    $parentJs = Join-Path $Tmp 'parent.js'
    Set-Content $parentJs "require('child_process').spawn(process.execPath,['-e','setTimeout(()=>{},60000)'],{stdio:'ignore'}); setTimeout(()=>{},60000)"
    $par = Start-Process node -ArgumentList @($parentJs) -PassThru
    Start-Sleep -Milliseconds 800
    $kidIds = @(if ($script:IsWin) { Get-CimInstance Win32_Process -Filter "ParentProcessId=$($par.Id)" | ForEach-Object ProcessId } else { & pgrep -P $par.Id })
    Set-Content (Get-PidFile 'unitproc') ("{0},{1}" -f $par.Id, $par.StartTime.ToUniversalTime().Ticks)
    T 'child process exists before stop' { $kidIds.Count -ge 1 }
    Stop-GwProcess 'unitproc' *> $null
    Start-Sleep -Milliseconds 500
    T 'Stop-GwProcess also stops child processes' { -not (@($kidIds | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }).Count) }

    Write-Host '# model test against mock (HttpClient; key not on any command line)'
    $mock += Start-Mock 18201 'ok'; $mock += Start-Mock 18202 'quota'; $mock += Start-Mock 18203 'empty'; $mock += Start-Mock 18204 'auth'
    T 'OK path returns 0'                { (Test-ModelRequest 'http://127.0.0.1:18201' 'anykey' 'mock-model' 6>$null) -eq 0 }
    T 'quota (429) returns 2'            { (Test-ModelRequest 'http://127.0.0.1:18202' 'anykey' 'mock-model' 6>$null) -eq 2 }
    T 'empty choices returns 3'          { (Test-ModelRequest 'http://127.0.0.1:18203' 'anykey' 'mock-model' 6>$null) -eq 3 }
    T 'wrong key returns 1'              { (Test-ModelRequest 'http://127.0.0.1:18204' 'wrong' 'mock-model' 6>$null) -eq 1 }
    T 'right key passes'                 { (Test-ModelRequest 'http://127.0.0.1:18204' 'mock-key' 'mock-model' 6>$null) -eq 0 }
    T 'unreachable returns 1'            { (Test-ModelRequest 'http://127.0.0.1:1' 'k' 'm' 6>$null) -eq 1 }
    T 'Get-HttpStatus 0 when down'       { (Get-HttpStatus 'http://127.0.0.1:1/') -eq 0 }
    $env:GW_T_KEY = 'fromenv'
    T 'Get-ApiKey from env'              { (Get-ApiKey 'GW_T_KEY' $null) -eq 'fromenv' }
    Remove-Item Env:GW_T_KEY
    Set-Content (Join-Path $Tmp 'k') 'filekey'
    T 'Get-ApiKey from file'             { (Get-ApiKey 'GW_NOPE' (Join-Path $Tmp 'k')) -eq 'filekey' }
    T 'Get-ApiKey missing file refused'  { Throws { Get-ApiKey 'GW_NOPE' (Join-Path $Tmp 'absent') } }

    Write-Host '# quota-report wrappers (against mock status endpoints; read-only)'
    # Node's ESM loader needs a file:// URL on Windows (a bare 'D:/...' path is rejected as scheme 'd:').
    $mockUrl = [Uri]::new((Join-Path $Root 'tests/quota/mock-gateways.mjs')).AbsoluteUri
    $canUni  = & node --input-type=module -e "import('$mockUrl').then(m=>process.stdout.write(m.CANARY.unified))"
    $canMgmt = & node --input-type=module -e "import('$mockUrl').then(m=>process.stdout.write(m.CANARY.mgmt))"
    foreach ($spec in @(@('freellmapi', 18321, 'api/ping'), @('omniroute', 18322, 'api/health/ping'))) {
        $mock += Start-Process node -ArgumentList @((Join-Path $Root 'tests/quota/mock-gateways.mjs'), $spec[0], 'ok', $spec[1]) -PassThru -RedirectStandardOutput (Join-Path $Tmp "qm$($spec[1]).log")
        for ($i = 0; $i -lt 30 -and (Get-HttpStatus "http://127.0.0.1:$($spec[1])/$($spec[2])") -eq 0; $i++) { Start-Sleep -Milliseconds 200 }
    }
    $flUrl = 'http://127.0.0.1:18321'; $omUrl = 'http://127.0.0.1:18322'
    T 'freellmapi quota-report shows labelled provider quota' { $r = Run-Script 'freellmapi.ps1' @('quota-report', '-BaseUrl', $flUrl) @{ FREELLMAPI_KEY = $canUni }; ($r.Code -eq 0) -and ($r.Out -match '\[PROVIDER\] pool groq::account: requests used 600') }
    T 'freellmapi quota-report never prints the key' { $r = Run-Script 'freellmapi.ps1' @('quota-report', '-BaseUrl', $flUrl) @{ FREELLMAPI_KEY = $canUni }; $r.Out -notmatch 'C4N4RY' }
    T 'freellmapi quota-report -Json is valid and read-only' { $r = Run-Script 'freellmapi.ps1' @('quota-report', '-BaseUrl', $flUrl, '-Json') @{ FREELLMAPI_KEY = $canUni }; $j = $r.Out | ConvertFrom-Json; ($j.readOnly -eq $true) -and ($j.modelRequestsSent -eq 0) }
    T 'freellmapi quota-report wrong key -> Unknown, exit 0' { $r = Run-Script 'freellmapi.ps1' @('quota-report', '-BaseUrl', $flUrl) @{ FREELLMAPI_KEY = 'wrong' }; ($r.Code -eq 0) -and ($r.Out -match 'UNKNOWN\] authentication rejected') }
    T 'freellmapi quota-report without key (non-interactive) fails' { (Run-Script 'freellmapi.ps1' @('quota-report', '-BaseUrl', $flUrl) @{ FREELLMAPI_KEY = '' }).Code -ne 0 }
    T 'omniroute quota-report shows provider quota with reset' { $r = Run-Script 'omniroute.ps1' @('quota-report', '-BaseUrl', $omUrl) @{ OMNIROUTE_MGMT_TOKEN = $canMgmt }; ($r.Code -eq 0) -and ($r.Out -match 'Monthly: 87.5% remaining') -and ($r.Out -match '\[ESTIMATE\] catalog-wide') }
    T 'omniroute quota-report never prints the token' { $r = Run-Script 'omniroute.ps1' @('quota-report', '-BaseUrl', $omUrl) @{ OMNIROUTE_MGMT_TOKEN = $canMgmt }; $r.Out -notmatch 'C4N4RY|ST0REDK3Y' }
    Set-Content (Join-Path $Tmp 'om.tok') $canMgmt
    T 'omniroute quota-report -TokenFile' { $r = Run-Script 'omniroute.ps1' @('quota-report', '-BaseUrl', $omUrl, '-TokenFile', (Join-Path $Tmp 'om.tok')) @{ OMNIROUTE_MGMT_TOKEN = '' }; $r.Out -match 'Monthly: 87.5% remaining' }
    T 'omniroute quota-report without token still reports public health' { $r = Run-Script 'omniroute.ps1' @('quota-report', '-BaseUrl', $omUrl) @{ OMNIROUTE_MGMT_TOKEN = '' }; $r.Out -match 'no credential supplied \(OMNIROUTE_MGMT_TOKEN not set\)' }
    T 'omniroute quota-report -MaxAgeMin passes through' { $r = Run-Script 'omniroute.ps1' @('quota-report', '-BaseUrl', $omUrl, '-MaxAgeMin', '5') @{ OMNIROUTE_MGMT_TOKEN = $canMgmt }; $r.Out -match 'ollama-cloud "cloud": stale' }

    Write-Host '# CLI behaviour'
    foreach ($g in 'freellmapi', 'omniroute') {
        $ports = @{ FREELLMAPI_PORT = '39001'; OMNIROUTE_PORT = '39002' }
        T "$g help exits 0"                       { (Run-Script "$g.ps1" @('help')).Code -eq 0 }
        T "$g start before install refuses"       { (Run-Script "$g.ps1" @('start') $ports).Code -ne 0 }
        T "$g status works when not installed"    { (Run-Script "$g.ps1" @('status') $ports).Code -eq 0 }
        T "$g health fails when down"             { (Run-Script "$g.ps1" @('health') $ports).Code -ne 0 }
        T "$g rollback with no history refuses"   { (Run-Script "$g.ps1" @('rollback', '-Yes') $ports).Code -ne 0 }
        T "$g refuses equal ports"                { (Run-Script "$g.ps1" @('start') @{ FREELLMAPI_PORT = '4100'; OMNIROUTE_PORT = '4100' }).Code -ne 0 }
        T "$g rejects unknown action"             { (Run-Script "$g.ps1" @('bogus') $ports).Code -ne 0 }
    }
    # Node-ABI guard: fake "installed" layouts whose recorded build Node differs from the current one.
    New-Item -ItemType Directory -Force (Join-Path $GwHome 'freellmapi/server/dist') | Out-Null
    Set-Content (Join-Path $GwHome 'freellmapi/server/dist/index.js') ''
    New-Item -ItemType Directory -Force (Join-Path $GwHome 'omniroute/node_modules/omniroute/bin') | Out-Null
    Set-Content (Join-Path $GwHome 'omniroute/node_modules/omniroute/bin/omniroute.mjs') ''
    Set-Content (Join-Path $GwStateDir 'freellmapi.node_version') '0.0.1'
    Set-Content (Join-Path $GwStateDir 'omniroute.node_version') '0.0.1'
    foreach ($g in 'freellmapi', 'omniroute') {
        T "$g start refuses when Node changed since build" { $r = Run-Script "$g.ps1" @('start') @{ FREELLMAPI_PORT = '39001'; OMNIROUTE_PORT = '39002' }; ($r.Code -ne 0) -and ($r.Out -match 'Node changed') }
    }
    Remove-Item (Join-Path $GwHome 'freellmapi'), (Join-Path $GwHome 'omniroute') -Recurse -Force
    Get-ChildItem $GwStateDir -Filter '*.node_version' | Remove-Item -Force
    T 'omniroute test-model requires -Model'      { $r = Run-Script 'omniroute.ps1' @('test-model') @{ OMNIROUTE_KEY = 'x' }; ($r.Code -ne 0) -and ($r.Out -match 'Model') }
    T 'audit -Offline reports a summary'          { (Run-Script 'audit-env.ps1' @('-Offline')).Out -match 'Summary:' }
    T 'audit blocks equal ports'                  { (Run-Script 'audit-env.ps1' @('-Offline') @{ FREELLMAPI_PORT = '4100'; OMNIROUTE_PORT = '4100' }).Code -ne 0 }
}
finally {
    foreach ($m in $mock) { if ($m -and -not $m.HasExited) { Stop-Process -Id $m.Id -Force -ErrorAction SilentlyContinue } }
    Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ''
Write-Host "passed=$script:Pass failed=$script:Fail"
exit $(if ($script:Fail -eq 0) { 0 } else { 1 })
