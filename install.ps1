# mpv-md 一键安装脚本
#
# 用法（在 mpv-md 项目目录下打开 PowerShell）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -ApiKey "你的Key"
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -MpvDir "D:\mpv\portable_config"
#
# 脚本会自动：
#   1. 找到 mpv 实际使用的配置目录（scoop 版 mpv 是 portable_config）
#   2. 复制 mpv-md.lua 到 scripts\，复制 mpv-md.conf 到 script-opts\
#   3. 交互式询问并写入 Obsidian Local REST API Key
#   4. 注册 mpv:// 协议（当前用户，无需管理员权限）

param(
    [string]$MpvDir = "",
    [string]$ApiKey = ""
)

$ErrorActionPreference = "Stop"
$repo = $PSScriptRoot

function Find-MpvConfigDir {
    # 1) 用户显式指定
    if ($MpvDir) {
        if (-not (Test-Path -LiteralPath $MpvDir)) {
            throw "指定的配置目录不存在: $MpvDir"
        }
        return $MpvDir
    }
    # 2) 从 PATH / 常见安装位置找到 mpv.exe，优先使用其 portable_config
    $mpvExe = $null
    $cmd = Get-Command mpv -ErrorAction SilentlyContinue
    if ($cmd) { $mpvExe = $cmd.Source }
    if (-not $mpvExe) {
        $candidates = @(
            (Join-Path $env:ProgramFiles "mpv\mpv.exe"),
            (Join-Path ${env:ProgramFiles(x86)} "mpv\mpv.exe"),
            (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\mpv.exe"),
            (Join-Path $env:LOCALAPPDATA "Programs\mpv\mpv.exe"),
            (Join-Path $env:USERPROFILE "scoop\apps\mpv\current\mpv.exe")
        )
        $mpvExe = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    }
    if ($mpvExe) {
        $portable = Join-Path (Split-Path $mpvExe -Parent) "portable_config"
        if (Test-Path -LiteralPath $portable) { return $portable }
    }
    # 3) 回退到默认配置目录
    return (Join-Path $env:APPDATA "mpv")
}

$cfg = Find-MpvConfigDir
$scriptsDir = Join-Path $cfg "scripts"
$optsDir = Join-Path $cfg "script-opts"
New-Item -ItemType Directory -Force -Path $scriptsDir, $optsDir | Out-Null

# 复制主脚本
Copy-Item -LiteralPath (Join-Path $repo "mpv-md.lua") -Destination $scriptsDir -Force

# 复制配置并写入 API Key（UTF-8 无 BOM，避免 mpv 解析异常）
$confSrc = Join-Path $repo "script-opts\mpv-md.conf"
$confDst = Join-Path $optsDir "mpv-md.conf"
$conf = Get-Content -LiteralPath $confSrc -Raw -Encoding UTF8
$placeholder = "在这里填写你的API Key"
if ($conf.Contains($placeholder)) {
    if (-not $ApiKey) {
        $ApiKey = Read-Host "请粘贴 Obsidian 的 Local REST API Key（Obsidian → 设置 → Local REST API → API Key）"
    }
    if ($ApiKey) {
        $conf = $conf.Replace($placeholder, $ApiKey.Trim())
    } else {
        Write-Warning "未提供 API Key，请稍后手动编辑 $confDst"
    }
}
[System.IO.File]::WriteAllText($confDst, $conf, (New-Object System.Text.UTF8Encoding($false)))

# 检测 curl 兼容性：Windows 自带 schannel 版 curl 与 Obsidian 自签证书不兼容
$scoopCurl = Join-Path $env:USERPROFILE "scoop\apps\curl\current\bin\curl.exe"
$conf = [System.IO.File]::ReadAllText($confDst)
if (Test-Path -LiteralPath $scoopCurl) {
    $conf = [regex]::Replace($conf, '(?m)^curl=.*$', { param($m) "curl=$scoopCurl" })
    [System.IO.File]::WriteAllText($confDst, $conf, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "已配置 OpenSSL 版 curl: $scoopCurl"
} else {
    $sysCurl = (Get-Command curl -ErrorAction SilentlyContinue).Source
    if ($sysCurl) {
        $ver = (& $sysCurl --version 2>$null | Select-Object -First 1)
        if ($ver -match "schannel") {
            Write-Warning ""
            Write-Warning "检测到 Windows 自带 schannel 版 curl，与 Obsidian Local REST API 的自签证书不兼容（会报 SEC_E_NO_CREDENTIALS）。"
            Write-Warning "请先运行: scoop install curl"
            Write-Warning "安装完成后重新运行本脚本，会自动配置 OpenSSL 版 curl 的路径。"
        }
    }
}

# 注册 mpv:// 协议
$proto = Join-Path $repo "install-mpv-protocol.ps1"
if (Test-Path -LiteralPath $proto) { & $proto }

Write-Host ""
Write-Host "安装完成："
Write-Host "  脚本: $scriptsDir\mpv-md.lua"
Write-Host "  配置: $confDst"
Write-Host ""
Write-Host "下一步："
Write-Host "  1) 如果 mpv 正在运行，请先退出再重新打开 mpv"
Write-Host "  2) 播放视频，按 Ctrl+Alt+n 即可把时间戳+截图写入 Obsidian"
