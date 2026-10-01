[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$failures = New-Object System.Collections.Generic.List[string]

function Add-Failure {
    param([string]$Message)
    $failures.Add($Message)
}

foreach ($scriptFile in Get-ChildItem -LiteralPath $projectRoot -Filter '*.ps1' -File) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $scriptFile.FullName,
        [ref]$tokens,
        [ref]$errors
    )
    foreach ($parseError in $errors) {
        Add-Failure "$($scriptFile.Name):$($parseError.Extent.StartLineNumber) $($parseError.Message)"
    }
}

$dashboardPath = Join-Path $projectRoot 'dashboard.html'
$dashboard = [System.IO.File]::ReadAllText($dashboardPath)
foreach ($elementId in @(
    'statusText',
    'wifiName',
    'timelineCanvas',
    'latencyCanvas',
    'lossCanvas',
    'outageRows',
    'openReset',
    'resetDialog',
    'resetPassword'
)) {
    $count = ([regex]::Matches($dashboard, "id=[`"']$([regex]::Escape($elementId))[`"']")).Count
    if ($count -ne 1) {
        Add-Failure "dashboard.html must contain exactly one '$elementId' element; found $count."
    }
}

foreach ($endpoint in @('/api/data', '/api/reset')) {
    if (-not $dashboard.Contains($endpoint)) {
        Add-Failure "dashboard.html does not reference $endpoint."
    }
}

$serverScript = [System.IO.File]::ReadAllText((Join-Path $projectRoot 'Update-WifiReport.ps1'))
if (-not $serverScript.Contains('reset-password.txt')) {
    Add-Failure 'Update-WifiReport.ps1 does not load the reset password from local data.'
}
if (-not $serverScript.Contains('[System.Net.IPAddress]::Any')) {
    Add-Failure 'Update-WifiReport.ps1 is not configured to accept LAN connections.'
}
if (-not $serverScript.Contains('LanUrl')) {
    Add-Failure 'Update-WifiReport.ps1 does not publish the LAN dashboard URL.'
}
if (-not $serverScript.Contains('PacketLossSeries')) {
    Add-Failure 'Update-WifiReport.ps1 does not publish packet-loss history.'
}
if ($serverScript -match '\[string\]\$ResetPassword\s*=') {
    Add-Failure 'The reset password must not have a source-controlled default value.'
}

foreach ($launcher in Get-ChildItem -LiteralPath $projectRoot -Filter '*.cmd' -File) {
    $content = [System.IO.File]::ReadAllText($launcher.FullName)
    $matches = [regex]::Matches($content, '%~dp0([^`"]+\.ps1)')
    foreach ($match in $matches) {
        $target = Join-Path $projectRoot $match.Groups[1].Value
        if (-not (Test-Path -LiteralPath $target)) {
            Add-Failure "$($launcher.Name) references missing script $($match.Groups[1].Value)."
        }
    }
}

if ($failures.Count -gt 0) {
    throw "Project checks failed:`n - $($failures -join "`n - ")"
}

Write-Output 'Project checks passed.'
