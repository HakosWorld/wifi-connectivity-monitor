[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 8765
)

$ErrorActionPreference = 'Stop'
$ruleName = 'Wi-Fi Drop Monitor Dashboard'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)

if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Port $Port"
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    exit $process.ExitCode
}

$existingRule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
if ($null -ne $existingRule) {
    Remove-NetFirewallRule -DisplayName $ruleName
}

New-NetFirewallRule `
    -DisplayName $ruleName `
    -Description 'Allow the Wi-Fi Drop Monitor dashboard from the local subnet only.' `
    -Direction Inbound `
    -Action Allow `
    -Protocol TCP `
    -LocalPort $Port `
    -RemoteAddress LocalSubnet `
    -Profile Any | Out-Null

Write-Output "LAN access enabled for TCP port $Port from the local subnet."
