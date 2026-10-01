[CmdletBinding()]
param(
    [string]$DataDirectory = (Join-Path $env:LOCALAPPDATA 'WifiConnectivityMonitor')
)

$serverInfoPath = Join-Path $DataDirectory 'dashboard-server.json'
$serverInfo = $null
if (Test-Path -LiteralPath $serverInfoPath) {
    try {
        $candidate = Get-Content -Raw -LiteralPath $serverInfoPath | ConvertFrom-Json
        if ($null -ne (Get-Process -Id $candidate.ProcessId -ErrorAction SilentlyContinue)) { $serverInfo = $candidate }
    }
    catch { $serverInfo = $null }
}

if ($null -ne $serverInfo) {
    Start-Process -FilePath $serverInfo.Url
} else {
    & (Join-Path $PSScriptRoot 'Get-WifiReport.ps1') -DataDirectory $DataDirectory
}
