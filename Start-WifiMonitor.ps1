[CmdletBinding()]
param(
    [string]$DataDirectory = (Join-Path $env:LOCALAPPDATA 'WifiConnectivityMonitor'),
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$monitorScript = Join-Path $PSScriptRoot 'Monitor-Wifi.ps1'
$reportScript = Join-Path $PSScriptRoot 'Get-WifiReport.ps1'
$reportLoopScript = Join-Path $PSScriptRoot 'Update-WifiReport.ps1'
$publicShareInstaller = Join-Path $PSScriptRoot 'Install-PublicShare.ps1'
$publicShareWatcher = Join-Path $PSScriptRoot 'PublicShare-Watcher.ps1'
$statusPath = Join-Path $DataDirectory 'status.json'
$resetPasswordPath = Join-Path $DataDirectory 'reset-password.txt'

New-Item -ItemType Directory -Path $DataDirectory -Force | Out-Null
if (-not (Test-Path -LiteralPath $resetPasswordPath)) {
    throw 'Set the dashboard reset password first by running Set Dashboard Password.cmd.'
}
$arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$monitorScript`" -DataDirectory `"$DataDirectory`""
Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden | Out-Null

$deadline = (Get-Date).AddSeconds(20)
do {
    Start-Sleep -Milliseconds 250
    $status = $null
    if (Test-Path -LiteralPath $statusPath) {
        try { $status = Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json } catch { $status = $null }
    }
} until (($null -ne $status -and $status.Running) -or (Get-Date) -ge $deadline)

if ($null -eq $status -or -not $status.Running) {
    throw 'The Wi-Fi monitor did not start within 20 seconds. Run Monitor-Wifi.ps1 in a PowerShell window to see the error.'
}

$reportArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$reportLoopScript`" -DataDirectory `"$DataDirectory`""
Start-Process -FilePath 'powershell.exe' -ArgumentList $reportArguments -WindowStyle Hidden | Out-Null

$serverInfoPath = Join-Path $DataDirectory 'dashboard-server.json'
$serverDeadline = (Get-Date).AddSeconds(10)
do {
    Start-Sleep -Milliseconds 200
    $serverInfo = $null
    if (Test-Path -LiteralPath $serverInfoPath) {
        try {
            $candidate = Get-Content -Raw -LiteralPath $serverInfoPath | ConvertFrom-Json
            if ($null -ne (Get-Process -Id $candidate.ProcessId -ErrorAction SilentlyContinue)) { $serverInfo = $candidate }
        }
        catch { $serverInfo = $null }
    }
} until ($null -ne $serverInfo -or (Get-Date) -ge $serverDeadline)

if ($null -ne $serverInfo) {
    $cloudflaredPath = Join-Path (Join-Path $DataDirectory 'bin') 'cloudflared.exe'
    if (-not (Test-Path -LiteralPath $cloudflaredPath)) {
        try { $cloudflaredPath = & $publicShareInstaller -DataDirectory $DataDirectory | Select-Object -Last 1 }
        catch { Write-Warning "Public sharing could not be installed: $($_.Exception.Message)" }
    }
    if (Test-Path -LiteralPath $cloudflaredPath) {
        $shareArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$publicShareWatcher`" -DataDirectory `"$DataDirectory`" -CloudflaredPath `"$cloudflaredPath`""
        Start-Process -FilePath 'powershell.exe' -ArgumentList $shareArguments -WindowStyle Hidden | Out-Null
    }

    if (-not $NoBrowser) { Start-Process -FilePath $serverInfo.Url }
    Write-Output "Wi-Fi monitor is running in the background. Live dashboard: $($serverInfo.Url)"
    if ($null -ne $serverInfo.PSObject.Properties['LanUrl'] -and -not [string]::IsNullOrWhiteSpace([string]$serverInfo.LanUrl)) {
        Write-Output "LAN dashboard: $($serverInfo.LanUrl)"
    }

    $shareInfoPath = Join-Path $DataDirectory 'public-share.json'
    $shareDeadline = (Get-Date).AddSeconds(50)
    do {
        Start-Sleep -Milliseconds 500
        $shareInfo = $null
        if (Test-Path -LiteralPath $shareInfoPath) {
            try {
                $candidate = Get-Content -Raw -LiteralPath $shareInfoPath | ConvertFrom-Json
                if ($candidate.Running -and $null -ne (Get-Process -Id $candidate.TunnelProcessId -ErrorAction SilentlyContinue)) { $shareInfo = $candidate }
            }
            catch { $shareInfo = $null }
        }
    } until ($null -ne $shareInfo -or (Get-Date) -ge $shareDeadline)
    if ($null -ne $shareInfo) { Write-Output "Public dashboard: $($shareInfo.Url)" }
    else { Write-Warning 'The public dashboard tunnel is still unavailable. Monitoring and the local dashboard are running.' }
}
else {
    & $reportScript -DataDirectory $DataDirectory -NoOpen | Out-Null
    if (-not $NoBrowser) { Start-Process -FilePath (Join-Path $DataDirectory 'wifi-report.html') }
    Write-Warning 'The live dashboard server did not start; the static fallback report was opened instead.'
}
