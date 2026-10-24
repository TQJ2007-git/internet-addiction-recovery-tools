[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [int]$Port = 0,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$RemoteDir = $PSScriptRoot
$Root = Split-Path -Parent $RemoteDir
$TaskName = 'AutoShutdownRemote'
$RuleName = 'AutoShutdownRemote'
$Server = Join-Path $RemoteDir 'remote-server.ps1'
$Index = Join-Path $RemoteDir 'index.html'
$Launcher = Join-Path $RemoteDir 'start-hidden.vbs'
$TokenPath = Join-Path $RemoteDir 'token.txt'
$StatePath = Join-Path $RemoteDir 'install-state.json'

function Get-ConfigValue {
    param([string]$Name, [string]$Default)
    $path = Join-Path $Root 'config.bat'
    if (Test-Path -LiteralPath $path) {
        $pattern = '^\s*set\s+"' + [regex]::Escape($Name) + '=(.*)"\s*$'
        $line = Get-Content -LiteralPath $path -Encoding Default |
            Where-Object { $_ -match $pattern } |
            Select-Object -First 1
        if ($line -and $line -match $pattern) { return $Matches[1].Trim() }
    }
    return $Default
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $WhatIfPreference) {
    Write-Host '需要管理员权限，请运行 install-remote.bat。' -ForegroundColor Red
    exit 1
}

if (-not (Test-Path -LiteralPath $Server) -or -not (Test-Path -LiteralPath $Index) -or -not (Test-Path -LiteralPath $Launcher)) {
    Write-Host 'remote-server.ps1、index.html 或 start-hidden.vbs 缺失。' -ForegroundColor Red
    exit 1
}

if ($Port -le 0) {
    $v = Get-ConfigValue 'REMOTE_PORT' '8765'
    $n = 0
    if ([int]::TryParse($v, [ref]$n) -and $n -ge 1 -and $n -le 65535) { $Port = $n } else { $Port = 8765 }
}

$owner = $null
try { $owner = [Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { }
if (-not $owner) { $owner = "$env:USERDOMAIN\$env:USERNAME" }

Write-Host "项目目录: $Root"
Write-Host "端口: $Port"
Write-Host "服务身份: $owner"

$listen = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($listen) {
    # 端口被占用：如果占用者就是本模块的服务，先停掉再继续安装；否则报错。
    $running = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*remote-server.ps1*' }
    if ($running) {
        if ($PSCmdlet.ShouldProcess('remote-server.ps1', '停止已在运行的服务')) {
            $running | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            Start-Sleep -Milliseconds 800
        }
        $listen = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    }
}
if ($listen) {
    Write-Host "端口 $Port 已被其他程序占用，请修改 config.bat 的 REMOTE_PORT 后重试。" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path -LiteralPath $TokenPath)) {
    $tok = [guid]::NewGuid().ToString('N')
    if ($PSCmdlet.ShouldProcess($TokenPath, '生成访问令牌')) {
        [IO.File]::WriteAllText($TokenPath, $tok, (New-Object Text.UTF8Encoding($false)))
    }
    Write-Host "已生成令牌: $TokenPath"
} else {
    Write-Host "沿用已有令牌: $TokenPath"
}

$url = "http://+:$Port/"
if ($PSCmdlet.ShouldProcess($url, '注册 URL ACL')) {
    & netsh http delete urlacl url=$url 2>&1 | Out-Null
    & netsh http add urlacl url=$url user="$owner" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host '注册 URL ACL 失败。' -ForegroundColor Red
        exit 1
    }
}

if ($PSCmdlet.ShouldProcess($RuleName, "添加防火墙规则 TCP $Port（仅本地子网）")) {
    & netsh advfirewall firewall delete rule name="$RuleName" 2>&1 | Out-Null
    & netsh advfirewall firewall add rule name="$RuleName" dir=in action=allow protocol=TCP localport=$Port remoteip=LocalSubnet profile=any 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host '添加防火墙规则失败。' -ForegroundColor Red
        exit 1
    }
}

if ($PSCmdlet.ShouldProcess($TaskName, '注册登录自启计划任务')) {
    $wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $action = New-ScheduledTaskAction -Execute $wscript -Argument ('//B //Nologo "{0}"' -f $Launcher)
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $owner
    $principal = New-ScheduledTaskPrincipal -UserId $owner -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -MultipleInstances IgnoreNew
    try {
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-Host ("注册计划任务失败: " + $_.Exception.Message) -ForegroundColor Red
        Write-Host "请确认服务身份是有效的本地用户账号（不是 Everyone）。" -ForegroundColor Yellow
        exit 1
    }
    try {
        Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    } catch {
        Write-Host ("计划任务已注册，但立即启动失败: " + $_.Exception.Message) -ForegroundColor Yellow
        Write-Host "下次登录时会自动启动，也可以现在重新运行本脚本。" -ForegroundColor Yellow
    }
}

if ($PSCmdlet.ShouldProcess($StatePath, '写入安装状态')) {
    $state = [ordered]@{
        port        = $Port
        user        = $owner
        taskName    = $TaskName
        installedAt = [datetimeoffset]::Now.ToString('o')
    }
    [IO.File]::WriteAllText($StatePath, ($state | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
}

if (-not $WhatIfPreference) {
    $ok = $false
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Milliseconds 500
        if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) { $ok = $true; break }
    }
    if (-not $ok) {
        Write-Host '服务启动自检失败，请查看 remote/server.log。' -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host '安装完成。访问地址：' -ForegroundColor Green
$ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
    Select-Object -ExpandProperty IPAddress
foreach ($ip in $ips) { Write-Host ("  http://{0}:{1}/" -f $ip, $Port) }
Write-Host ''
Write-Host "令牌文件: $TokenPath"
Write-Host '电脑需保持登录（锁屏可以）；注销或停在登录界面时服务不会运行。'

if (-not $NoPause -and -not $WhatIfPreference) { Read-Host '按回车键关闭' | Out-Null }
