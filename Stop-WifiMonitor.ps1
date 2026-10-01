[CmdletBinding()]
param(
    [string]$DataDirectory = (Join-Path $env:LOCALAPPDATA 'WifiConnectivityMonitor')
)

$ErrorActionPreference = 'Stop'
$statusPath = Join-Path $DataDirectory 'status.json'
$stopRequestPath = Join-Path $DataDirectory 'stop.request.json'
$serverInfoPath = Join-Path $DataDirectory 'dashboard-server.json'
$shareInfoPath = Join-Path $DataDirectory 'public-share.json'

if (-not (Test-Path -LiteralPath $statusPath)) {
    Write-Output 'No Wi-Fi monitor status was found; it does not appear to be running.'
    exit 0
}

$status = Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json
$process = Get-Process -Id $status.ProcessId -ErrorAction SilentlyContinue
if (-not $status.Running -or $null -eq $process) {
    Write-Output 'The Wi-Fi monitor is already stopped.'
    exit 0
}

$request = [pscustomobject]@{
    InstanceId = $status.InstanceId
    RequestedAt = [DateTimeOffset]::Now.ToString('o')
}
$request | ConvertTo-Json | Set-Content -LiteralPath $stopRequestPath -Encoding UTF8

$deadline = (Get-Date).AddSeconds(8)
do {
    Start-Sleep -Milliseconds 250
    $process = Get-Process -Id $status.ProcessId -ErrorAction SilentlyContinue
} until ($null -eq $process -or (Get-Date) -ge $deadline)

if ($null -ne $process) {
    throw 'The monitor did not stop within 8 seconds. No process was forcibly terminated.'
}

$serverProcess = $null
if (Test-Path -LiteralPath $serverInfoPath) {
    try {
        $serverInfo = Get-Content -Raw -LiteralPath $serverInfoPath | ConvertFrom-Json
        $serverProcess = Get-Process -Id $serverInfo.ProcessId -ErrorAction SilentlyContinue
        $serverDeadline = (Get-Date).AddSeconds(5)
        while ($null -ne $serverProcess -and (Get-Date) -lt $serverDeadline) {
            Start-Sleep -Milliseconds 250
            $serverProcess = Get-Process -Id $serverInfo.ProcessId -ErrorAction SilentlyContinue
        }
    }
    catch { $serverProcess = $null }
}

if (Test-Path -LiteralPath $shareInfoPath) {
    try {
        $shareInfo = Get-Content -Raw -LiteralPath $shareInfoPath | ConvertFrom-Json
        foreach ($shareProcessId in @($shareInfo.TunnelProcessId, $shareInfo.WatcherProcessId)) {
            if ($null -ne $shareProcessId) {
                $shareProcess = Get-Process -Id $shareProcessId -ErrorAction SilentlyContinue
                if ($null -ne $shareProcess) { Stop-Process -Id $shareProcessId -ErrorAction SilentlyContinue }
            }
        }
        Remove-Item -LiteralPath $shareInfoPath -Force -ErrorAction SilentlyContinue
    }
    catch { }
}

Write-Output 'Wi-Fi monitor stopped cleanly.'
