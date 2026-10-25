[CmdletBinding()]
param(
    [string]$Python = '',
    [int]$Port = 5032,
    [string]$Model = 'small',
    [string]$Token = '',
    [switch]$Foreground,
    [int]$WaitSeconds = 120
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$worker = Join-Path $here 'worker.py'
$logDir = Join-Path $here 'logs'
$runDir = Join-Path $here 'run'
New-Item -ItemType Directory -Force -Path $logDir, $runDir | Out-Null

function Resolve-Python {
    param([string]$Explicit)
    if ($Explicit) { return $Explicit }
    if ($env:ASR_PYTHON) { return $env:ASR_PYTHON }
    # DSH 的运行时目录名可能随版本变化，所以按结构探测而不是写死。
    $dshRoot = Join-Path $env:USERPROFILE '.dsh\dsh-runtimes'
    if (Test-Path -LiteralPath $dshRoot) {
        $found = Get-ChildItem -LiteralPath $dshRoot -Recurse -Depth 4 -Filter 'python.exe' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match 'dependencies\\python\\python\.exe$' } |
            Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw 'No Python found. Pass -Python <path-to-python.exe>.'
}

if (-not (Test-Path -LiteralPath $worker)) { throw "worker.py not found: $worker" }

$py = Resolve-Python -Explicit $Python
$pyVersion = (& $py -c "import sys;print('%d.%d'%sys.version_info[:2])").Trim()
Write-Host "python : $py ($pyVersion)"

if ($Foreground) {
    $env:ASR_PORT = "$Port"
    $env:ASR_MODEL = $Model
    $env:ASR_TOKEN = $Token
    & $py -B $worker
    exit $LASTEXITCODE
}

# 端口已占用就直接退出，不要起第二个实例
$occupied = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($occupied) {
    $owner = $occupied[0].OwningProcess
    throw "port $Port is already in use (pid $owner). Run stop.ps1 first."
}

$env:ASR_PORT = "$Port"
$env:ASR_MODEL = $Model
$env:ASR_TOKEN = $Token

$stdout = Join-Path $logDir 'asr.out.log'
$stderr = Join-Path $logDir 'asr.err.log'
$proc = Start-Process -FilePath $py `
    -ArgumentList @('-B', $worker) `
    -WorkingDirectory $here `
    -WindowStyle Hidden `
    -PassThru `
    -RedirectStandardOutput $stdout `
    -RedirectStandardError $stderr

$proc.Id | Set-Content -LiteralPath (Join-Path $runDir 'asr.pid') -Encoding ascii
@{
    pid     = $proc.Id
    port    = $Port
    model   = $Model
    python  = $py
    started = (Get-Date).ToString('o')
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runDir 'asr.json') -Encoding utf8

$headers = @{}
if ($Token) { $headers['X-ASR-Token'] = $Token }

$deadline = (Get-Date).AddSeconds($WaitSeconds)
while ((Get-Date) -lt $deadline) {
    $proc.Refresh()
    if ($proc.HasExited) {
        $tail = ''
        if (Test-Path $stderr) { $tail = (Get-Content $stderr -Tail 20 | Out-String) }
        throw "asr-worker exited with code $($proc.ExitCode).`n$tail"
    }
    try {
        $health = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -Headers $headers -TimeoutSec 2
        if ($health.ok -eq $true) {
            Write-Host "ready  : http://127.0.0.1:$Port  model=$($health.model)  pid=$($proc.Id)"
            Write-Host "logs   : $stdout"
            exit 0
        }
    } catch { }
    Start-Sleep -Milliseconds 500
}

throw "asr-worker did not become ready in $WaitSeconds s. See $stderr"
