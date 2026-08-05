# 打开 mpv://open?file=...&time=... 链接
# 由 install-mpv-protocol.ps1 注册为 mpv:// 协议处理器

param([string]$Uri)

if ([string]::IsNullOrWhiteSpace($Uri)) {
    exit 1
}

$query = ""
$idx = $Uri.IndexOf("?")
if ($idx -ge 0) {
    $query = $Uri.Substring($idx + 1)
}

$params = @{}
foreach ($pair in $query.Split("&")) {
    if ([string]::IsNullOrEmpty($pair)) { continue }
    $kv = $pair.Split("=", 2)
    $key = [Uri]::UnescapeDataString($kv[0])
    $val = if ($kv.Count -gt 1) { [Uri]::UnescapeDataString($kv[1]) } else { "" }
    $params[$key] = $val
}

$file = $params["file"]
$time = $params["time"]
if ([string]::IsNullOrWhiteSpace($file)) {
    exit 1
}

$mpv = $env:MPV_MD_MPV_EXE
if ([string]::IsNullOrWhiteSpace($mpv)) {
    $cmd = Get-Command mpv -ErrorAction SilentlyContinue
    if ($cmd) { $mpv = $cmd.Source }
}
if ([string]::IsNullOrWhiteSpace($mpv)) {
    $candidates = @(
        (Join-Path $env:ProgramFiles "mpv\mpv.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "mpv\mpv.exe"),
        (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\mpv.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\mpv\mpv.exe"),
        (Join-Path $env:USERPROFILE "scoop\apps\mpv\current\mpv.exe")
    )
    $mpv = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}

if ([string]::IsNullOrWhiteSpace($mpv) -or -not (Test-Path -LiteralPath $mpv)) {
    Write-Warning "未找到 mpv.exe。请安装 mpv，或设置环境变量 MPV_MD_MPV_EXE 指向 mpv 可执行文件。"
    exit 1
}

$argsList = @()
if ($time -match "^\d+(\.\d+)?$") {
    $argsList += "--start=+$time"
}
$argsList += "--force-window=yes"
$argsList += "--"
$argsList += $file

# 参数逐个引用（避免含空格路径被拆开）
$argStr = ($argsList | ForEach-Object {
    if ($_ -match '[\s"]') {
        '"' + ($_ -replace '"', '\"') + '"'
    } else {
        $_
    }
}) -join " "

Start-Process -FilePath $mpv -ArgumentList $argStr
