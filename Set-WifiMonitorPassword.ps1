[CmdletBinding()]
param(
    [string]$DataDirectory = (Join-Path $env:LOCALAPPDATA 'WifiConnectivityMonitor'),
    [string]$Password = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Password)) {
    $securePassword = Read-Host 'Choose a dashboard reset password' -AsSecureString
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    try {
        $Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

if ([string]::IsNullOrWhiteSpace($Password)) {
    throw 'Password cannot be empty.'
}

New-Item -ItemType Directory -Path $DataDirectory -Force | Out-Null
$passwordPath = Join-Path $DataDirectory 'reset-password.txt'
[System.IO.File]::WriteAllText($passwordPath, $Password, (New-Object System.Text.UTF8Encoding($false)))

Write-Output "Dashboard reset password saved to $passwordPath"
