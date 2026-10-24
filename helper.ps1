param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('sec', 'runat', 'state')]
    [string]$Mode,

    [string]$Time,
    [int]$Lead = 10,
    [string]$TaskName = 'AutoShutdownDaily'
)

$ErrorActionPreference = 'Stop'

switch ($Mode) {
    'sec' {
        if ($Time -notmatch '^(\d{1,2}):(\d{2})$') { 'ERR'; exit 0 }
        $h = [int]$Matches[1]
        $m = [int]$Matches[2]
        if ($h -gt 23 -or $m -gt 59) { 'ERR'; exit 0 }

        $now = Get-Date
        $target = $now.Date.AddHours($h).AddMinutes($m)
        $day = 'today'
        if ($target -le $now) {
            $target = $target.AddDays(1)
            $day = 'tomorrow'
        }
        $sec = [int]($target - $now).TotalSeconds
        "$sec $day"
    }
    'runat' {
        if ($Time -notmatch '^(\d{1,2}):(\d{2})$') { 'ERR'; exit 0 }
        $t = [datetime]::Today.AddHours([int]$Matches[1]).AddMinutes([int]$Matches[2])
        $t = $t.AddMinutes(-$Lead)
        $t.ToString('HH:mm')
    }
    'state' {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if (-not $task) { 'MISSING' }
        elseif ($task.State -eq 'Disabled') { 'ENABLE' }
        else { 'DISABLE' }
    }
}
