[CmdletBinding()]
param(
    [int]$Port = 0,
    [switch]$Quiet
)

$ErrorActionPreference = 'SilentlyContinue'
$here = $PSScriptRoot
$runDir = Join-Path $here 'run'
$pidFile = Join-Path $runDir 'asr.pid'
$target = $null

if (Test-Path -LiteralPath $pidFile) {
    $raw = (Get-Content -LiteralPath $pidFile -Raw).Trim()
    if ($raw -match '^\d+$') { $target = [int]$raw }
}

if (-not $target -and $Port -gt 0) {
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($conn) { $target = $conn[0].OwningProcess }
}

if (-not $target) {
    if (-not $Quiet) { Write-Host 'not running' }
    exit 0
}

$proc = Get-Process -Id $target -ErrorAction SilentlyContinue
if (-not $proc) {
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    if (-not $Quiet) { Write-Host "stale pid file removed ($target)" }
    exit 0
}

Stop-Process -Id $target -Force
Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
if (-not $Quiet) { Write-Host "stopped pid $target" }
exit 0
