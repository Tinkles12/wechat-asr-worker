[CmdletBinding()]
param(
    [string]$ProjectRoot = '',
    [string]$ScriptsDir = '',
    [string]$HashFile = '',
    [switch]$SkipSyntaxCheck,
    [switch]$DryRun
)

# 把 asr-worker 的语音支持接进一个已存在的 WeChatAgent（v0.4.0）。
# 只替换两个文件，原文件先备份；不实现在线升级，也不改其它任何东西。

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$files = Join-Path $here 'files'

# 上游 v0.4.0 的原版指纹（换行统一成 LF 后的 SHA256）。
# 只认这两份：别人改了代码还硬打补丁，比装不上更危险。
$known = @{
    'reader-api.py'   = 'fba96bd6b52ce8bd0c9f1f618dc63095e8749417ddfb4cc97d69b4c22be326c9'
    'hook-onebot.mjs' = '7b407c48359108402b7f3f2268bc56d5f688bbfc75c167306384e18493abca10'
}
if ($HashFile) {
    if (-not (Test-Path -LiteralPath $HashFile)) { throw "missing -HashFile: $HashFile" }
    $raw = Get-Content -LiteralPath $HashFile -Raw | ConvertFrom-Json
    $known = @{}
    foreach ($prop in $raw.PSObject.Properties) { $known[$prop.Name] = $prop.Value }
}

function Get-NormalizedHash([string]$path) {
    $text = [IO.File]::ReadAllText($path)
    $bytes = [Text.Encoding]::UTF8.GetBytes($text.Replace("`r`n", "`n"))
    $sha = [Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return ([BitConverter]::ToString($sha)).Replace('-', '').ToLowerInvariant()
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
        # 安装版有“模板源 + 工作副本”两份：模板每次启动都会覆盖工作副本，
        # 所以两处都必须打补丁（见 deployment.cjs 的 manifest 同步）。
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
        throw '找不到 WeChatAgent 的 scripts 目录。请用 -ProjectRoot <WeChatAgent根目录> 或 -ScriptsDir <scripts目录> 指定。'
    }
    return $found
}

$targets = @(Resolve-Scripts -root $ProjectRoot -explicit $ScriptsDir)
Write-Host ('targets: ' + ($targets -join ' | '))

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$refused = @()
$patched = @()

foreach ($target in $targets) {
    Write-Host ''
    Write-Host "target : $target"

    $plan = @()
    foreach ($name in @('reader-api.py', 'hook-onebot.mjs')) {
        $source = Join-Path $files $name
        $dest = Join-Path $target $name
        if (-not (Test-Path -LiteralPath $source)) { throw "安装包缺少 $name" }
        if (-not (Test-Path -LiteralPath $dest)) { throw "目标缺少 ${name}: $dest" }

        $current = [IO.File]::ReadAllText($dest)
        if ($current -match 'VOICE_TYPE') {
            $plan += [pscustomobject]@{ Name = $name; Action = 'skip'; Reason = '已经装过' }
            continue
        }
        $hash = Get-NormalizedHash $dest
        if ($hash -ne $known[$name]) {
            $plan += [pscustomobject]@{ Name = $name; Action = 'refuse'; Reason = "版本不匹配（$($hash.Substring(0,12))…）" }
            continue
        }
        $plan += [pscustomobject]@{ Name = $name; Action = 'patch'; Reason = 'v0.4.0 原版' }
    }

    $plan | Format-Table -AutoSize | Out-String | Write-Host
    $refused += @($plan | Where-Object { $_.Action -eq 'refuse' })
    $todo = @($plan | Where-Object { $_.Action -eq 'patch' })

    if ($DryRun -or -not $todo.Count) { continue }

    foreach ($item in $todo) {
        $name = $item.Name
        $dest = Join-Path $target $name
        $backup = "$dest.bak-wechatagent-voice-$stamp"
        Copy-Item -LiteralPath $dest -Destination $backup -Force

        # 跟随原文件的换行风格，避免把整洁的 diff 变成满屏改动
        $original = [IO.File]::ReadAllText($dest)
        $style = if ($original.Contains("`r`n")) { "`r`n" } else { "`n" }
        $new = [IO.File]::ReadAllText((Join-Path $files $name)).Replace("`r`n", "`n")
        if ($style -ne "`n") { $new = $new.Replace("`n", $style) }
        [IO.File]::WriteAllText($dest, $new, (New-Object Text.UTF8Encoding($false)))

        Write-Host "patched: $name  (backup: $(Split-Path $backup -Leaf))"
        $patched += $dest
    }
}

if ($refused.Count) {
    throw '有文件版本不匹配，已中止。请确认 WeChatAgent 是 v0.4.0（commit 34766b6）。'
}

if ($DryRun) {
    Write-Host ''
    Write-Host 'dry run: 未写入任何文件。'
    return
}

if (-not $patched.Count) {
    Write-Host ''
    Write-Host '没有需要改的文件（所有目标都已经装过）。'
    return
}

$check = $targets[0]

if (-not $SkipSyntaxCheck) {
Write-Host ''
Write-Host '语法检查:'
$pyCandidates = @()
if ($ProjectRoot) { $pyCandidates += (Join-Path $ProjectRoot 'data\runtimes') }
$pyCandidates += (Join-Path $env:USERPROFILE 'WeChatAgent\data\runtimes')
$pyCandidates += 'D:\WeChatAgent\data\runtimes'

$python = $null
foreach ($dir in $pyCandidates) {
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    $found = Get-ChildItem -LiteralPath $dir -Recurse -Depth 3 -Filter 'python.exe' -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($found) { $python = $found.FullName; break }
}
if ($python) {
    & $python -c "import ast,io,sys; ast.parse(io.open(sys.argv[1],encoding='utf-8').read()); print('  reader-api.py OK')" (Join-Path $check 'reader-api.py')
    if ($LASTEXITCODE -ne 0) { Write-Warning 'reader-api.py 语法检查失败，请用 uninstall.ps1 还原' }
} else {
    Write-Warning '没找到内置 python，跳过语法检查'
}

$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
    & $node.Source --check (Join-Path $check 'hook-onebot.mjs')
    if ($LASTEXITCODE -eq 0) { Write-Host '  hook-onebot.mjs OK' }
} else {
    Write-Warning '没找到 node，跳过语法检查'
}
}

Write-Host ''
Write-Host '完成。下一步：'
Write-Host '  1) 确认 asr-worker 已在运行：  Invoke-RestMethod http://127.0.0.1:5032/health'
Write-Host '  2) 重启 WeChatAgent 服务（控制台"重启"，或 manage.ps1 restart）'
Write-Host '  3) 让对方发一条语音，问 AI "我刚才说了什么"'
Write-Host ''
Write-Host "回滚： .\uninstall.ps1 -ProjectRoot `"$($targets[0].Split('\app\')[0])`""
