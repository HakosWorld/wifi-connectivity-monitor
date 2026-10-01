[CmdletBinding()]
param()

$shortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'WiFi Connectivity Monitor.lnk'
if (Test-Path -LiteralPath $shortcutPath) {
    Remove-Item -LiteralPath $shortcutPath -Force
    Write-Output 'Automatic startup disabled.'
} else {
    Write-Output 'Automatic startup was not enabled.'
}
