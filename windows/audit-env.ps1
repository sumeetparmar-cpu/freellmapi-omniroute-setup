<#
.SYNOPSIS
  Read-only environment audit for running FreeLLMAPI + OmniRoute side by side on Windows.
.DESCRIPTION
  Changes nothing and sends no credentials. Exit code 0 = no blockers, 1 = at least one blocker.
.EXAMPLE
  .\audit-env.ps1 -Offline
  .\audit-env.ps1 -Only omniroute
#>
[CmdletBinding()]
param([switch]$Offline, [ValidateSet('', 'freellmapi', 'omniroute')][string]$Only = '')
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib/Common.ps1')

$script:Blockers = 0; $script:Warnings = 0
function Pass($m)    { Write-Ok $m }
function Blocker($m) { Write-Err "BLOCKER: $m"; $script:Blockers++ }
function Caution($m) { Write-Warn $m; $script:Warnings++ }
function Want($g)    { (-not $Only) -or ($Only -eq $g) }

Write-Host '== Platform =='
Write-Info "PowerShell $($PSVersionTable.PSVersion) on $([Environment]::OSVersion.VersionString)"
if ($script:IsWin) { Pass 'Windows detected' } else { Caution 'Not Windows: fine for testing, but this audit is meant for the laptop' }
if ($PSVersionTable.PSVersion.Major -lt 5) { Blocker 'PowerShell 5.1 or newer required' }
if ($script:IsWin) {
    $pol = Get-ExecutionPolicy
    if ($pol -in 'Restricted', 'AllSigned') { Caution "ExecutionPolicy is $pol; scripts won't run. Use: powershell -ExecutionPolicy Bypass -File .\freellmapi.ps1 ... (per-process, no system change)" } else { Pass "ExecutionPolicy $pol" }
    $lp = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -ErrorAction SilentlyContinue).LongPathsEnabled
    if ($lp -eq 1) { Pass 'long paths enabled' } else { Caution 'Windows long paths disabled: deep node_modules paths can fail. Enable LongPathsEnabled or install near the drive root via $env:GW_HOME=C:\gw' }
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($admin) { Caution 'Running as Administrator: not needed; run as a normal user' } else { Pass 'running as a normal user' }
}

Write-Host '== Resources =='
try {
    $memMb = if ($script:IsWin) { [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB) } else { [math]::Round((Get-Content /proc/meminfo | Select-String 'MemTotal').ToString().Split()[-2] / 1024) }
    if ($memMb -ge 4000) { Pass "RAM $memMb MB" } elseif ($memMb -ge 2000) { Caution "RAM $memMb MB: both gateways together may be tight" } else { Blocker "RAM $memMb MB is too low for the OmniRoute/Next.js server" }
} catch { Caution "could not read RAM: $($_.Exception.Message)" }
try {
    $root = [IO.Path]::GetPathRoot($GwHome); if (-not $root) { $root = '/' }
    $freeMb = [math]::Round((New-Object IO.DriveInfo $root).AvailableFreeSpace / 1MB)
    if ($freeMb -ge 3000) { Pass "free disk $freeMb MB on $root" } elseif ($freeMb -ge 1500) { Caution "free disk $freeMb MB (3 GB recommended for both)" } else { Blocker "free disk $freeMb MB; need ~3 GB for both" }
} catch { Caution "could not read disk space: $($_.Exception.Message)" }

Write-Host '== Tooling =='
foreach ($t in 'git', 'npm') {
    if (Test-Command $t) { Pass "$t found" } else { Blocker "$t missing. winget install $(if ($t -eq 'git') { 'Git.Git' } else { 'OpenJS.NodeJS.LTS' })" }
}
if (Test-Command node) {
    $nv = Get-NodeVersion; Write-Info "node $nv"
    if (Want 'freellmapi') { if (Test-NodeForFreeLlmApi $nv) { Pass "Node OK for FreeLLMAPI ($($NodeRangeText.freellmapi))" } else { Blocker "Node $nv not OK for FreeLLMAPI; need $($NodeRangeText.freellmapi)" } }
    if (Want 'omniroute')  { if (Test-NodeForOmniRoute $nv)  { Pass "Node OK for OmniRoute ($($NodeRangeText.omniroute))" } else { Blocker "Node $nv not OK for OmniRoute; need $($NodeRangeText.omniroute)" } }
    if ((Want 'freellmapi') -and (Want 'omniroute') -and (Test-NodeForFreeLlmApi $nv) -and -not (Test-NodeForOmniRoute $nv)) { Write-Info 'Tip: Node 22.22.2+ or 24.x satisfies both gateways' }
} else { Blocker 'node missing. winget install OpenJS.NodeJS.LTS' }

Write-Host '== Ports =='
try { Assert-DistinctPorts; Pass "distinct ports: FreeLLMAPI=$FreeLlmApiPort OmniRoute=$OmniRoutePort" } catch { Blocker "ports: $($_.Exception.Message)" }
foreach ($g in @(@('freellmapi', $FreeLlmApiPort), @('omniroute', $OmniRoutePort))) {
    if (-not (Want $g[0])) { continue }
    if (Test-PortInUse $g[1]) {
        if (Get-GwProcess $g[0]) { Pass "$($g[0]) already running on $($g[1]) (managed by these scripts)" } else { Blocker "port $($g[1]) is in use by another process (not managed $($g[0]))" }
    } else { Pass "port $($g[1]) free" }
}
if ($GatewayBindHost -eq '127.0.0.1') { Pass 'bind host 127.0.0.1 (this PC only)' } else { Caution "bind host $GatewayBindHost exposes the gateways to the network (Windows Firewall will prompt)" }

Write-Host '== Network (reachability only; no credentials sent) =='
if ($Offline) { Write-Info 'skipped (-Offline)' } else {
    $c = Get-HttpStatus 'https://registry.npmjs.org/omniroute'
    if ($c -ge 200 -and $c -lt 400) { Pass "npm registry -> $c" } else { Caution "npm registry -> $c (OmniRoute install/update will fail)" }
    if (Want 'freellmapi' -and (Test-Command git)) {
        & git ls-remote --heads https://github.com/tashfeenahmed/freellmapi.git HEAD *> $null
        if ($LASTEXITCODE -eq 0) { Pass 'git can reach tashfeenahmed/freellmapi' } else { Caution 'git cannot reach tashfeenahmed/freellmapi (FreeLLMAPI install/update will fail)' }
    }
}

Write-Host '== Existing installs & secrets hygiene =='
foreach ($g in 'freellmapi', 'omniroute') {
    if (-not (Want $g)) { continue }
    $f = Join-Path $GwConfigDir "$g.env"
    if (Test-Path $f) {
        if ($script:IsWin) {
            $acl = (& icacls.exe $f) -join ' '
            if ($acl -match 'Everyone|BUILTIN\\Users|Authenticated Users') { Caution "$f is readable by other accounts; run: icacls `"$f`" /inheritance:r /grant:r `"$env:USERDOMAIN\$env:USERNAME`:F" } else { Pass "$f owner-only" }
        } else { Pass "$f present" }
    } else { Write-Info "$g not configured yet ($f absent)" }
}
$repoRoot = Split-Path $PSScriptRoot -Parent
if ((Test-Command git) -and (Test-Path (Join-Path $repoRoot '.git'))) {
    $tracked = & git -C $repoRoot ls-files | Where-Object { $_ -match '(^|/)\.env($|\.)|\.sqlite$|\.db$|\.pem$' -and $_ -notmatch '\.example$' }
    if (-not $tracked) { Pass 'no env/db/key files tracked in this repo' } else { Blocker "secret-like files tracked in Git: $($tracked -join ', ')" }
}

Write-Host ''
Write-Host "Summary: $script:Blockers blocker(s), $script:Warnings warning(s)"
exit $(if ($script:Blockers -eq 0) { 0 } else { 1 })
