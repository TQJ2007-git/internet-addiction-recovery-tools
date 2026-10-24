# 远程关机控制模块 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在目标电脑上增加一个局域网 HTTP 服务和一个网页控制台，让另一台电脑可以远程定时关机、取消关机和查看状态。

**Architecture:** 一个常驻的 Windows PowerShell 5.1 进程用 `System.Net.HttpListener` 提供静态页面和 JSON API；令牌认证；动作复用现有的 `shutdown-at.bat` / `helper.ps1` / `shutdown.exe`。安装脚本一次性注册 URL ACL、防火墙规则和登录自启任务；服务本身以普通用户身份运行。

**Tech Stack:** Windows PowerShell 5.1、.NET Framework `System.Net.HttpListener`、原生 HTML/CSS/JavaScript、`schtasks` / ScheduledTasks 模块、`netsh`。

**Spec:** `docs/superpowers/specs/2026-10-24-remote-control-design.md`

## Global Constraints

- 目标环境：Windows 10/11，Windows PowerShell 5.1；不引入任何第三方依赖。
- 新增 `.ps1`：**UTF-8 with BOM**（否则 PowerShell 5.1 会把中文按 ANSI 读取）。
- `index.html`：UTF-8（无 BOM），声明 `<meta charset="utf-8">`。
- 新增 `.bat`：仅使用 ASCII 字符，避免编码问题。
- 现有 `shutdown-at.bat`、`helper.ps1`、`install-task.bat`、`toggle-task.bat`、`uninstall-task.bat`、`cancel-shutdown.bat` **不得修改**；只允许在 `config.bat` 末尾追加 `REMOTE_PORT`。
- 服务运行身份：普通用户（`RunLevel Limited`）；只有安装/卸载需要管理员。
- 自动化测试一律使用 `-DryRun`，不得真正调用 `shutdown` / `shutdown-at.bat`。
- 本目录不是 git 仓库：**计划中不包含 git 提交**，每个任务以"测试通过/检查点确认"结束。
- 服务监听 `http://+:<PORT>/`；测试实例监听 `http://127.0.0.1:<PORT>/`（非管理员可绑定）。
- 端口默认 8765；测试实例固定 8766。

## 文件结构

创建：

- `remote/remote-server.ps1` — HTTP 服务、认证、状态、动作执行、日志
- `remote/index.html` — 控制页面
- `remote/test-remote.ps1` — 自动化验证（dry-run）
- `remote/install-remote.ps1` — 安装逻辑（管理员）
- `remote/install-remote.bat` — 安装入口（自提权）
- `remote/uninstall-remote.ps1` — 卸载逻辑（管理员）
- `remote/uninstall-remote.bat` — 卸载入口（自提权）

修改：

- `config.bat` — 末尾追加 `REMOTE_PORT=8765`

运行期生成（不手工创建）：

- `remote/token.txt`、`remote/install-state.json`、`remote/pending.json`、`remote/server.log`

---

### Task 1: 服务骨架、令牌认证、状态接口与静态页面

**Files:**
- Create: `remote/test-remote.ps1`
- Create: `remote/remote-server.ps1`
- Create: `remote/index.html`（占位版，Task 3 替换为完整 UI）
- Modify: `config.bat`（追加端口配置）

**Interfaces:**
- Produces:
  - `remote-server.ps1` 参数：`-Port <int>`（0 表示读配置）、`-DryRun`、`-LocalOnly`、`-DataDir <path>`
  - `GET /` → `200 text/html`
  - `GET /api/status` → `200 {"ok":true,"hostname":...,"now":...,"daily":{...},"pending":null,"lastAction":null}`
  - 认证头：`Authorization: Bearer <token>`
  - 运行时文件：`<DataDir>/server.log`、`<DataDir>/pending.json`

- [ ] **Step 1: 编写失败的集成测试（Task 1 子集）**

创建 `remote/test-remote.ps1`：

```powershell
param([int]$Port = 8766)

$ErrorActionPreference = 'Stop'
$RemoteDir = $PSScriptRoot
$Server = Join-Path $RemoteDir 'remote-server.ps1'
$TokenPath = Join-Path $RemoteDir 'token.txt'
$DataDir = Join-Path $env:TEMP ('asr-test-' + [guid]::NewGuid().ToString('N'))

if (-not (Test-Path -LiteralPath $TokenPath)) {
    [IO.File]::WriteAllText($TokenPath, [guid]::NewGuid().ToString('N'), (New-Object Text.UTF8Encoding($false)))
}
$token = (Get-Content -Raw -LiteralPath $TokenPath).Trim()
New-Item -ItemType Directory -Path $DataDir -Force | Out-Null

$base = "http://127.0.0.1:$Port"
$script:pass = 0
$script:fail = 0

function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    if ($Expected -eq $Actual) {
        Write-Host "PASS $Name" -ForegroundColor Green
        $script:pass++
    } else {
        Write-Host "FAIL $Name (expected=[$Expected] actual=[$Actual])" -ForegroundColor Red
        $script:fail++
    }
}

function Call-Api {
    param([string]$Method, [string]$Path, [string]$Token, [string]$Body)
    $headers = @{}
    if ($Token) { $headers['Authorization'] = "Bearer $Token" }
    $params = @{
        UseBasicParsing = $true
        Method          = $Method
        Uri             = ($base + $Path)
        Headers         = $headers
        TimeoutSec      = 10
    }
    if ($Body) {
        $params['Body'] = $Body
        $params['ContentType'] = 'application/json'
    }
    try {
        $r = Invoke-WebRequest @params
        return @{ status = [int]$r.StatusCode; body = [string]$r.Content; type = [string]$r.Headers['Content-Type'] }
    } catch {
        $resp = $_.Exception.Response
        if (-not $resp) { throw }
        $sr = New-Object IO.StreamReader($resp.GetResponseStream())
        return @{ status = [int]$resp.StatusCode; body = $sr.ReadToEnd(); type = [string]$resp.ContentType }
    }
}

$proc = $null
try {
    $proc = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $Server),
        '-Port', $Port, '-DryRun', '-LocalOnly', '-DataDir', ('"{0}"' -f $DataDir)
    )

    $ready = $false
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 250
        try {
            $c = New-Object Net.Sockets.TcpClient
            $c.Connect('127.0.0.1', $Port)
            $c.Close()
            $ready = $true
            break
        } catch { }
    }
    if (-not $ready) { throw "服务未在端口 $Port 启动" }

    $r = Call-Api 'GET' '/' $null $null
    Assert-Equal 'GET / -> 200' 200 $r.status
    Assert-Equal 'GET / content-type html' $true ($r.type -like 'text/html*')
    Assert-Equal 'GET / has html root' $true ($r.body -match '<html')

    $r = Call-Api 'GET' '/api/status' $null $null
    Assert-Equal 'no token -> 401' 401 $r.status

    $r = Call-Api 'GET' '/api/status' 'wrong-token' $null
    Assert-Equal 'bad token -> 401' 401 $r.status

    $r = Call-Api 'GET' '/api/status' $token $null
    Assert-Equal 'status -> 200' 200 $r.status
    $j = $r.body | ConvertFrom-Json
    Assert-Equal 'status ok' $true $j.ok
    Assert-Equal 'hostname non-empty' $true ([bool]$j.hostname)
    Assert-Equal 'daily targetTime format' $true ($j.daily.targetTime -match '^\d{1,2}:\d{2}$')

    $r = Call-Api 'GET' '/nope' $token $null
    Assert-Equal 'unknown path -> 404' 404 $r.status

    $r = Call-Api 'POST' '/api/status' $token '{}'
    Assert-Equal 'wrong method -> 405' 405 $r.status
}
finally {
    if ($proc) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*$DataDir*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $DataDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "通过 $script:pass，失败 $script:fail"
if ($script:fail -gt 0) { exit 1 }
```

- [ ] **Step 2: 运行测试，确认失败**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "remote\test-remote.ps1"
```

Expected: 失败，提示 `remote-server.ps1` 不存在或服务未启动（`throw "服务未在端口 8766 启动"`）。

- [ ] **Step 3: 给 `config.bat` 追加端口配置**

用 PowerShell 按 ANSI 读改写，保留原有 GBK 中文：

```powershell
$p = '<项目目录>\config.bat'
$lines = @(Get-Content -LiteralPath $p -Encoding Default)
if (-not ($lines | Where-Object { $_ -match '^\s*set\s+"REMOTE_PORT=' })) {
    $lines += ''
    $lines += 'rem ---- remote control ----'
    $lines += 'set "REMOTE_PORT=8765"'
    Set-Content -LiteralPath $p -Value $lines -Encoding Default
}
Get-Content -LiteralPath $p -Encoding Default | Select-String 'REMOTE_PORT'
```

Expected: 输出包含 `set "REMOTE_PORT=8765"`。

- [ ] **Step 4: 创建占位 `remote/index.html`**

```html
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>远程关机控制</title>
</head>
<body>
  <h1>远程关机控制</h1>
  <p>控制页面尚未安装。</p>
</body>
</html>
```

- [ ] **Step 5: 实现 `remote/remote-server.ps1`（Task 1 范围）**

```powershell
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
                    'GET /api/status' { $result = @{ status = 200; body = Get-StatusObject } }
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
```

- [ ] **Step 6: 给 `.ps1` 添加 UTF-8 BOM**

```powershell
foreach ($p in @(
    '<项目目录>\remote\remote-server.ps1',
    '<项目目录>\remote\test-remote.ps1'
)) {
    $t = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText($p, $t, (New-Object Text.UTF8Encoding($true)))
}
```

- [ ] **Step 7: 运行测试，确认通过**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "remote\test-remote.ps1"
```

Expected:

```
PASS GET / -> 200
PASS GET / content-type html
PASS GET / has html root
PASS no token -> 401
PASS bad token -> 401
PASS status -> 200
PASS status ok
PASS hostname non-empty
PASS daily targetTime format
PASS unknown path -> 404
PASS wrong method -> 405

通过 11，失败 0
```

- [ ] **Step 8: 检查点**

确认：
- `config.bat` 原有中文仍正常显示（在 cmd 中双击/运行一次 `shutdown-at.bat --dry-run` 不受影响）。
- `remote/server.log` 只出现在临时测试目录，没有被创建到项目目录。

---

### Task 2: 动作接口（排定 / 取消 / 立即关机）

**Files:**
- Modify: `remote/remote-server.ps1`
- Modify: `remote/test-remote.ps1`（追加动作断言）

**Interfaces:**
- Consumes: Task 1 的 `Read-JsonBody` 尚不存在；本任务新增。
- Produces:
  - `POST /api/schedule` body `{"at":"HH:MM"}` 或 `{"inMinutes":N}`
  - `POST /api/cancel` body `{}`
  - `POST /api/shutdown-now` body `{"delaySeconds":N}`（可省略 body）
  - 状态码：200 / 400 / 401 / 404 / 405 / 413 / 500 / 501

- [ ] **Step 1: 在测试脚本中追加剧作断言（先失败）**

在 `remote/test-remote.ps1` 的 `finally` 之前、最后一条断言之后插入：

```powershell
    $r = Call-Api 'POST' '/api/schedule' $token '{"at":"25:99"}'
    Assert-Equal 'bad at -> 400' 400 $r.status

    $r = Call-Api 'POST' '/api/schedule' $token '{"inMinutes":0}'
    Assert-Equal 'bad minutes -> 400' 400 $r.status

    $r = Call-Api 'POST' '/api/schedule' $token '{"at":"23:30"}'
    Assert-Equal 'schedule at -> 200' 200 $r.status
    $j = $r.body | ConvertFrom-Json
    Assert-Equal 'schedule at seconds > 0' $true ($j.seconds -gt 0)

    $r = Call-Api 'GET' '/api/status' $token $null
    $j = $r.body | ConvertFrom-Json
    Assert-Equal 'status shows pending' $true ($null -ne $j.pending)

    $r = Call-Api 'POST' '/api/schedule' $token '{"inMinutes":30}'
    Assert-Equal 'schedule in -> 200' 200 $r.status
    $j = $r.body | ConvertFrom-Json
    Assert-Equal 'schedule in seconds' 1800 $j.seconds

    $r = Call-Api 'POST' '/api/cancel' $token '{}'
    Assert-Equal 'cancel -> 200' 200 $r.status
    $j = $r.body | ConvertFrom-Json
    Assert-Equal 'cancel ok' $true $j.ok
    Assert-Equal 'cancel cancelled' $true $j.cancelled

    $r = Call-Api 'GET' '/api/status' $token $null
    $j = $r.body | ConvertFrom-Json
    Assert-Equal 'pending cleared' $true ($null -eq $j.pending)

    $r = Call-Api 'POST' '/api/shutdown-now' $token '{"delaySeconds":9999}'
    Assert-Equal 'bad delay -> 400' 400 $r.status

    $r = Call-Api 'POST' '/api/shutdown-now' $token '{"delaySeconds":60}'
    Assert-Equal 'shutdown-now -> 200' 200 $r.status
    $j = $r.body | ConvertFrom-Json
    Assert-Equal 'shutdown-now seconds' 60 $j.seconds

    $big = '{"x":"' + ('a' * 5000) + '"}'
    $r = Call-Api 'POST' '/api/schedule' $token $big
    Assert-Equal 'oversize -> 413' 413 $r.status
```

- [ ] **Step 2: 运行测试，确认新断言失败**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "remote\test-remote.ps1"
```

Expected: 出现 `FAIL bad at -> 400` 等（当前动作路由返回 405/404），测试退出码非 0。

- [ ] **Step 3: 在 `remote-server.ps1` 中新增 JSON 读取与关机调用函数**

在 `Test-Token` 函数之后插入：

```powershell
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
            if (-not [int]::TryParse([string]$b.value.delaySeconds, [ref]$d) -or $d -lt 10 -or $d -gt 600) {
                return @{ status = 400; body = [ordered]@{ ok = $false; error = 'delaySeconds 必须在 10 到 600 之间' } }
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
```

- [ ] **Step 4: 把新路由接入请求循环**

把 `switch ("$method $apiPath")` 中的分支替换为：

```powershell
                switch ("$method $apiPath") {
                    'GET /api/status'     { $result = @{ status = 200; body = Get-StatusObject } }
                    'POST /api/schedule'  { $result = Handle-Schedule $req }
                    'POST /api/cancel'    { $result = Handle-Cancel }
                    'POST /api/shutdown-now' { $result = Handle-ShutdownNow $req }
                    default {
                        if ($apiPath -in @('/api/status', '/api/schedule', '/api/cancel', '/api/shutdown-now')) {
                            $result = @{ status = 405; body = [ordered]@{ ok = $false; error = '方法不支持' } }
                        } else {
                            $result = @{ status = 404; body = [ordered]@{ ok = $false; error = '接口不存在' } }
                        }
                    }
                }
```

- [ ] **Step 5: 重新写入 UTF-8 BOM**

```powershell
foreach ($p in @(
    '<项目目录>\remote\remote-server.ps1',
    '<项目目录>\remote\test-remote.ps1'
)) {
    $t = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText($p, $t, (New-Object Text.UTF8Encoding($true)))
}
```

- [ ] **Step 6: 运行测试，确认全部通过**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "remote\test-remote.ps1"
```

Expected: 所有断言 PASS，最后一行 `通过 26，失败 0`（Task 1 的 11 条 + 本任务新增的 15 条），退出码 0。

- [ ] **Step 7: 检查点**

确认测试输出中 `schedule at`、`cancel`、`shutdown-now` 均为 PASS，且测试实例使用 8766 端口、`-DryRun`，没有真正关机。

---

### Task 3: 完整网页控制台

**Files:**
- Modify: `remote/index.html`（替换占位内容）
- Modify: `remote/test-remote.ps1`（追加静态内容断言）

**Interfaces:**
- Consumes: Task 1/2 的 `GET /api/status`、`POST /api/schedule`、`POST /api/cancel`、`POST /api/shutdown-now`
- Produces: 浏览器控制页面；令牌保存在 `localStorage` 键 `asr_token`

- [ ] **Step 1: 追加上失败的静态断言**

在 `remote/test-remote.ps1` 的 `finally` 之前插入：

```powershell
    $r = Call-Api 'GET' '/' $null $null
    Assert-Equal 'UI has token input' $true ($r.body -match 'id="tokenInput"')
    Assert-Equal 'UI has schedule form' $true ($r.body -match 'id="scheduleForm"')
    Assert-Equal 'UI has cancel button' $true ($r.body -match 'id="cancel"')
```

- [ ] **Step 2: 运行测试，确认失败**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "remote\test-remote.ps1"
```

Expected: `FAIL UI has token input` 等。

- [ ] **Step 3: 用完整页面替换 `remote/index.html`**

```html
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>远程关机控制</title>
  <style>
    :root { --bg:#f5f7fa; --card:#fff; --text:#1f2937; --muted:#6b7280; --line:#e5e7eb; --accent:#2563eb; --danger:#dc2626; --ok:#059669; }
    * { box-sizing: border-box; }
    body { margin:0; font-family: "Microsoft YaHei", "PingFang SC", system-ui, sans-serif; background:var(--bg); color:var(--text); }
    header { display:flex; align-items:center; justify-content:space-between; gap:12px; padding:18px 22px; background:#111827; color:#fff; }
    header h1 { font-size:18px; margin:0; font-weight:600; }
    .badge { font-size:12px; padding:3px 9px; border-radius:999px; background:#374151; color:#d1d5db; }
    .badge.ok { background:#065f46; color:#d1fae5; }
    .badge.bad { background:#7f1d1d; color:#fee2e2; }
    main { max-width:820px; margin:22px auto; padding:0 16px; display:grid; gap:16px; }
    .card { background:var(--card); border:1px solid var(--line); border-radius:12px; padding:18px; box-shadow:0 1px 2px rgba(0,0,0,.04); }
    .card h2 { font-size:15px; margin:0 0 14px; }
    dl { display:grid; grid-template-columns: 120px 1fr; gap:8px 14px; margin:0; font-size:14px; }
    dt { color:var(--muted); }
    dd { margin:0; word-break:break-all; }
    form { display:flex; gap:10px; align-items:center; flex-wrap:wrap; }
    input[type=time] { font-size:16px; padding:8px 10px; border:1px solid var(--line); border-radius:8px; }
    button { font-size:14px; padding:9px 14px; border-radius:8px; border:1px solid var(--line); background:#fff; cursor:pointer; }
    button:hover { border-color:#9ca3af; }
    button.primary { background:var(--accent); border-color:var(--accent); color:#fff; }
    button.danger { background:var(--danger); border-color:var(--danger); color:#fff; }
    .quick { display:flex; gap:8px; margin-top:12px; flex-wrap:wrap; }
    .msg { min-height:20px; margin:10px 0 0; font-size:13px; color:var(--muted); }
    .msg.err { color:var(--danger); }
    .msg.ok { color:var(--ok); }
    .overlay { position:fixed; inset:0; background:rgba(17,24,39,.72); display:flex; align-items:center; justify-content:center; padding:20px; z-index:10; }
    .overlay[hidden] { display:none; }
    .login { background:#fff; border-radius:14px; padding:24px; width:min(420px,100%); }
    .login h2 { margin:0 0 8px; font-size:18px; }
    .login p { margin:0 0 14px; color:var(--muted); font-size:13px; line-height:1.6; }
    .login input { width:100%; padding:10px 12px; font-size:15px; border:1px solid var(--line); border-radius:8px; }
    .login button { width:100%; margin-top:12px; }
    .login .msg { color:var(--danger); }
    .row-actions { display:flex; gap:10px; flex-wrap:wrap; }
    .hint { color:var(--muted); font-size:12px; margin-top:10px; }
    @media (max-width:520px) { dl { grid-template-columns: 96px 1fr; } }
  </style>
</head>
<body>
  <div id="login" class="overlay">
    <form id="loginForm" class="login">
      <h2>输入访问令牌</h2>
      <p>令牌在目标电脑的 <code>remote\token.txt</code> 中。只需输入一次，浏览器会记住。</p>
      <input id="tokenInput" type="password" autocomplete="current-password" placeholder="32 位令牌">
      <button type="submit" class="primary">连接</button>
      <p id="loginMsg" class="msg"></p>
    </form>
  </div>

  <header>
    <h1><span id="hostname">目标电脑</span> · 远程关机</h1>
    <span id="conn" class="badge">未连接</span>
  </header>

  <main>
    <section class="card">
      <h2>状态</h2>
      <dl>
        <dt>目标机时间</dt><dd id="now">—</dd>
        <dt>每日任务</dt><dd id="daily">—</dd>
        <dt>下次自动运行</dt><dd id="nextRun">—</dd>
        <dt>本次排定</dt><dd id="pending">—</dd>
        <dt>最近操作</dt><dd id="lastAction">—</dd>
      </dl>
      <p class="hint">页面每 5 秒自动刷新。电脑需保持登录（锁屏可以）。</p>
    </section>

    <section class="card">
      <h2>定时关机</h2>
      <form id="scheduleForm">
        <input id="at" type="time" value="23:30" required>
        <button type="submit" class="primary">排定关机</button>
      </form>
      <div class="quick">
        <button type="button" data-min="10">10 分钟后</button>
        <button type="button" data-min="30">30 分钟后</button>
        <button type="button" data-min="60">60 分钟后</button>
      </div>
      <p id="scheduleMsg" class="msg"></p>
    </section>

    <section class="card">
      <h2>危险操作</h2>
      <div class="row-actions">
        <button id="shutdownNow" type="button" class="danger">立即关机（60 秒后）</button>
        <button id="cancel" type="button">取消关机</button>
        <button id="changeToken" type="button">更换令牌</button>
      </div>
      <p id="dangerMsg" class="msg"></p>
    </section>
  </main>

  <script>
    (function () {
      'use strict';
      var TOKEN_KEY = 'asr_token';
      var token = localStorage.getItem(TOKEN_KEY) || '';
      var $ = function (id) { return document.getElementById(id); };

      function fmt(v) {
        if (!v) { return '—'; }
        var d = new Date(v);
        if (isNaN(d.getTime())) { return String(v); }
        return d.toLocaleString('zh-CN', { hour12: false });
      }

      function stateText(s) {
        return ({ Ready: '启用', Running: '运行中', Disabled: '已暂停', MISSING: '未安装' })[s] || s || '未知';
      }

      function actionText(a) {
        return ({ schedule: '定时关机', 'schedule-in': '延时关机', cancel: '取消关机', 'shutdown-now': '立即关机' })[a] || a || '—';
      }

      function setOnline(ok) {
        var el = $('conn');
        el.textContent = ok ? '已连接' : '连接失败';
        el.className = 'badge ' + (ok ? 'ok' : 'bad');
      }

      function showLogin(msg) {
        $('login').hidden = false;
        $('loginMsg').textContent = msg || '';
        $('tokenInput').focus();
      }

      function hideLogin() { $('login').hidden = true; }

      function msg(id, text, isErr) {
        var el = $(id);
        el.textContent = text;
        el.className = 'msg ' + (isErr ? 'err' : 'ok');
      }

      async function api(path, options) {
        options = options || {};
        var headers = Object.assign({ 'Content-Type': 'application/json' }, options.headers || {});
        if (token) { headers['Authorization'] = 'Bearer ' + token; }
        var res;
        try {
          res = await fetch(path, Object.assign({}, options, { headers: headers, cache: 'no-store' }));
        } catch (e) {
          setOnline(false);
          throw new Error('无法连接目标电脑');
        }
        var data = null;
        try { data = await res.json(); } catch (e) { }
        if (res.status === 401) {
          token = '';
          localStorage.removeItem(TOKEN_KEY);
          showLogin('令牌无效，请重新输入');
          throw new Error('令牌无效');
        }
        if (!res.ok || !data || data.ok === false) {
          throw new Error((data && data.error) || ('HTTP ' + res.status));
        }
        setOnline(true);
        return data;
      }

      async function refresh() {
        try {
          var s = await api('/api/status');
          $('hostname').textContent = s.hostname || '目标电脑';
          $('now').textContent = fmt(s.now);
          var d = s.daily || {};
          $('daily').textContent = (d.taskName || '任务') + '：' + stateText(d.state) +
            '（每日 ' + (d.targetTime || '—') + '，提前 ' + (d.leadMinutes != null ? d.leadMinutes : '—') + ' 分钟）';
          $('nextRun').textContent = d.nextRunTime ? fmt(d.nextRunTime) : '—';
          if (s.pending) {
            $('pending').textContent = fmt(s.pending.at) + '（剩 ' + s.pending.secondsRemaining + ' 秒）';
          } else {
            $('pending').textContent = '无（网页未排定）';
          }
          if (s.lastAction) {
            $('lastAction').textContent = actionText(s.lastAction.action) + ' @ ' + fmt(s.lastAction.at) +
              ' ' + (s.lastAction.ok ? '成功' : '失败');
          } else {
            $('lastAction').textContent = '—';
          }
          if (!$('at').dataset.touched && d.targetTime) { $('at').value = d.targetTime; }
          hideLogin();
        } catch (e) {
          if (token) { setOnline(false); }
        }
      }

      $('loginForm').addEventListener('submit', async function (e) {
        e.preventDefault();
        var v = $('tokenInput').value.trim();
        if (!v) { return; }
        token = v;
        localStorage.setItem(TOKEN_KEY, token);
        try {
          await refresh();
          if (!$('login').hidden) { $('loginMsg').textContent = '仍然无法连接，请检查令牌和网络。'; }
        } catch (err) {
          $('loginMsg').textContent = err.message;
        }
      });

      $('at').addEventListener('input', function () { $('at').dataset.touched = '1'; });

      $('scheduleForm').addEventListener('submit', async function (e) {
        e.preventDefault();
        var at = $('at').value;
        try {
          var r = await api('/api/schedule', { method: 'POST', body: JSON.stringify({ at: at }) });
          msg('scheduleMsg', '已排定 ' + at + '，约 ' + Math.round(r.seconds / 60) + ' 分钟后关机', false);
          refresh();
        } catch (err) {
          msg('scheduleMsg', err.message, true);
        }
      });

      Array.prototype.forEach.call(document.querySelectorAll('[data-min]'), function (btn) {
        btn.addEventListener('click', async function () {
          var n = parseInt(btn.getAttribute('data-min'), 10);
          try {
            await api('/api/schedule', { method: 'POST', body: JSON.stringify({ inMinutes: n }) });
            msg('scheduleMsg', '已排定 ' + n + ' 分钟后关机', false);
            refresh();
          } catch (err) {
            msg('scheduleMsg', err.message, true);
          }
        });
      });

      $('shutdownNow').addEventListener('click', async function () {
        if (!confirm('确定让目标电脑在 60 秒后关机吗？\n期间可以点“取消关机”。')) { return; }
        try {
          await api('/api/shutdown-now', { method: 'POST', body: JSON.stringify({ delaySeconds: 60 }) });
          msg('dangerMsg', '已排定 60 秒后关机', false);
          refresh();
        } catch (err) {
          msg('dangerMsg', err.message, true);
        }
      });

      $('cancel').addEventListener('click', async function () {
        try {
          var r = await api('/api/cancel', { method: 'POST', body: '{}' });
          if (r.cancelled) { msg('dangerMsg', '已取消关机', false); }
          else { msg('dangerMsg', '当前没有待取消的关机', true); }
          refresh();
        } catch (err) {
          msg('dangerMsg', err.message, true);
        }
      });

      $('changeToken').addEventListener('click', function () {
        token = '';
        localStorage.removeItem(TOKEN_KEY);
        showLogin('请输入新的令牌');
      });

      if (token) { hideLogin(); refresh(); } else { showLogin(); }
      setInterval(function () { if (token) { refresh(); } }, 5000);
    })();
  </script>
</body>
</html>
```

- [ ] **Step 4: 运行测试，确认通过**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "remote\test-remote.ps1"
```

Expected: 全部 PASS，包括 `UI has token input` / `UI has schedule form` / `UI has cancel button`。

- [ ] **Step 5: 手工检查页面（dry-run）**

启动 dry-run 实例（不要接真实计划任务）：

```powershell
$dd = Join-Path $env:TEMP 'asr-ui-check'
powershell -NoProfile -ExecutionPolicy Bypass -File "remote\remote-server.ps1" -Port 8766 -DryRun -LocalOnly -DataDir $dd
```

另开一个窗口：

```powershell
start http://127.0.0.1:8766/
```

Expected:
- 首次弹出令牌层；输入 `remote/token.txt` 的内容后进入主界面。
- 状态卡显示主机名、每日任务、下次运行时间。
- 点"30 分钟后"显示"已排定 30 分钟后关机"，状态卡出现本次排定。
- 点"取消关机"显示"已取消关机"。
- 关闭 dry-run 窗口后，页面在 5 秒内显示"连接失败"。

- [ ] **Step 6: 检查点**

确认页面没有引用任何外部 CDN/字体，所有中文显示正常，且 `remote/token.txt` 没有被写入页面源码。

---

### Task 4: 安装脚本（URL ACL、防火墙、登录自启任务）

**Files:**
- Create: `remote/install-remote.ps1`
- Create: `remote/install-remote.bat`

**Interfaces:**
- Consumes: `config.bat` 的 `REMOTE_PORT`；`remote/remote-server.ps1`、`remote/index.html`、`remote/token.txt`
- Produces:
  - 计划任务 `AutoShutdownRemote`（AtLogOn，当前用户，Limited）
  - 防火墙规则 `AutoShutdownRemote`（TCP，`remoteip=LocalSubnet`）
  - URL ACL `http://+:<PORT>/`
  - `remote/install-state.json`

- [ ] **Step 1: 创建 `remote/install-remote.ps1`**

```powershell
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

if (-not (Test-Path -LiteralPath $Server) -or -not (Test-Path -LiteralPath $Index)) {
    Write-Host 'remote-server.ps1 或 index.html 缺失。' -ForegroundColor Red
    exit 1
}

if ($Port -le 0) {
    $v = Get-ConfigValue 'REMOTE_PORT' '8765'
    $n = 0
    if ([int]::TryParse($v, [ref]$n) -and $n -ge 1 -and $n -le 65535) { $Port = $n } else { $Port = 8765 }
}

$owner = $null
try { $owner = (Get-Acl -LiteralPath $Root).Owner } catch { }
if (-not $owner) { $owner = "$env:USERDOMAIN\$env:USERNAME" }

Write-Host "项目目录: $Root"
Write-Host "端口: $Port"
Write-Host "服务身份: $owner"

$listen = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($listen) {
    Write-Host "端口 $Port 已被占用，请修改 config.bat 的 REMOTE_PORT 后重试。" -ForegroundColor Red
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
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $Server)
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $owner
    $principal = New-ScheduledTaskPrincipal -UserId $owner -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
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
```

- [ ] **Step 2: 创建 `remote/install-remote.bat`**

```bat
@echo off
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "SCRIPT=%~dp0install-remote.ps1"
"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "if (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { & '%SCRIPT%' } else { Start-Process -FilePath '%PS%' -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','%SCRIPT%') }"
exit /b 0
```

- [ ] **Step 3: 添加 UTF-8 BOM**

```powershell
$p = '<项目目录>\remote\install-remote.ps1'
$t = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
[IO.File]::WriteAllText($p, $t, (New-Object Text.UTF8Encoding($true)))
```

- [ ] **Step 4: 用 `-WhatIf` 验证安装逻辑（不改系统、不提权）**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "remote\install-remote.ps1" -WhatIf -NoPause
```

Expected:
- 退出码 0
- 输出包含 `端口: 8765`、`服务身份: <计算机名>\<用户名>`
- 出现 `What if: 正在执行操作 "注册 URL ACL"...`、防火墙、计划任务对应的 WhatIf 提示
- 末尾打印访问地址和令牌路径
- 系统没有任何实际改动（可运行 `netsh http show urlacl | findstr 8765` 和 `schtasks /query /tn AutoShutdownRemote` 确认仍为空）

- [ ] **Step 5: 检查点**

审查安装脚本：
- 所有系统修改都在 `ShouldProcess` 中
- 令牌只在不存在时生成
- 防火墙规则带 `remoteip=LocalSubnet`
- 任务使用 `RunLevel Limited`、`ExecutionTimeLimit=0`

---

### Task 5: 卸载脚本

**Files:**
- Create: `remote/uninstall-remote.ps1`
- Create: `remote/uninstall-remote.bat`

**Interfaces:**
- Consumes: `remote/install-state.json`（缺省回退到 `config.bat` 的 `REMOTE_PORT`）
- Produces: 删除任务/防火墙/URL ACL；可选 `-Purge` 删除令牌和日志

- [ ] **Step 1: 创建 `remote/uninstall-remote.ps1`**

```powershell
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
```

- [ ] **Step 2: 创建 `remote/uninstall-remote.bat`**

```bat
@echo off
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "SCRIPT=%~dp0uninstall-remote.ps1"
"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "if (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { & '%SCRIPT%' } else { Start-Process -FilePath '%PS%' -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','%SCRIPT%') }"
exit /b 0
```

- [ ] **Step 3: 添加 UTF-8 BOM**

```powershell
$p = '<项目目录>\remote\uninstall-remote.ps1'
$t = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
[IO.File]::WriteAllText($p, $t, (New-Object Text.UTF8Encoding($true)))
```

- [ ] **Step 4: 用 `-WhatIf` 验证**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "remote\uninstall-remote.ps1" -WhatIf -NoPause
```

Expected:
- 退出码 0
- 输出 `卸载完成。`
- 出现停止任务、删除防火墙、删除 URL ACL 的 WhatIf 提示
- 系统无实际改动

- [ ] **Step 5: 检查点**

确认 `-Purge` 默认不删除令牌和日志；仅在显式传入时删除。

---

### Task 6: 端到端验收（手工，需要 UAC 和另一台电脑）

**Files:** 无新增；使用前面任务产物。

**Interfaces:**
- Consumes: 全部实现
- Produces: 验收记录

- [ ] **Step 1: 真实安装**

双击 `remote/install-remote.bat`，在 UAC 弹窗点"是"。
Expected:
- 控制台打印端口、服务身份、访问地址、令牌路径
- 打印的地址包含 `http://<目标机IP>:8765/`（以实际网卡为准）

- [ ] **Step 2: 本机自检**

```powershell
Get-ScheduledTask -TaskName AutoShutdownRemote | Select-Object TaskName, State
Get-NetTCPConnection -LocalPort 8765 -State Listen | Select-Object LocalAddress, LocalPort, State
```

Expected: 任务 `Ready` 或 `Running`；8765 处于 `Listen`。

- [ ] **Step 3: 本机浏览器验证**

打开 `http://127.0.0.1:8765/`，输入 `remote/token.txt` 的内容。
Expected: 状态卡显示主机名和每日任务；页面无报错。

- [ ] **Step 4: 另一台电脑验证**

1. 打开 `http://<目标机IP>:8765/`
2. 输入令牌
3. 点"30 分钟后"，确认状态卡显示"本次排定"
4. 点"取消关机"，确认显示"已取消关机"
5. 点"立即关机（60 秒后）"，确认目标机出现关机提示；在 60 秒内点"取消关机"

Expected: 以上全部成功；`remote/server.log` 记录每次操作和来源 IP。

- [ ] **Step 5: 重启恢复验证**

重启目标机并登录。
Expected: `AutoShutdownRemote` 自动运行，浏览器刷新后恢复"已连接"。

- [ ] **Step 6: 记录验收结果**

把结果写入 `docs/superpowers/plans/2026-10-24-remote-control-acceptance.md`，包含：
- 测试时间
- 目标机 IP
- 通过的步骤
- 未通过/受限的步骤及原因

---

## 计划自检

**Spec coverage:**

| Spec 章节 | 对应任务 |
|---|---|
| 3.1 文件布局 | Task 1 / 4 / 5 |
| 3.2 组件职责 | Task 1–5 |
| 3.3 数据流 | Task 1–3 |
| 3.4 启动方式 | Task 4 |
| 3.5 服务参数 | Task 1 |
| 4 网络与端口 | Task 1 / 4 |
| 5 API 规范 | Task 1 / 2 |
| 6 网页界面 | Task 3 |
| 7 安全模型 | Task 1 / 2 / 4 |
| 8 安装流程 | Task 4 |
| 9 卸载流程 | Task 5 |
| 10 日志 | Task 1 |
| 11 错误处理 | Task 1 / 2 |
| 12 编码约定 | 各任务末尾 |
| 13 测试计划 | Task 1–3 / 6 |
| 14 已知限制 | Task 6 验收记录 |

**Placeholder scan:** 无 TBD/TODO；所有代码步骤包含完整内容。

**Type consistency:** 参数名 `-Port`、`-DryRun`、`-LocalOnly`、`-DataDir` 在服务、测试、安装脚本中一致；状态字段 `hostname` / `now` / `daily` / `pending` / `lastAction` 在服务与页面中一致；动作响应字段 `ok` / `mode` / `seconds` / `cancelled` 前后一致。
