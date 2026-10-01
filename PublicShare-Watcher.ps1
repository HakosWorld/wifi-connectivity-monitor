[CmdletBinding()]
param(
    [string]$DataDirectory = (Join-Path $env:LOCALAPPDATA 'WifiConnectivityMonitor'),
    [string]$CloudflaredPath = (Join-Path (Join-Path $env:LOCALAPPDATA 'WifiConnectivityMonitor') 'bin\cloudflared.exe')
)

$ErrorActionPreference = 'Stop'
$mutex = New-Object System.Threading.Mutex($false, 'Local\WifiConnectivityMonitor.PublicShare.Singleton')
$ownsMutex = $false
$tunnelProcess = $null
$shareInstanceId = [guid]::NewGuid().ToString('N')
$shareInfoPath = Join-Path $DataDirectory 'public-share.json'
$dashboardInfoPath = Join-Path $DataDirectory 'dashboard-server.json'
$statusPath = Join-Path $DataDirectory 'status.json'
$stdoutPath = Join-Path $DataDirectory 'public-share.stdout.log'
$stderrPath = Join-Path $DataDirectory 'public-share.stderr.log'

function Test-MonitorAlive {
    if (-not (Test-Path -LiteralPath $statusPath)) { return $false }
    try {
        $status = Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json
        return $status.Running -and $null -ne (Get-Process -Id $status.ProcessId -ErrorAction SilentlyContinue)
    }
    catch { return $false }
}

function Get-DashboardUrl {
    if (-not (Test-Path -LiteralPath $dashboardInfoPath)) { return $null }
    try {
        $dashboard = Get-Content -Raw -LiteralPath $dashboardInfoPath | ConvertFrom-Json
        if ($null -ne (Get-Process -Id $dashboard.ProcessId -ErrorAction SilentlyContinue)) {
            return [string]$dashboard.Url
        }
    }
    catch { }
    return $null
}

try {
    $ownsMutex = $mutex.WaitOne(0, $false)
    if (-not $ownsMutex) { exit 0 }
    if (-not (Test-Path -LiteralPath $CloudflaredPath)) { throw "cloudflared was not found at $CloudflaredPath" }

    while (Test-MonitorAlive) {
        $dashboardUrl = Get-DashboardUrl
        if ([string]::IsNullOrWhiteSpace($dashboardUrl)) {
            Start-Sleep -Seconds 2
            continue
        }

        Set-Content -LiteralPath $stdoutPath -Value '' -Encoding UTF8
        Set-Content -LiteralPath $stderrPath -Value '' -Encoding UTF8
        $tunnelProcess = Start-Process -FilePath $CloudflaredPath -ArgumentList @('tunnel', '--url', $dashboardUrl, '--no-autoupdate') -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru

        $publicUrl = $null
        $urlDeadline = (Get-Date).AddSeconds(45)
        while ($null -eq $publicUrl -and -not $tunnelProcess.HasExited -and (Get-Date) -lt $urlDeadline) {
            Start-Sleep -Milliseconds 500
            $logText = ''
            if (Test-Path -LiteralPath $stdoutPath) { $logText += Get-Content -Raw -LiteralPath $stdoutPath -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $stderrPath) { $logText += Get-Content -Raw -LiteralPath $stderrPath -ErrorAction SilentlyContinue }
            $urlMatch = [regex]::Match($logText, 'https://[a-z0-9-]+\.trycloudflare\.com', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($urlMatch.Success) { $publicUrl = $urlMatch.Value }
        }

        if ($null -ne $publicUrl) {
            [pscustomobject]@{
                Running          = $true
                InstanceId       = $shareInstanceId
                WatcherProcessId = $PID
                TunnelProcessId  = $tunnelProcess.Id
                Url              = $publicUrl
                LocalUrl         = $dashboardUrl
                StartedAt        = [DateTimeOffset]::Now.ToString('o')
                TemporaryUrl     = $true
            } | ConvertTo-Json | Set-Content -LiteralPath $shareInfoPath -Encoding UTF8
        }

        while (-not $tunnelProcess.HasExited -and (Test-MonitorAlive)) {
            Start-Sleep -Seconds 2
        }

        if (-not $tunnelProcess.HasExited) {
            Stop-Process -Id $tunnelProcess.Id -ErrorAction SilentlyContinue
            $tunnelProcess.WaitForExit(5000) | Out-Null
        }
        $tunnelProcess = $null
        if (Test-MonitorAlive) { Start-Sleep -Seconds 10 }
    }
}
finally {
    if ($null -ne $tunnelProcess -and -not $tunnelProcess.HasExited) {
        Stop-Process -Id $tunnelProcess.Id -ErrorAction SilentlyContinue
    }
    try {
        if (Test-Path -LiteralPath $shareInfoPath) {
            $currentInfo = Get-Content -Raw -LiteralPath $shareInfoPath | ConvertFrom-Json
            if ($currentInfo.InstanceId -eq $shareInstanceId) { Remove-Item -LiteralPath $shareInfoPath -Force }
        }
    }
    catch { }
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
