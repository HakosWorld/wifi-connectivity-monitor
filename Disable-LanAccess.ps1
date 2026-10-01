[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ruleName = 'Wi-Fi Drop Monitor Dashboard'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)

if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    exit $process.ExitCode
}

Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
Write-Output 'LAN dashboard firewall access disabled.'
