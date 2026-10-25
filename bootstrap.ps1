[CmdletBinding()]
param(
    [string]$Python = '',
    [string]$Deps = '',
    [switch]$KeepNumpy
)

# Rebuild the isolated dependency directory from requirements.lock.
# Nothing is written outside this project and the target deps dir.

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$root = Split-Path -Parent $here
if (-not $Deps) { $Deps = Join-Path $root '.voice\deps' }
$lock = Join-Path $here 'requirements.lock'

if (-not (Test-Path -LiteralPath $lock)) { throw "missing $lock" }
New-Item -ItemType Directory -Force -Path $Deps | Out-Null

function Resolve-Python {
    param([string]$Explicit)
    if ($Explicit) { return $Explicit }
    if ($env:ASR_PYTHON) { return $env:ASR_PYTHON }
    # DSH 的运行时目录名可能随版本变化，按结构探测而不是写死。
    $dshRoot = Join-Path $env:USERPROFILE '.dsh\dsh-runtimes'
    if (Test-Path -LiteralPath $dshRoot) {
        $found = Get-ChildItem -LiteralPath $dshRoot -Recurse -Depth 4 -Filter 'python.exe' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match 'dependencies\\python\\python\.exe$' } |
            Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw 'No Python found. Pass -Python <path>.'
}

$py = Resolve-Python -Explicit $Python
$pyVersion = (& $py -c "import sys;print('%d.%d'%sys.version_info[:2])").Trim()
$parts = $pyVersion.Split('.')
$major = [int]$parts[0]
$minor = [int]$parts[1]
Write-Host "python : $py"
Write-Host "version: $pyVersion"
Write-Host "deps   : $Deps"

if ($major -ne 3 -or $minor -lt 9 -or $minor -gt 14) {
    throw "Python $pyVersion 不被支持：ctranslate2 只有 3.9-3.14 的 wheel。推荐 3.12（DSH 自带）。"
}

# pilk 的官方 wheel 只到 cp311；3.12+ 要么用随包的 wheel，要么现场编译。
$wheels = Join-Path $here 'wheels'
$pilkWheel = @(Get-ChildItem -LiteralPath $wheels -Filter "pilk-*-cp$major$minor-*.whl" -File -ErrorAction SilentlyContinue)
if (-not $pilkWheel.Count) {
    Write-Warning "wheels\ 里没有 cp$major$minor 的 pilk 预编译包。"
    Write-Warning "接下来会尝试现场编译 pilk，需要 Microsoft Visual C++ Build Tools。"
    Write-Warning "没有编译器的话：改用 Python 3.11（官方有 wheel），或把对应版本的 wheel 放进 wheels\。"
} else {
    Write-Host "pilk   : 用随包 wheel $($pilkWheel[0].Name)"
}

& $py -m pip --version
if ($LASTEXITCODE -ne 0) { throw 'pip is unavailable for this Python.' }

$installArgs = @('-m', 'pip', 'install', '--disable-pip-version-check', '--no-input',
                 '--upgrade', '--target', $Deps, '-r', $lock)
if (Test-Path -LiteralPath $wheels) {
    $installArgs += @('--find-links', $wheels)
}
& $py @installArgs
if ($LASTEXITCODE -ne 0) { throw 'pip install failed.' }

# numpy 由宿主 Python 提供：deps 里那份是 pip 原版，
# 会被 Windows Smart App Control 拒绝加载（CodeIntegrity 3033/3077）。
if (-not $KeepNumpy) {
    foreach ($name in @('numpy', 'numpy.libs')) {
        $dir = Join-Path $Deps $name
        if (Test-Path -LiteralPath $dir) {
            Remove-Item -LiteralPath $dir -Recurse -Force
            Write-Host "removed : deps\$name  (uses host python's numpy)"
        }
    }
}

Write-Host ''
Write-Host 'verify:'
& $py -c "import sys; sys.path.append(r'$Deps'); import numpy, faster_whisper, pilk; print('  numpy', numpy.__version__, '<-', numpy.__file__); print('  faster_whisper', faster_whisper.__version__); print('  pilk ok')"
if ($LASTEXITCODE -ne 0) {
    Write-Warning 'import check failed. If it mentions numpy DLL / Smart App Control, install numpy for the host Python instead.'
    exit 1
}
Write-Host ''
Write-Host "done. start with:  .\start.ps1 -Python `"$py`""
