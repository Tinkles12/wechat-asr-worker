[CmdletBinding()]
param(
    [string]$ProjectRoot = '',
    [string]$ScriptsDir = '',
    [switch]$ToOriginal,
    [switch]$Quiet
)

# 还原 install.ps1 的改动。
# 默认回到“最近一次备份”；-ToOriginal 回到最早的那份（即从未打过任何补丁的版本）。
# 安装版有两份副本（模板源 + 工作副本），会被一起还原。

$ErrorActionPreference = 'Stop'

function Write-Line([string]$text) {
    if (-not $Quiet) { Write-Host $text }
}

function Resolve-Scripts([string]$root, [string]$explicit) {
    if ($explicit) {
        if (-not (Test-Path -LiteralPath $explicit)) { throw "not found: $explicit" }
        return @((Resolve-Path -LiteralPath $explicit).Path)
    }
    $roots = @()
    if ($root) {
        $roots += $root
    } else {
        $roots += (Join-Path $env:USERPROFILE 'WeChatAgent')
        $roots += 'D:\WeChatAgent'
        $roots += 'C:\WeChatAgent'
    }
    $found = @()
    foreach ($base in $roots) {
        if (-not (Test-Path -LiteralPath $base)) { continue }
        foreach ($candidate in @(
                (Join-Path $base 'app\resources\project\scripts'),
                (Join-Path $base 'data\workspace\scripts'),
                (Join-Path $base 'scripts'))) {
            if (Test-Path -LiteralPath (Join-Path $candidate 'reader-api.py')) {
                $full = (Resolve-Path -LiteralPath $candidate).Path
                if ($found -notcontains $full) { $found += $full }
            }
        }
        if ($found.Count) { break }
    }
    if (-not $found.Count) {
        throw '找不到 scripts 目录，请用 -ScriptsDir 指定。'
    }
    return $found
}

$targets = @(Resolve-Scripts -root $ProjectRoot -explicit $ScriptsDir)
$restored = 0

foreach ($target in $targets) {
    Write-Line "target : $target"
    foreach ($name in @('reader-api.py', 'hook-onebot.mjs')) {
        $dest = Join-Path $target $name
        $backups = @(Get-ChildItem -LiteralPath $target -Filter "$name.bak-wechatagent-voice-*" -File -ErrorAction SilentlyContinue |
            Sort-Object Name)
        if (-not $backups.Count) {
            Write-Line "  $name : 没有备份，跳过"
            continue
        }
        $pick = if ($ToOriginal) { $backups[0] } else { $backups[-1] }
        Copy-Item -LiteralPath $pick.FullName -Destination $dest -Force
        Write-Line "  $name : restored from $($pick.Name)"
        $restored++
    }
}

if ($restored -eq 0) {
    Write-Line '没有可还原的备份。'
    return
}

Write-Line ''
Write-Line '已还原。重启 WeChatAgent 服务后生效。'
Write-Line '（备份文件保留，确认无误后可手动删除）'
