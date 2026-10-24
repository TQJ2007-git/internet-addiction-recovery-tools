[CmdletBinding()]
param(
    [int]$Port = 0,
    [switch]$DryRun,
    [switch]$LocalOnly,
    [string]$DataDir = ''
)

$ErrorActionPreference = 'Stop'

if (-not $DataDir) { $DataDir = $PSScriptRoot }
$script:Root     = Split-Path -Parent $PSScriptRoot
$script:LogPath  = Join-Path $DataDir 'server.log'
$script:PendPath = Join-Path $DataDir 'pending.json'
$script:Token    = ''
$script:Pending  = $null
$script:LastAction = $null

if (-not (Test-Path -LiteralPath $DataDir)) {
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
}

function Write-Log {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    $enc = New-Object System.Text.UTF8Encoding($false)
    try { [System.IO.File]::AppendAllText($script:LogPath, $line + "`r`n", $enc) } catch { }
}

function Get-ConfigValue {
    param([string]$Name, [string]$Default)
    $path = Join-Path $script:Root 'config.bat'
    if (Test-Path -LiteralPath $path) {
        $pattern = '^\s*set\s+"' + [regex]::Escape($Name) + '=(.*)"\s*$'
        $line = Get-Content -LiteralPath $path -Encoding Default |
            Where-Object { $_ -match $pattern } |
            Select-Object -First 1
        if ($line -and $line -match $pattern) { return $Matches[1].Trim() }
    }
    return $Default
}

$script:Port = if ($Port -gt 0) { $Port } else {
    $v = Get-ConfigValue 'REMOTE_PORT' '8765'
    $n = 0
    if ([int]::TryParse($v, [ref]$n) -and $n -ge 1 -and $n -le 65535) { $n } else { 8765 }
}

$tokenPath = Join-Path $PSScriptRoot 'token.txt'
if (-not (Test-Path -LiteralPath $tokenPath)) {
    Write-Log 'token.txt 不存在，拒绝启动'
    exit 3
}
$script:Token = (Get-Content -Raw -LiteralPath $tokenPath).Trim()
if (-not $script:Token) {
    Write-Log 'token.txt 为空，拒绝启动'
    exit 3
}

if ((Test-Path -LiteralPath $script:LogPath) -and (Get-Item -LiteralPath $script:LogPath).Length -gt 1MB) {
    Move-Item -LiteralPath $script:LogPath -Destination ($script:LogPath + '.old') -Force
}

function Load-Pending {
    if (-not (Test-Path -LiteralPath $script:PendPath)) { return }
    try {
        $p = Get-Content -Raw -LiteralPath $script:PendPath | ConvertFrom-Json
        $at = [datetimeoffset]::Parse($p.at)
        if ($at -gt [datetimeoffset]::Now) {
            $script:Pending = [ordered]@{ source = 'web'; at = $at.ToString('o') }
        } else {
            Remove-Item -LiteralPath $script:PendPath -ErrorAction SilentlyContinue
        }
    } catch {
        Remove-Item -LiteralPath $script:PendPath -ErrorAction SilentlyContinue
    }
}

function Send-Bytes {
    param($Response, [int]$Status, [string]$ContentType, [byte[]]$Bytes)
    $Response.StatusCode = $Status
    $Response.ContentType = $ContentType
    $Response.Headers['Cache-Control'] = 'no-store'
    $Response.ContentLength64 = $Bytes.Length
    if ($Bytes.Length -gt 0) { $Response.OutputStream.Write($Bytes, 0, $Bytes.Length) }
    $Response.OutputStream.Close()
}

function Send-Json {
    param($Response, [int]$Status, $Object)
    $json = $Object | ConvertTo-Json -Depth 8 -Compress
    Send-Bytes $Response $Status 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($json))
}

function Send-Error {
    param($Response, [int]$Status, [string]$Message)
    Send-Json $Response $Status ([ordered]@{ ok = $false; error = $Message })
}

function Test-Token {
    param($Request)
    $h = $Request.Headers['Authorization']
    if (-not $h) { return $false }
    if (-not $h.StartsWith('Bearer ', [StringComparison]::Ordinal)) { return $false }
    return ($h.Substring(7) -ceq $script:Token)
}

function Read-JsonBody {
    param($Request)
    if ($Request.ContentLength64 -gt 4096) {
        # 先尽量读完请求体再返回 413，避免客户端在发送中途收到响应
        try {
            $buf = New-Object byte[] 8192
            $remaining = [long][math]::Min($Request.ContentLength64, 1048576)
            while ($remaining -gt 0) {
                $n = $Request.InputStream.Read($buf, 0, [int][math]::Min($buf.Length, $remaining))
                if ($n -le 0) { break }
                $remaining -= $n
            }
        } catch { }
        return @{ error = 413 }
    }
    if (-not $Request.HasEntityBody) { return @{ error = 400 } }
    $reader = New-Object System.IO.StreamReader($Request.InputStream, [Text.Encoding]::UTF8)
    try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
    if ($text.Length -gt 4096) { return @{ error = 413 } }
    if ([string]::IsNullOrWhiteSpace($text)) { return @{ error = 400 } }
    try { return @{ value = ($text | ConvertFrom-Json) } } catch { return @{ error = 400 } }
}

function Test-TimeFormat {
    param([string]$Value)
    return ($Value -match '^([01]?\d|2[0-3]):[0-5]\d$')
}

function Get-RemainingSeconds {
    param([string]$Value)
    $helper = Join-Path $script:Root 'helper.ps1'
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $helper sec $Value
    $first = (($out -join ' ').Trim() -split '\s+')[0]
    if ($first -match '^\d+$') { return [int]$first }
    return $null
}

function Invoke-ShutdownAt {
    param([string]$Value)
    $bat = Join-Path $script:Root 'shutdown-at.bat'
    $null = & $bat $Value 2>&1
    return [int]$LASTEXITCODE
}

function Invoke-ShutdownExe {
    param([string[]]$ShutdownArgs)
    $null = & shutdown.exe @ShutdownArgs 2>&1
    return [int]$LASTEXITCODE
}

function Set-Pending {
    param([int]$Seconds)
    $at = [datetimeoffset]::Now.AddSeconds($Seconds)
    $script:Pending = [ordered]@{ source = 'web'; at = $at.ToString('o') }
    try {
        [IO.File]::WriteAllText(
            $script:PendPath,
            ($script:Pending | ConvertTo-Json -Compress),
            (New-Object Text.UTF8Encoding($false))
        )
    } catch { }
}

function Clear-Pending {
    $script:Pending = $null
    Remove-Item -LiteralPath $script:PendPath -ErrorAction SilentlyContinue
}

function Handle-Schedule {
    param($Request)
    $b = Read-JsonBody $Request
    if ($b.error) {
        $msg = if ($b.error -eq 413) { '请求体过大' } else { '请求格式错误' }
        return @{ status = $b.error; body = [ordered]@{ ok = $false; error = $msg } }
    }
    $obj = $b.value
    $at = $obj.at
    $min = $obj.inMinutes

    if ($at -and $null -ne $min) {
        return @{ status = 400; body = [ordered]@{ ok = $false; error = 'at 和 inMinutes 只能二选一' } }
    }

    if ($at) {
        if (-not (Test-TimeFormat ([string]$at))) {
            return @{ status = 400; body = [ordered]@{ ok = $false; error = '时间格式不正确，应为 HH:MM' } }
        }
        $code = 0
        if (-not $DryRun) { $code = Invoke-ShutdownAt ([string]$at) }
        if ($code -eq 2) {
            return @{ status = 400; body = [ordered]@{ ok = $false; error = '时间格式不正确，应为 HH:MM' } }
        }
        if ($code -eq 3) {
            return @{ status = 501; body = [ordered]@{ ok = $false; error = '关机被系统拒绝（可能是组策略限制）' } }
        }
        if ($code -ne 0) {
            return @{ status = 500; body = [ordered]@{ ok = $false; error = "排定失败（退出码 $code）" } }
        }
        $sec = Get-RemainingSeconds ([string]$at)
        if ($null -eq $sec) { $sec = 0 }
        Set-Pending $sec
        $script:LastAction = [ordered]@{ action = 'schedule'; at = [datetimeoffset]::Now.ToString('o'); ok = $true }
        return @{ status = 200; body = [ordered]@{ ok = $true; mode = 'at'; scheduledFor = [string]$at; seconds = $sec } }
    }

    if ($null -ne $min) {
        $n = 0
        if (-not [int]::TryParse([string]$min, [ref]$n) -or $n -lt 1 -or $n -gt 1440) {
            return @{ status = 400; body = [ordered]@{ ok = $false; error = 'inMinutes 必须在 1 到 1440 之间' } }
        }
        $sec = $n * 60
        $code = 0
        if (-not $DryRun) {
            $shutdownArgs = @('/s', '/t', [string]$sec)
            if ((Get-ConfigValue 'FORCE' '1') -eq '1') { $shutdownArgs = @('/f') + $shutdownArgs }
            $code = Invoke-ShutdownExe $shutdownArgs
        }
        if ($code -ne 0) {
            return @{ status = 500; body = [ordered]@{ ok = $false; error = "关机命令失败（退出码 $code）" } }
        }
        Set-Pending $sec
        $script:LastAction = [ordered]@{ action = 'schedule-in'; at = [datetimeoffset]::Now.ToString('o'); ok = $true }
        return @{ status = 200; body = [ordered]@{ ok = $true; mode = 'inMinutes'; seconds = $sec } }
    }

    return @{ status = 400; body = [ordered]@{ ok = $false; error = '需要 at 或 inMinutes' } }
}

function Handle-Cancel {
    $code = 0
    if (-not $DryRun) { $code = Invoke-ShutdownExe @('/a') }
    Clear-Pending
    $script:LastAction = [ordered]@{ action = 'cancel'; at = [datetimeoffset]::Now.ToString('o'); ok = ($code -eq 0) }
    if ($code -eq 0) {
        return @{ status = 200; body = [ordered]@{ ok = $true; cancelled = $true } }
    }
    return @{ status = 200; body = [ordered]@{ ok = $true; cancelled = $false; reason = 'no pending shutdown' } }
}

function Handle-ShutdownNow {
    param($Request)
    $delay = 60
    if ($Request.HasEntityBody) {
        $b = Read-JsonBody $Request
        if ($b.error) {
            $msg = if ($b.error -eq 413) { '请求体过大' } else { '请求格式错误' }
            return @{ status = $b.error; body = [ordered]@{ ok = $false; error = $msg } }
        }
        if ($null -ne $b.value.delaySeconds) {
            $d = 0
            if (-not [int]::TryParse([string]$b.value.delaySeconds, [ref]$d) -or $d -lt 0 -or $d -gt 600) {
                return @{ status = 400; body = [ordered]@{ ok = $false; error = 'delaySeconds 必须在 0 到 600 之间' } }
            }
            $delay = $d
        }
    }
    $code = 0
    if (-not $DryRun) {
        $shutdownArgs = @('/s', '/t', [string]$delay)
        if ((Get-ConfigValue 'FORCE' '1') -eq '1') { $shutdownArgs = @('/f') + $shutdownArgs }
        $code = Invoke-ShutdownExe $shutdownArgs
    }
    if ($code -ne 0) {
        return @{ status = 500; body = [ordered]@{ ok = $false; error = "关机命令失败（退出码 $code）" } }
    }
    Set-Pending $delay
    $script:LastAction = [ordered]@{ action = 'shutdown-now'; at = [datetimeoffset]::Now.ToString('o'); ok = $true }
    return @{ status = 200; body = [ordered]@{ ok = $true; seconds = $delay } }
}

function Get-DailyInfo {
    $name = Get-ConfigValue 'TASK_NAME' 'AutoShutdownDaily'
    $lead = 0
    [void][int]::TryParse((Get-ConfigValue 'LEAD_MINUTES' '10'), [ref]$lead)
    $info = [ordered]@{
        targetTime  = Get-ConfigValue 'TARGET_TIME' '23:30'
        leadMinutes = $lead
        taskName    = $name
        exists      = $false
        state       = 'MISSING'
        nextRunTime = $null
    }
    try {
        $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        if ($task) {
            $info.exists = $true
            $info.state = [string]$task.State
            $ti = Get-ScheduledTaskInfo -TaskName $name -ErrorAction SilentlyContinue
            if ($ti -and $ti.NextRunTime) {
                $info.nextRunTime = ([datetimeoffset]$ti.NextRunTime).ToString('o')
            }
        }
    } catch { }
    return $info
}

function Get-StatusObject {
    $pendingOut = $null
    if ($script:Pending) {
        $at = [datetimeoffset]::Parse($script:Pending.at)
        $sec = [int][math]::Floor(($at - [datetimeoffset]::Now).TotalSeconds)
        if ($sec -gt 0) {
            $pendingOut = [ordered]@{ source = 'web'; at = $at.ToString('o'); secondsRemaining = $sec }
        } else {
            $script:Pending = $null
            Remove-Item -LiteralPath $script:PendPath -ErrorAction SilentlyContinue
        }
    }
    return [ordered]@{
        ok         = $true
        hostname   = $env:COMPUTERNAME
        now        = [datetimeoffset]::Now.ToString('o')
        daily      = Get-DailyInfo
        pending    = $pendingOut
        lastAction = $script:LastAction
    }
}

Load-Pending

$prefix = if ($LocalOnly) { "http://127.0.0.1:$script:Port/" } else { "http://+:$script:Port/" }
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)

try {
    $listener.Start()
} catch {
    Write-Log "启动失败 ($prefix): $($_.Exception.Message)"
    exit 2
}
Write-Log "服务启动 $prefix$(if ($DryRun) { ' [dry-run]' })"

while ($listener.IsListening) {
    $ctx = $null
    try {
        $ctx = $listener.GetContext()
        $req = $ctx.Request
        $res = $ctx.Response
        $ip = 'unknown'
        try { $ip = $req.RemoteEndPoint.Address.ToString() } catch { }
        $path = $req.Url.AbsolutePath
        $method = $req.HttpMethod
        $status = 200

        if ($path -eq '/' -and $method -eq 'GET') {
            $htmlPath = Join-Path $PSScriptRoot 'index.html'
            if (Test-Path -LiteralPath $htmlPath) {
                Send-Bytes $res 200 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes($htmlPath))
            } else {
                $status = 500
                Send-Error $res 500 'index.html 缺失'
            }
        }
        elseif ($path -eq '/favicon.ico' -and $method -eq 'GET') {
            $res.StatusCode = 204
            $res.OutputStream.Close()
            $status = 204
        }
        elseif ($path.StartsWith('/api/')) {
            if (-not (Test-Token $req)) {
                Start-Sleep -Milliseconds 750
                $status = 401
                Send-Error $res 401 '令牌无效'
            } else {
                $apiPath = $path.TrimEnd('/')
                $result = $null
                switch ("$method $apiPath") {
                    'GET /api/status'        { $result = @{ status = 200; body = Get-StatusObject } }
                    'POST /api/schedule'     { $result = Handle-Schedule $req }
                    'POST /api/cancel'       { $result = Handle-Cancel }
                    'POST /api/shutdown-now' { $result = Handle-ShutdownNow $req }
                    default {
                        if ($apiPath -in @('/api/status', '/api/schedule', '/api/cancel', '/api/shutdown-now')) {
                            $result = @{ status = 405; body = [ordered]@{ ok = $false; error = '方法不支持' } }
                        } else {
                            $result = @{ status = 404; body = [ordered]@{ ok = $false; error = '接口不存在' } }
                        }
                    }
                }
                $status = $result.status
                Send-Json $res $status $result.body
            }
        }
        else {
            $status = 404
            Send-Error $res 404 '页面不存在'
        }

        Write-Log "$ip $method $path -> $status"
    } catch {
        Write-Log "请求处理异常: $($_.Exception.Message)"
        try { Send-Error $ctx.Response 500 '内部错误' } catch { }
    } finally {
        try { if ($ctx -and $ctx.Response) { $ctx.Response.Close() } } catch { }
    }
}
