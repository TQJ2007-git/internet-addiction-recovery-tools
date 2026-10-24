[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Purge,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$RemoteDir = $PSScriptRoot
$Root = Split-Path -Parent $RemoteDir
$TaskName = 'AutoShutdownRemote'
$RuleName = 'AutoShutdownRemote'
$StatePath = Join-Path $RemoteDir 'install-state.json'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $WhatIfPreference) {
    Write-Host '需要管理员权限，请运行 uninstall-remote.bat。' -ForegroundColor Red
    exit 1
}

$port = 0
if (Test-Path -LiteralPath $StatePath) {
    try {
        $st = Get-Content -Raw -LiteralPath $StatePath | ConvertFrom-Json
        $port = [int]$st.port
    } catch { }
}
if ($port -le 0) {
    $cfg = Join-Path $Root 'config.bat'
    if (Test-Path -LiteralPath $cfg) {
        $line = Get-Content -LiteralPath $cfg -Encoding Default |
            Where-Object { $_ -match '^\s*set\s+"REMOTE_PORT=(\d+)"' } |
            Select-Object -First 1
        if ($line -and $line -match 'REMOTE_PORT=(\d+)') { $port = [int]$Matches[1] }
    }
}
if ($port -le 0) { $port = 8765 }

if ($PSCmdlet.ShouldProcess($TaskName, '停止并删除计划任务')) {
    try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch { }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
}

if ($PSCmdlet.ShouldProcess('remote-server.ps1', '结束残留服务进程')) {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*remote-server.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

if ($PSCmdlet.ShouldProcess($RuleName, '删除防火墙规则')) {
    & netsh advfirewall firewall delete rule name="$RuleName" 2>&1 | Out-Null
}

$url = "http://+:$port/"
if ($PSCmdlet.ShouldProcess($url, '删除 URL ACL')) {
    & netsh http delete urlacl url=$url 2>&1 | Out-Null
}

if ($PSCmdlet.ShouldProcess($StatePath, '删除安装状态文件')) {
    Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
}

if ($Purge) {
    if ($PSCmdlet.ShouldProcess($RemoteDir, '删除令牌与日志')) {
        foreach ($f in @('token.txt', 'server.log', 'server.log.old', 'pending.json')) {
            Remove-Item -LiteralPath (Join-Path $RemoteDir $f) -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host '卸载完成。' -ForegroundColor Green
if (-not $NoPause -and -not $WhatIfPreference) { Read-Host '按回车键关闭' | Out-Null }
