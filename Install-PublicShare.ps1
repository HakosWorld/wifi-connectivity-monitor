[CmdletBinding()]
param(
    [string]$DataDirectory = (Join-Path $env:LOCALAPPDATA 'WifiConnectivityMonitor')
)

$ErrorActionPreference = 'Stop'
$cloudflaredVersion = '2026.9.3'
$expectedSha256 = 'f096265ec2fcbe9bb6e2d64268db167ced3fcbb83d894bdb9e2fcdb26f2ea7e2'
$downloadUrl = "https://github.com/cloudflare/cloudflared/releases/download/$cloudflaredVersion/cloudflared-windows-amd64.exe"
$binDirectory = Join-Path $DataDirectory 'bin'
$cloudflaredPath = Join-Path $binDirectory 'cloudflared.exe'
$temporaryPath = Join-Path $binDirectory 'cloudflared.download'

New-Item -ItemType Directory -Path $binDirectory -Force | Out-Null

if (Test-Path -LiteralPath $cloudflaredPath) {
    $existingHash = (Get-FileHash -LiteralPath $cloudflaredPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($existingHash -eq $expectedSha256) {
        Write-Output $cloudflaredPath
        exit 0
    }
}

Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
try {
    Invoke-WebRequest -Uri $downloadUrl -OutFile $temporaryPath -UseBasicParsing
    $actualHash = (Get-FileHash -LiteralPath $temporaryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedSha256) {
        throw "The cloudflared download failed checksum verification. Expected $expectedSha256 but received $actualHash."
    }
    Move-Item -LiteralPath $temporaryPath -Destination $cloudflaredPath -Force
}
finally {
    Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
}

Write-Output $cloudflaredPath
