# Shared helpers for the Windows PowerShell gateway scripts. Dot-source; do not run directly.
# Compatible with Windows PowerShell 5.1 and PowerShell 7+. Never writes secrets into this repo.

Set-StrictMode -Version Latest

$script:IsWin = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
$HomeDir = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
$GwHome = if ($env:GW_HOME) { $env:GW_HOME } else { Join-Path $HomeDir 'llm-gateways' }
$GwConfigDir = Join-Path $GwHome 'config'
$GwRunDir    = Join-Path $GwHome 'run'
$GwLogDir    = Join-Path $GwHome 'logs'
$GwBackupDir = Join-Path $GwHome 'backups'
$GwStateDir  = Join-Path $GwHome 'state'

function Get-Setting([string]$Name, [string]$Default) {
    # Precedence: process env > $GwHome\config\gateways.env (non-secret) > default
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ($v) { return $v }
    $f = Join-Path $GwConfigDir 'gateways.env'
    if (Test-Path $f) {
        $m = Select-String -Path $f -Pattern "^$Name=(.*)$" | Select-Object -First 1
        if ($m) { return $m.Matches[0].Groups[1].Value }
    }
    return $Default
}
$FreeLlmApiPort   = [int](Get-Setting 'FREELLMAPI_PORT' '3001')
$OmniRoutePort    = [int](Get-Setting 'OMNIROUTE_PORT' '20128')
$GatewayBindHost  = Get-Setting 'GATEWAY_BIND_HOST' '127.0.0.1'
$FreeLlmApiRef    = Get-Setting 'FREELLMAPI_REF' 'main'
$OmniRouteVersion = Get-Setting 'OMNIROUTE_VERSION' 'latest'

function Write-Info($m) { Write-Host "[info] $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "[ ok ] $m" -ForegroundColor Green }
function Write-Warn($m) { Write-Host "[warn] $m" -ForegroundColor Yellow }
function Write-Err($m)  { Write-Host "[fail] $m" -ForegroundColor Red }
function Stop-Script([string]$m) { Write-Err $m; throw $m }

# [Environment]::UserInteractive stays true even when stdin is redirected (CI, pipes), so also check the console.
function Test-Interactive { [Environment]::UserInteractive -and -not [Console]::IsInputRedirected }
function Test-Command([string]$n) { [bool](Get-Command $n -ErrorAction SilentlyContinue) }

function Initialize-Dirs {
    foreach ($d in $GwHome, $GwConfigDir, $GwRunDir, $GwLogDir, $GwBackupDir, $GwStateDir) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    foreach ($d in $GwHome, $GwConfigDir, $GwBackupDir) { Set-OwnerOnly $d }
}

# Restrict a file/dir to the current user. Windows: icacls. Elsewhere (tests): chmod.
function Set-OwnerOnly([string]$Path) {
    if ($script:IsWin) {
        $me = "$env:USERDOMAIN\$env:USERNAME"
        $isDir = Test-Path -LiteralPath $Path -PathType Container
        $grant = if ($isDir) { "${me}:(OI)(CI)F" } else { "${me}:F" }
        & icacls.exe $Path /inheritance:r /grant:r $grant | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warn "could not restrict ACL on $Path" }
    } else {
        $mode = if (Test-Path -LiteralPath $Path -PathType Container) { '700' } else { '600' }
        & chmod $mode $Path
    }
}

# --- versions ----------------------------------------------------------------
function Get-NodeVersion {
    if (-not (Test-Command node)) { return $null }
    return [version]((& node -v).TrimStart('v'))
}
# Ranges from each upstream's package.json "engines" (checked 2026-10-29).
#   FreeLLMAPI: >=20.18.0 <25    OmniRoute: >=22.22.2 <23 || >=24.0.0 <27
function Test-NodeForFreeLlmApi([version]$v) { ($v -ge [version]'20.18.0') -and ($v -lt [version]'25.0.0') }
function Test-NodeForOmniRoute([version]$v) {
    (($v -ge [version]'22.22.2') -and ($v -lt [version]'23.0.0')) -or (($v -ge [version]'24.0.0') -and ($v -lt [version]'27.0.0'))
}
$NodeRangeText = @{ freellmapi = '>=20.18.0 <25'; omniroute = '>=22.22.2 <23 || >=24.0.0 <27' }

# --- ports -------------------------------------------------------------------
function Test-PortInUse([int]$Port) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect('127.0.0.1', $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(500) -and $c.Connected) { return $true }
        return $false
    } catch { return $false } finally { $c.Close() }
}
function Assert-DistinctPorts([int]$A = $FreeLlmApiPort, [int]$B = $OmniRoutePort) {
    if ($A -eq $B) { Stop-Script "FREELLMAPI_PORT and OMNIROUTE_PORT are both $A; they must differ." }
    foreach ($p in $A, $B) { if ($p -lt 1024 -or $p -gt 65535) { Stop-Script "Port $p out of range 1024-65535" } }
}

# --- env files (secrets live ONLY here, never in Git) --------------------------
function New-HexSecret([int]$Bytes) {
    $b = New-Object byte[] $Bytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($b) } finally { $rng.Dispose() }
    -join ($b | ForEach-Object { $_.ToString('x2') })
}
function Get-EnvValue([string]$File, [string]$Key) {
    if (-not (Test-Path $File)) { return $null }
    $m = Select-String -Path $File -Pattern "^$([regex]::Escape($Key))=(.*)$" | Select-Object -First 1
    if ($m) { $m.Matches[0].Groups[1].Value } else { $null }
}
function Read-EnvFile([string]$File) {
    $h = [ordered]@{}
    if (Test-Path $File) {
        foreach ($line in Get-Content $File) {
            if ($line -match '^\s*#' -or $line -notmatch '^([A-Za-z0-9_]+)=(.*)$') { continue }
            $h[$Matches[1]] = $Matches[2]
        }
    }
    $h
}
function Write-EnvFile([string]$File, $Pairs, [string]$Header) {
    $lines = @("# $Header") + ($Pairs.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })
    # Create empty + lock down BEFORE secrets are written.
    if (-not (Test-Path $File)) { New-Item -ItemType File -Path $File -Force | Out-Null }
    Set-OwnerOnly $File
    [System.IO.File]::WriteAllText($File, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
}
# Run a script block with extra env vars, then restore the caller's environment
# so gateway secrets never linger in the interactive session.
function Invoke-WithEnv([System.Collections.IDictionary]$Vars, [scriptblock]$Body) {
    $saved = @{}
    foreach ($k in $Vars.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, [string]$Vars[$k]) }
    try { & $Body } finally {
        foreach ($k in $saved.Keys) {
            # $null would bind to an empty string (leaving an empty variable on Unix); remove explicitly.
            if ($null -eq $saved[$k]) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue } else { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
        }
    }
}

# --- native commands ---------------------------------------------------------
# PS 5.1 turns native stderr into errors under -ErrorAction Stop; check exit codes ourselves.
function Invoke-Native([string]$Exe, [string[]]$Arguments, [string]$WorkDir) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    if ($WorkDir) { Push-Location $WorkDir }
    try { & $Exe @Arguments; $code = $LASTEXITCODE } finally { if ($WorkDir) { Pop-Location }; $ErrorActionPreference = $old }
    if ($code -ne 0) { Stop-Script "$Exe $($Arguments -join ' ') exited with $code" }
}
function Get-NativeOutput([string]$Exe, [string[]]$Arguments, [string]$WorkDir) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    if ($WorkDir) { Push-Location $WorkDir }
    try { $o = & $Exe @Arguments 2>$null; if ($LASTEXITCODE -ne 0) { return $null } ; ($o | Out-String).Trim() } finally { if ($WorkDir) { Pop-Location }; $ErrorActionPreference = $old }
}

# --- HTTP (HttpClient: works on 5.1 and 7; key never appears on a command line) ---
Add-Type -AssemblyName System.Net.Http
function Invoke-Http([string]$Url, [string]$Method = 'GET', [string]$Key, [string]$Body, [int]$TimeoutSec = 10) {
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
    try {
        $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::new($Method), $Url)
        if ($Key) { $req.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $Key) }
        if ($Body) { $req.Content = New-Object System.Net.Http.StringContent($Body, [System.Text.Encoding]::UTF8, 'application/json') }
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        [pscustomobject]@{ Status = [int]$resp.StatusCode; Body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult() }
    } catch {
        [pscustomobject]@{ Status = 0; Body = $_.Exception.Message }
    } finally { $client.Dispose() }
}
function Get-HttpStatus([string]$Url) { (Invoke-Http -Url $Url).Status }
function Wait-ForHttp([string]$Url, [int]$Seconds = 60) {
    for ($i = 0; $i -lt $Seconds; $i++) { if ((Get-HttpStatus $Url) -eq 200) { return $true }; Start-Sleep -Seconds 1 }
    $false
}

# --- processes ---------------------------------------------------------------
function Get-PidFile([string]$Name) { Join-Path $GwRunDir "$Name.pid" }
# PID file stores "<pid>,<start-time-ticks>". The start time guards against PID reuse on every
# platform (process names differ: node.exe on Windows, "MainThread" on Linux).
function Get-GwProcess([string]$Name) {
    $f = Join-Path $GwRunDir "$Name.pid"
    if (-not (Test-Path $f)) { return $null }
    $parts = (Get-Content $f -TotalCount 1).Trim().Split(',')
    $p = Get-Process -Id ([int]$parts[0]) -ErrorAction SilentlyContinue
    if (-not $p) { return $null }
    if ($parts.Count -gt 1) {
        # Tolerance: .NET on Linux derives StartTime from boot time and can drift by milliseconds between calls.
        try { if ([math]::Abs($p.StartTime.ToUniversalTime().Ticks - [long]$parts[1]) -gt 20000000) { return $null } } catch { return $null }
    }
    $p
}
function Start-GwProcess([string]$Name, [string]$LogFile, [string]$Exe, [string[]]$Arguments, [string]$WorkDir) {
    $err = [IO.Path]::ChangeExtension($LogFile, '.err.log')
    $sp = @{ FilePath = $Exe; ArgumentList = $Arguments; RedirectStandardOutput = $LogFile; RedirectStandardError = $err; PassThru = $true }
    if ($WorkDir) { $sp.WorkingDirectory = $WorkDir }
    if ($script:IsWin) { $sp.WindowStyle = 'Hidden' }
    $p = Start-Process @sp
    Set-Content -Path (Get-PidFile $Name) -Value ("{0},{1}" -f $p.Id, $p.StartTime.ToUniversalTime().Ticks)
    $p
}
function Get-DescendantIds([int]$Id) {
    $kids = if ($script:IsWin) {
        @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$Id" -ErrorAction SilentlyContinue | ForEach-Object { [int]$_.ProcessId })
    } else { @(& pgrep -P $Id 2>$null | ForEach-Object { [int]$_ }) }
    foreach ($k in $kids) { $k; Get-DescendantIds $k }
}
# Stop a gateway and everything it spawned. OmniRoute's CLI is a supervisor that spawns a separate server
# child and RESPAWNS it if it dies, and older builds ignore SIGTERM once orphaned. So: snapshot the whole
# tree, stop the parent FIRST (no respawn), then the snapshot, wait, and force-kill any survivor.
function Stop-GwProcess([string]$Name, [int]$Port = 0) {
    $p = Get-GwProcess $Name
    if (-not $p) { Remove-Item (Get-PidFile $Name) -ErrorAction SilentlyContinue; Write-Info "$Name is not running"; return }
    $ids = @($p.Id) + @(Get-DescendantIds $p.Id)
    foreach ($id in $ids) { Stop-Process -Id $id -ErrorAction SilentlyContinue }   # parent first
    $alive = $ids
    for ($i = 0; $i -lt 10 -and $alive.Count -gt 0; $i++) {
        Start-Sleep -Seconds 1
        $alive = @($ids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
    }
    if ($alive.Count -gt 0) {
        Write-Warn "$Name did not exit gracefully (pid $($alive -join ',')); forcing"
        foreach ($id in $alive) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 1
    }
    Remove-Item (Get-PidFile $Name) -ErrorAction SilentlyContinue
    if ($Port -gt 0) {
        for ($i = 0; $i -lt 10 -and (Test-PortInUse $Port); $i++) { Start-Sleep -Seconds 1 }
        if (Test-PortInUse $Port) { Write-Warn "port $Port is still in use after stopping $Name (an unrelated process may own it)" }
    }
    Write-Ok "$Name stopped"
}

# --- backups / rollback ------------------------------------------------------
# Archive layout is relative (config\<gw>.env + data\...), restored to known locations,
# so a restore can never write outside the gateway's own config/data paths.
function New-GwBackup([string]$Name, [string]$Label, [string]$EnvFile, [string]$DataDir) {
    $dir = Join-Path $GwBackupDir $Name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null; Set-OwnerOnly $dir
    $stage = Join-Path ([IO.Path]::GetTempPath()) ("gwbk-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage | Out-Null
    try {
        $any = $false
        if (Test-Path $EnvFile)  { New-Item -ItemType Directory -Path "$stage/config" | Out-Null; Copy-Item $EnvFile "$stage/config/$Name.env"; $any = $true }
        if (Test-Path $DataDir)  { Copy-Item $DataDir "$stage/data" -Recurse; $any = $true }
        if (-not $any) { Write-Warn "nothing to back up for $Name yet"; return $null }
        $out = Join-Path $dir ("{0}-{1}.zip" -f (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'), $Label)
        Compress-Archive -Path "$stage/*" -DestinationPath $out
        Set-OwnerOnly $out
        $out
    } finally { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
}
function Restore-GwBackup([string]$Archive, [string]$Name, [string]$EnvFile, [string]$DataDir) {
    if (-not (Test-Path $Archive)) { Stop-Script "backup not found: $Archive" }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        foreach ($e in $zip.Entries) {
            $n = $e.FullName
            if ($n -match '(^|[\\/])\.\.([\\/]|$)' -or [IO.Path]::IsPathRooted($n)) { Stop-Script "archive contains unsafe path '$n'; refusing" }
            if ($n -notmatch '^(config|data)[\\/]') { Stop-Script "archive contains unexpected entry '$n'; refusing" }
        }
    } finally { $zip.Dispose() }
    $stage = Join-Path ([IO.Path]::GetTempPath()) ("gwrs-" + [guid]::NewGuid().ToString('N'))
    try {
        Expand-Archive -Path $Archive -DestinationPath $stage -Force
        $src = Join-Path $stage "config/$Name.env"
        if (Test-Path $src) { Copy-Item $src $EnvFile -Force; Set-OwnerOnly $EnvFile }
        if (Test-Path "$stage/data") {
            if (Test-Path $DataDir) { Remove-Item $DataDir -Recurse -Force }
            Copy-Item "$stage/data" $DataDir -Recurse
        }
    } finally { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
}
function Get-LatestBackup([string]$Name, [string]$Pattern = '*.zip') {
    $d = Join-Path $GwBackupDir $Name
    if (Test-Path $d) { Get-ChildItem $d -Filter $Pattern | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName }
}
function Confirm-Action([string]$Question, [bool]$AssumeYes) {
    if ($AssumeYes) { return $true }
    if (-not (Test-Interactive)) { Stop-Script "non-interactive: pass -Yes to confirm: $Question" }
    (Read-Host "$Question [y/N]") -match '^[yY]'
}

# --- API key handling (never echoed, never on a command line, never stored) ------
function Get-ApiKey([string]$EnvVar, [string]$KeyFile) {
    $k = [Environment]::GetEnvironmentVariable($EnvVar)
    if (-not $k -and $KeyFile) {
        if (-not (Test-Path $KeyFile)) { Stop-Script "key file not found: $KeyFile" }
        $k = (Get-Content $KeyFile -TotalCount 1).Trim()
    }
    if (-not $k) {
        if (-not (Test-Interactive)) { Stop-Script "No API key. Set `$env:$EnvVar, pass -KeyFile, or run interactively." }
        $sec = Read-Host 'Paste API key (input hidden)' -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { $k = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    if (-not $k) { Stop-Script 'empty API key' }
    $k
}

# Returns 0 on success; 1 = /v1/models failed, 2 = chat failed, 3 = no content in reply.
function Test-ModelRequest([string]$Base, [string]$Key, [string]$Model) {
    Write-Info "GET $Base/v1/models (free; does not consume model quota)"
    $r = Invoke-Http -Url "$Base/v1/models" -Key $Key -TimeoutSec 20
    if ($r.Status -ne 200) { Write-Err "/v1/models returned HTTP $($r.Status): $($r.Body.Substring(0, [Math]::Min(300, $r.Body.Length)))"; return 1 }
    $n = try { ($r.Body | ConvertFrom-Json).data.Count } catch { '?' }
    Write-Ok "/v1/models OK: $n models listed"
    Write-Info "POST $Base/v1/chat/completions model=$Model max_tokens=16 (spends a tiny amount of upstream free-tier quota)"
    $body = @{ model = $Model; max_tokens = 16; stream = $false; messages = @(@{ role = 'user'; content = 'Reply with the single word OK.' }) } | ConvertTo-Json -Depth 5 -Compress
    $c = Invoke-Http -Url "$Base/v1/chat/completions" -Method POST -Key $Key -Body $body -TimeoutSec 90
    if ($c.Status -ne 200) {
        Write-Err "chat completion returned HTTP $($c.Status): $($c.Body.Substring(0, [Math]::Min(400, $c.Body.Length)))"
        Write-Warn 'Common causes: no provider key added yet, free-tier quota exhausted (HTTP 429), model unavailable.'
        return 2
    }
    $text = try { ($c.Body | ConvertFrom-Json).choices[0].message.content } catch { $null }
    if (-not $text) { Write-Err "HTTP 200 but no choices[0].message.content: $($c.Body.Substring(0, [Math]::Min(300, $c.Body.Length)))"; return 3 }
    Write-Ok "model replied: $($text.Substring(0, [Math]::Min(120, $text.Length)))"
    return 0
}
