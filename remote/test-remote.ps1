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

    $r = Call-Api 'POST' '/api/shutdown-now' $token '{"delaySeconds":0}'
    Assert-Equal 'shutdown-now 0 -> 200' 200 $r.status
    $j = $r.body | ConvertFrom-Json
    Assert-Equal 'shutdown-now 0 seconds' 0 $j.seconds

    $r = Call-Api 'POST' '/api/shutdown-now' $token '{"delaySeconds":-1}'
    Assert-Equal 'negative delay -> 400' 400 $r.status

    $big = '{"x":"' + ('a' * 5000) + '"}'
    $r = Call-Api 'POST' '/api/schedule' $token $big
    Assert-Equal 'oversize -> 413' 413 $r.status

    $r = Call-Api 'GET' '/' $null $null
    Assert-Equal 'UI has token input' $true ($r.body -match 'id="tokenInput"')
    Assert-Equal 'UI has schedule form' $true ($r.body -match 'id="scheduleForm"')
    Assert-Equal 'UI has cancel button' $true ($r.body -match 'id="cancel"')
    Assert-Equal 'UI has hard shutdown' $true ($r.body -match 'id="shutdownHard"')
    Assert-Equal 'UI has no 60s button' $true ($r.body -notmatch 'id="shutdownNow"')
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
