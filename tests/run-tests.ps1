# asr-worker 的安装器测试（自包含，不依赖 Pester）
#
# 用法：
#   pwsh -File .\tests\run-tests.ps1
#   powershell -File .\tests\run-tests.ps1
#
# 只测“有状态”的流程：指纹校验、首次安装、幂等、卸载还原。
# 不测 worker 推理本身（那需要 500MB 模型，属于集成测试）。

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$root = Split-Path $here -Parent
$install = Join-Path $root 'integration\install.ps1'
$uninstall = Join-Path $root 'integration\uninstall.ps1'

$script:pass = 0
$script:fail = 0
$script:fixtures = @()

function Get-NormalizedHash([string]$path) {
    $text = [IO.File]::ReadAllText($path)
    $bytes = [Text.Encoding]::UTF8.GetBytes($text.Replace("`r`n", "`n"))
    $sha = [Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return ([BitConverter]::ToString($sha)).Replace('-', '').ToLowerInvariant()
}

function Assert-True([bool]$condition, [string]$message) {
    if (-not $condition) { throw $message }
}

function New-Fixture {
    $dir = Join-Path $env:TEMP ('asr-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $scripts = Join-Path $dir 'scripts'
    New-Item -ItemType Directory -Force -Path $scripts | Out-Null

    # 伪造的“v0.4.0 原版”：install 只比对 hash，不解析内容，所以够用
    [IO.File]::WriteAllText((Join-Path $scripts 'reader-api.py'),
        "PAT_TYPE = (62 << 32) | 49`ndef poll(self):`n    pass`n",
        (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $scripts 'hook-onebot.mjs'),
        "const PAT_TYPE = 1;`n",
        (New-Object Text.UTF8Encoding($false)))

    $hashes = [ordered]@{
        'reader-api.py'   = (Get-NormalizedHash (Join-Path $scripts 'reader-api.py'))
        'hook-onebot.mjs' = (Get-NormalizedHash (Join-Path $scripts 'hook-onebot.mjs'))
    }
    $hashFile = Join-Path $dir 'hashes.json'
    $hashes | ConvertTo-Json | Set-Content -LiteralPath $hashFile -Encoding utf8

    $script:fixtures += $dir
    return [pscustomobject]@{ Dir = $dir; Scripts = $scripts; HashFile = $hashFile }
}

function Invoke-Case([string]$name, [scriptblock]$body) {
    try {
        & $body
        Write-Host ("PASS  " + $name) -ForegroundColor Green
        $script:pass++
    } catch {
        Write-Host ("FAIL  " + $name) -ForegroundColor Red
        Write-Host ("      " + $_.Exception.Message) -ForegroundColor DarkGray
        $script:fail++
    }
}

Write-Host "asr-worker integration tests"
Write-Host "root : $root"
Write-Host ''

# ---------------------------------------------------------------- 1. 指纹校验
Invoke-Case '拒绝指纹不匹配的上游' {
    $fx = New-Fixture
    Add-Content -LiteralPath (Join-Path $fx.Scripts 'reader-api.py') -Value '# 上游被人改过'
    $threw = $false
    try {
        & $install -ScriptsDir $fx.Scripts -HashFile $fx.HashFile -SkipSyntaxCheck 6>$null 3>$null
    } catch {
        $threw = $true
        Assert-True ($_.Exception.Message -match '版本不匹配') "期望“版本不匹配”，实际：$($_.Exception.Message)"
    }
    Assert-True $threw '应当抛错，但没有'
}

# ---------------------------------------------------------------- 2. 首次安装
Invoke-Case '首次安装：替换文件并生成备份' {
    $fx = New-Fixture
    & $install -ScriptsDir $fx.Scripts -HashFile $fx.HashFile -SkipSyntaxCheck 6>$null 3>$null
    $patched = [IO.File]::ReadAllText((Join-Path $fx.Scripts 'reader-api.py'))
    Assert-True ($patched -match 'VOICE_TYPE') 'reader-api.py 没有被打上补丁'
    $backups = @(Get-ChildItem -LiteralPath $fx.Scripts -Filter 'reader-api.py.bak-wechatagent-voice-*')
    Assert-True ($backups.Count -eq 1) "备份数量应为 1，实际 $($backups.Count)"
    $hook = [IO.File]::ReadAllText((Join-Path $fx.Scripts 'hook-onebot.mjs'))
    Assert-True ($hook -match 'VOICE_TYPE') 'hook-onebot.mjs 没有被打上补丁'
}

# ---------------------------------------------------------------- 3. 幂等
Invoke-Case '重复安装：跳过且不再新增备份' {
    $fx = New-Fixture
    & $install -ScriptsDir $fx.Scripts -HashFile $fx.HashFile -SkipSyntaxCheck 6>$null 3>$null
    $before = @(Get-ChildItem -LiteralPath $fx.Scripts -Filter '*.bak-wechatagent-voice-*').Count
    & $install -ScriptsDir $fx.Scripts -HashFile $fx.HashFile -SkipSyntaxCheck 6>$null 3>$null
    $after = @(Get-ChildItem -LiteralPath $fx.Scripts -Filter '*.bak-wechatagent-voice-*').Count
    Assert-True ($before -eq $after) "备份数从 $before 变成 $after，幂等失效"
}

# ---------------------------------------------------------------- 4. 卸载还原
Invoke-Case '卸载：回到原版内容' {
    $fx = New-Fixture
    $original = Get-NormalizedHash (Join-Path $fx.Scripts 'reader-api.py')
    & $install -ScriptsDir $fx.Scripts -HashFile $fx.HashFile -SkipSyntaxCheck 6>$null 3>$null
    & $uninstall -ScriptsDir $fx.Scripts -Quiet 6>$null 3>$null
    $restored = Get-NormalizedHash (Join-Path $fx.Scripts 'reader-api.py')
    Assert-True ($restored -eq $original) '卸载后内容与原版不一致'
    $text = [IO.File]::ReadAllText((Join-Path $fx.Scripts 'reader-api.py'))
    Assert-True (-not ($text -match 'VOICE_TYPE')) '卸载后仍残留 VOICE_TYPE'
}

# ---------------------------------------------------------------- 5. 无备份卸载
Invoke-Case '卸载：没有备份时安全退出' {
    $fx = New-Fixture
    & $uninstall -ScriptsDir $fx.Scripts -Quiet 6>$null 3>$null
    Assert-True (Test-Path (Join-Path $fx.Scripts 'reader-api.py')) '文件被误删了'
}

# ---------------------------------------------------------------- 清理
foreach ($dir in $script:fixtures) {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("result: {0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
