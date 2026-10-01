[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$startupDirectory = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startupDirectory 'WiFi Connectivity Monitor.lnk'
$launcherPath = Join-Path $PSScriptRoot 'Start-WifiMonitor.ps1'
$powershellPath = (Get-Command powershell.exe -ErrorAction Stop).Source

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $powershellPath
$shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcherPath`" -NoBrowser"
$shortcut.WorkingDirectory = $PSScriptRoot
$shortcut.Description = 'Start the Wi-Fi connectivity monitor in the background'
$shortcut.Save()

Write-Output "Automatic startup enabled: $shortcutPath"
