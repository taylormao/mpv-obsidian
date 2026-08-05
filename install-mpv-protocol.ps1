# 注册 mpv:// URL 协议（当前用户，无需管理员权限）
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File .\install-mpv-protocol.ps1

$ErrorActionPreference = "Stop"

$launcher = Join-Path $PSScriptRoot "open-mpv-note.ps1"
if (-not (Test-Path -LiteralPath $launcher)) {
    Write-Error "找不到 open-mpv-note.ps1：$launcher"
    exit 1
}

$root = "HKCU:\Software\Classes\mpv"
New-Item -Path $root -Force | Out-Null
Set-ItemProperty -Path $root -Name "(Default)" -Value "URL:MPV Media Protocol"
Set-ItemProperty -Path $root -Name "URL Protocol" -Value ""

$cmdPath = "$root\shell\open\command"
New-Item -Path $cmdPath -Force | Out-Null
$command = '"powershell" -NoProfile -ExecutionPolicy Bypass -File "' + $launcher + '" "%1"'
Set-ItemProperty -Path $cmdPath -Name "(Default)" -Value $command

Write-Host "mpv:// 协议已注册："
Write-Host "  $command"
Write-Host "可点击笔记中的 [mm:ss](mpv://open?... ) 链接测试。"
