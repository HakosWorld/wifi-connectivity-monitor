[CmdletBinding()]
param(
    [string]$DataDirectory = (Join-Path $env:LOCALAPPDATA 'WifiConnectivityMonitor'),
    [ValidateRange(0.25, 60)]
    [double]$IntervalSeconds = 0.5,
    [ValidateRange(100, 10000)]
    [int]$TimeoutMs = 400,
    [string[]]$InternetTargets = @('1.1.1.1', '8.8.8.8', '9.9.9.9'),
    [ValidateRange(0, 1000000)]
    [int]$MaxSamples = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$mutex = New-Object System.Threading.Mutex($false, 'Local\WifiConnectivityMonitor.Singleton')
$ownsMutex = $false

try {
    $ownsMutex = $mutex.WaitOne(0, $false)
    if (-not $ownsMutex) {
        Write-Output 'The Wi-Fi connectivity monitor is already running.'
        exit 0
    }

    New-Item -ItemType Directory -Path $DataDirectory -Force | Out-Null
    $minuteDirectory = Join-Path $DataDirectory 'minute-stats'
    New-Item -ItemType Directory -Path $minuteDirectory -Force | Out-Null
    $packetLossDirectory = Join-Path $DataDirectory 'packet-loss'
    New-Item -ItemType Directory -Path $packetLossDirectory -Force | Out-Null

    $statusPath = Join-Path $DataDirectory 'status.json'
    $stopRequestPath = Join-Path $DataDirectory 'stop.request.json'
    $resetRequestPath = Join-Path $DataDirectory 'reset.request.json'
    $resetCompletedPath = Join-Path $DataDirectory 'reset.completed.json'
    $eventPath = Join-Path $DataDirectory 'outage-events.csv'
    $instanceId = [guid]::NewGuid().ToString('N')
    $startedAt = [DateTimeOffset]::Now

    function Write-CsvRow {
        param(
            [Parameter(Mandatory = $true)]$InputObject,
            [Parameter(Mandatory = $true)][string]$Path
        )

        for ($attempt = 1; $attempt -le 20; $attempt++) {
            try {
                $InputObject | Export-Csv -LiteralPath $Path -NoTypeInformation -Append -Encoding UTF8
                return
            }
            catch {
                if ($attempt -eq 20) { throw }
                Start-Sleep -Milliseconds 50
            }
        }
    }

    function Write-JsonAtomic {
        param(
            [Parameter(Mandatory = $true)]$InputObject,
            [Parameter(Mandatory = $true)][string]$Path
        )

        $temporaryPath = "$Path.$instanceId.tmp"
        $json = $InputObject | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($temporaryPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        for ($attempt = 1; $attempt -le 20; $attempt++) {
            try {
                Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
                return
            }
            catch {
                if ($attempt -lt 20) { Start-Sleep -Milliseconds 25 }
            }
        }

        # A dashboard read can briefly prevent replacement on Windows. Missing one live
        # status update is safer than stopping the long-running connectivity monitor.
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }

    function Update-EventLogSchema {
        param([string]$Path)

        if (-not (Test-Path -LiteralPath $Path)) { return }
        $header = Get-Content -LiteralPath $Path -TotalCount 1
        $rows = @(Import-Csv -LiteralPath $Path)
        if ($rows.Count -eq 0) { return }
        $hasSeverityColumn = $header -match '"Severity"'
        $hasDiagnosticColumns = $header -match '"AdapterStatus"' -and
            $header -match '"WifiSignalPercent"' -and $header -match '"GatewaySuccess"'
        $needsUpdate = -not $hasSeverityColumn -or -not $hasDiagnosticColumns
        if (-not $needsUpdate) {
            $needsUpdate = $null -ne ($rows | Where-Object {
                [string]::IsNullOrWhiteSpace($_.Severity) -or
                ($_.Severity -eq 'Outage' -and $_.Classification -match '^(Potential|Gateway probe)') -or
                ($_.Severity -eq 'Potential' -and $_.Classification -match '^Potential' -and $_.FailedTargets -match '^\d+\.\d+\.\d+\.\d+$')
            } | Select-Object -First 1)
        }
        if (-not $needsUpdate) { return }

        $temporaryPath = "$Path.schema-$instanceId.tmp"
        $upgradedRows = @($rows | ForEach-Object {
            $existingSeverity = if ($null -ne $_.PSObject.Properties['Severity']) { $_.Severity } else { '' }
            $severity = if ($_.Classification -match '^Potential' -and $_.FailedTargets -match '^\d+\.\d+\.\d+\.\d+$') {
                'Noise'
            }
            elseif ($_.Classification -match '^(Potential|Gateway probe)') {
                'Potential'
            }
            elseif (-not [string]::IsNullOrWhiteSpace($existingSeverity)) {
                $existingSeverity
            }
            else { 'Outage' }
            [pscustomobject]@{
                EventTimestampLocal = $_.EventTimestampLocal
                EventTimestampUtc   = $_.EventTimestampUtc
                Event               = $_.Event
                OutageId            = $_.OutageId
                StartLocal          = $_.StartLocal
                StartUtc            = $_.StartUtc
                EndLocal            = $_.EndLocal
                EndUtc              = $_.EndUtc
                DurationSeconds     = $_.DurationSeconds
                Severity            = $severity
                Classification      = $_.Classification
                Gateway             = $_.Gateway
                FailedTargets       = $_.FailedTargets
                AdapterStatus       = if ($null -ne $_.PSObject.Properties['AdapterStatus']) { $_.AdapterStatus } else { '' }
                WifiSignalPercent   = if ($null -ne $_.PSObject.Properties['WifiSignalPercent']) { $_.WifiSignalPercent } else { '' }
                GatewaySuccess      = if ($null -ne $_.PSObject.Properties['GatewaySuccess']) { $_.GatewaySuccess } else { '' }
            }
        })
        $upgradedRows | Export-Csv -LiteralPath $temporaryPath -NoTypeInformation -Encoding UTF8
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }

    function Get-WifiContext {
        $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue)
        $wifiAdapters = @($adapters | Where-Object {
            $_.NdisPhysicalMedium.ToString() -eq '9' -or
                $_.Name -match 'Wi-?Fi|WLAN|Wireless' -or
                $_.InterfaceDescription -match 'Wi-?Fi|WLAN|Wireless|802\.11'
        })
        $adapter = $wifiAdapters | Sort-Object @{ Expression = { if ($_.Status -eq 'Up') { 0 } else { 1 } } }, ifIndex | Select-Object -First 1

        if ($null -eq $adapter) {
            return [pscustomobject]@{
                AdapterName    = 'Wi-Fi adapter not found'
                WifiName       = $null
                WifiSignalPercent = $null
                WifiRssiDbm    = $null
                AdapterStatus  = 'Disconnected'
                InterfaceIndex = $null
                Gateway        = $null
                LocalAddress   = $null
            }
        }

        $route = Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' } |
            Sort-Object RouteMetric |
            Select-Object -First 1
        $address = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike '169.254.*' } |
            Select-Object -First 1

        # Get-NetConnectionProfile.Name can be renamed by Windows (for example,
        # "Network 3"). netsh reports the actual access point SSID shown to users.
        $wifiName = $null
        $wifiSignalPercent = $null
        $wifiRssiDbm = $null
        try {
            $interfaceOutput = & "$env:SystemRoot\System32\netsh.exe" wlan show interfaces 2>$null
            $ssidLine = $interfaceOutput | Where-Object { $_ -match '^\s*SSID\s*:\s*(.+?)\s*$' } | Select-Object -First 1
            if ($ssidLine -match '^\s*SSID\s*:\s*(.+?)\s*$') {
                $wifiName = $matches[1].Trim()
            }
            $signalLine = $interfaceOutput | Where-Object { $_ -match '^\s*Signal\s*:\s*(\d+)%' } | Select-Object -First 1
            if ($signalLine -match '^\s*Signal\s*:\s*(\d+)%') { $wifiSignalPercent = [int]$matches[1] }
            $rssiLine = $interfaceOutput | Where-Object { $_ -match '^\s*Rssi\s*:\s*(-?\d+)' } | Select-Object -First 1
            if ($rssiLine -match '^\s*Rssi\s*:\s*(-?\d+)') { $wifiRssiDbm = [int]$matches[1] }
        }
        catch {
            $wifiName = $null
        }

        return [pscustomobject]@{
            AdapterName    = $adapter.Name
            WifiName       = $wifiName
            WifiSignalPercent = $wifiSignalPercent
            WifiRssiDbm    = $wifiRssiDbm
            AdapterStatus  = $adapter.Status.ToString()
            InterfaceIndex = [int]$adapter.ifIndex
            Gateway        = if ($null -ne $route) { [string]$route.NextHop } else { $null }
            LocalAddress   = if ($null -ne $address) { [string]$address.IPAddress } else { $null }
        }
    }

    function Invoke-PingBatch {
        param(
            [Parameter(Mandatory = $true)][string[]]$Targets,
            [Parameter(Mandatory = $true)][int]$Timeout
        )

        $entries = @()
        foreach ($target in @($Targets | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
            $ping = New-Object System.Net.NetworkInformation.Ping
            try {
                $task = $ping.SendPingAsync($target, $Timeout)
                $entries += [pscustomobject]@{ Target = $target; Ping = $ping; Task = $task }
            }
            catch {
                $ping.Dispose()
                $entries += [pscustomobject]@{ Target = $target; Ping = $null; Task = $null }
            }
        }

        $tasks = @($entries | Where-Object { $null -ne $_.Task } | ForEach-Object { $_.Task })
        if ($tasks.Count -gt 0) {
            try {
                [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]$tasks, $Timeout + 500)
            }
            catch {
                # Individual failures are converted to unsuccessful probe results below.
            }
        }

        $results = @{}
        foreach ($entry in $entries) {
            $success = $false
            $latency = $null
            if ($null -ne $entry.Task -and $entry.Task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
                try {
                    $reply = $entry.Task.Result
                    $success = $reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success
                    if ($success) {
                        $latency = [int64]$reply.RoundtripTime
                    }
                }
                catch {
                    $success = $false
                }
            }

            $results[$entry.Target] = [pscustomobject]@{
                Target    = $entry.Target
                Success   = $success
                LatencyMs = $latency
            }

            if ($null -ne $entry.Ping) {
                $entry.Ping.Dispose()
            }
        }

        return $results
    }

    function Invoke-TcpConfirmation {
        param(
            [string[]]$Targets = @('1.1.1.1', '8.8.8.8'),
            [int]$Port = 443,
            [int]$Timeout = 600
        )

        $entries = @()
        foreach ($target in $Targets) {
            $client = New-Object System.Net.Sockets.TcpClient
            try {
                $entries += [pscustomobject]@{ Target = $target; Client = $client; Task = $client.ConnectAsync($target, $Port) }
            }
            catch {
                $client.Dispose()
                $entries += [pscustomobject]@{ Target = $target; Client = $null; Task = $null }
            }
        }

        $tasks = @($entries | Where-Object { $null -ne $_.Task } | ForEach-Object { $_.Task })
        if ($tasks.Count -gt 0) {
            try { [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]$tasks, $Timeout) }
            catch { }
        }

        $results = @()
        foreach ($entry in $entries) {
            $connected = $null -ne $entry.Client -and $entry.Client.Connected
            $results += [pscustomobject]@{ Target = "$($entry.Target):$Port"; Success = $connected }
            if ($null -ne $entry.Client) { $entry.Client.Dispose() }
        }
        return $results
    }

    function Get-Classification {
        param(
            [bool]$GatewaySucceeded,
            [string]$AdapterStatus,
            [string]$Gateway,
            [int]$SuccessfulInternetTargets,
            [int]$TotalInternetTargets
        )

        if ($AdapterStatus -ne 'Up' -or [string]::IsNullOrWhiteSpace($Gateway)) {
            return 'Wi-Fi adapter disconnected'
        }
        if ($SuccessfulInternetTargets -eq 0 -and -not $GatewaySucceeded) {
            return 'Wi-Fi/local router'
        }
        if ($SuccessfulInternetTargets -eq 0) {
            return 'ISP/upstream internet'
        }
        if ($SuccessfulInternetTargets -lt $TotalInternetTargets) {
            return 'Potential packet loss/partial route failure'
        }
        return 'Gateway probe failure (internet reachable)'
    }

    function Write-MinuteSummary {
        param($Accumulator)

        if ($null -eq $Accumulator -or $Accumulator.Samples -eq 0) {
            return
        }

        $latencies = @($Accumulator.Latencies)
        $averageLatency = if ($latencies.Count -gt 0) {
            [math]::Round(($latencies | Measure-Object -Average).Average, 1)
        } else { $null }
        $maximumLatency = if ($latencies.Count -gt 0) {
            [int64](($latencies | Measure-Object -Maximum).Maximum)
        } else { $null }

        $dayPath = Join-Path $minuteDirectory ("minute-stats-{0}.csv" -f $Accumulator.MinuteStart.ToString('yyyy-MM-dd'))
        Write-CsvRow -Path $dayPath -InputObject ([pscustomobject]@{
            MinuteStartLocal = $Accumulator.MinuteStart.ToString('o')
            MinuteStartUtc   = $Accumulator.MinuteStart.UtcDateTime.ToString('o')
            Samples          = $Accumulator.Samples
            FailureSamples   = $Accumulator.Failures
            FailurePercent   = [math]::Round(($Accumulator.Failures * 100.0) / $Accumulator.Samples, 2)
            AverageLatencyMs = $averageLatency
            MaximumLatencyMs = $maximumLatency
        })
    }

    function Write-PacketLossSummary {
        param($Accumulator)

        if ($null -eq $Accumulator -or $Accumulator.Samples -eq 0) {
            return
        }

        $targetStats = @($Accumulator.TargetAttempts.Keys | Sort-Object | ForEach-Object {
            $target = [string]$_
            $attempts = [int64]$Accumulator.TargetAttempts[$target]
            $failures = [int64]$Accumulator.TargetFailures[$target]
            [ordered]@{
                Target      = $target
                Attempts    = $attempts
                Failures    = $failures
                LossPercent = if ($attempts -gt 0) { [math]::Round(($failures * 100.0) / $attempts, 3) } else { $null }
            }
        })

        $dayPath = Join-Path $packetLossDirectory ("packet-loss-{0}.csv" -f $Accumulator.MinuteStart.ToString('yyyy-MM-dd'))
        Write-CsvRow -Path $dayPath -InputObject ([pscustomobject]@{
            MinuteStartLocal             = $Accumulator.MinuteStart.ToString('o')
            MinuteStartUtc               = $Accumulator.MinuteStart.UtcDateTime.ToString('o')
            Samples                      = $Accumulator.Samples
            InternetProbeAttempts        = $Accumulator.InternetAttempts
            InternetProbeFailures        = $Accumulator.InternetFailures
            InternetProbeLossPercent     = if ($Accumulator.InternetAttempts -gt 0) { [math]::Round(($Accumulator.InternetFailures * 100.0) / $Accumulator.InternetAttempts, 3) } else { $null }
            GatewayProbeAttempts         = $Accumulator.GatewayAttempts
            GatewayProbeFailures         = $Accumulator.GatewayFailures
            GatewayProbeLossPercent      = if ($Accumulator.GatewayAttempts -gt 0) { [math]::Round(($Accumulator.GatewayFailures * 100.0) / $Accumulator.GatewayAttempts, 3) } else { $null }
            CompleteInternetFailureChecks = $Accumulator.CompleteInternetFailures
            TargetStatsJson              = $targetStats | ConvertTo-Json -Depth 4 -Compress
        })
    }

    function New-MinuteAccumulator {
        param([DateTimeOffset]$Timestamp)

        $minute = [DateTimeOffset]::new(
            $Timestamp.Year, $Timestamp.Month, $Timestamp.Day,
            $Timestamp.Hour, $Timestamp.Minute, 0, $Timestamp.Offset
        )
        return [pscustomobject]@{
            MinuteStart             = $minute
            Samples                 = 0
            Failures                = 0
            Latencies               = New-Object System.Collections.Generic.List[long]
            InternetAttempts        = 0
            InternetFailures        = 0
            GatewayAttempts         = 0
            GatewayFailures         = 0
            CompleteInternetFailures = 0
            TargetAttempts          = @{}
            TargetFailures          = @{}
        }
    }

    # Retain detailed minute aggregates for 90 days. Outage events are retained indefinitely.
    Get-ChildItem -LiteralPath $minuteDirectory -Filter 'minute-stats-*.csv' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-100) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $packetLossDirectory -Filter 'packet-loss-*.csv' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-100) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    if (Test-Path -LiteralPath $stopRequestPath) {
        Remove-Item -LiteralPath $stopRequestPath -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $resetRequestPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $resetCompletedPath -Force -ErrorAction SilentlyContinue
    Update-EventLogSchema -Path $eventPath

    $context = Get-WifiContext
    $lastContextRefresh = [DateTimeOffset]::MinValue
    $currentOutage = $null
    $sampleCount = 0
    $minuteAccumulator = New-MinuteAccumulator -Timestamp ([DateTimeOffset]::Now)
    $keepRunning = $true

    while ($keepRunning) {
        $iterationWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $now = [DateTimeOffset]::Now

        if (Test-Path -LiteralPath $resetRequestPath) {
            try {
                $resetRequest = Get-Content -Raw -LiteralPath $resetRequestPath | ConvertFrom-Json
                if (-not [string]::IsNullOrWhiteSpace([string]$resetRequest.RequestId)) {
                    # Reset from inside the writer process so an event that was active
                    # before the reset cannot later append an unmatched recovery row.
                    $currentOutage = $null
                    $sampleCount = 0
                    $startedAt = $now
                    $minuteAccumulator = New-MinuteAccumulator -Timestamp $now
                    if (Test-Path -LiteralPath $eventPath) {
                        Remove-Item -LiteralPath $eventPath -Force -ErrorAction Stop
                    }
                    Get-ChildItem -LiteralPath $minuteDirectory -Filter 'minute-stats-*.csv' -File -ErrorAction SilentlyContinue |
                        Remove-Item -Force -ErrorAction Stop
                    Get-ChildItem -LiteralPath $packetLossDirectory -Filter 'packet-loss-*.csv' -File -ErrorAction SilentlyContinue |
                        Remove-Item -Force -ErrorAction Stop
                    Write-JsonAtomic -Path $resetCompletedPath -InputObject ([pscustomobject]@{
                        RequestId = [string]$resetRequest.RequestId
                        ResetAtLocal = $now.ToString('o')
                        ResetAtUtc = $now.UtcDateTime.ToString('o')
                    })
                    Remove-Item -LiteralPath $resetRequestPath -Force -ErrorAction SilentlyContinue
                }
            }
            catch {
                # An incomplete request is retried on the next half-second cycle.
            }
        }

        if (($now - $lastContextRefresh).TotalSeconds -ge 30 -or $null -eq $context.Gateway) {
            $context = Get-WifiContext
            $lastContextRefresh = $now
        }

        $targets = @($InternetTargets)
        if (-not [string]::IsNullOrWhiteSpace($context.Gateway)) {
            $targets += $context.Gateway
        }
        $probeResults = Invoke-PingBatch -Targets $targets -Timeout $TimeoutMs

        $internetResults = @($InternetTargets | ForEach-Object { $probeResults[$_] })
        $successfulInternetResults = @($internetResults | Where-Object { $null -ne $_ -and $_.Success })
        $internetOnline = $successfulInternetResults.Count -gt 0
        $gatewaySucceeded = -not [string]::IsNullOrWhiteSpace($context.Gateway) -and
            $null -ne $probeResults[$context.Gateway] -and
            $probeResults[$context.Gateway].Success
        $failedInternetCount = $InternetTargets.Count - $successfulInternetResults.Count
        $tcpConfirmationResults = @()
        $tcpConfirmationSucceeded = $false
        if ($failedInternetCount -eq $InternetTargets.Count -and $gatewaySucceeded) {
            # ICMP can be rate-limited. Confirm a suspected upstream outage using
            # independent TCP handshakes before calling the Internet unreachable.
            $tcpConfirmationResults = @(Invoke-TcpConfirmation -Timeout ([math]::Max(600, $TimeoutMs)))
            $tcpConfirmationSucceeded = $null -ne ($tcpConfirmationResults | Where-Object Success | Select-Object -First 1)
            if ($tcpConfirmationSucceeded) { $internetOnline = $true }
        }
        $issueDetected = $failedInternetCount -gt 0 -or (-not [string]::IsNullOrWhiteSpace($context.Gateway) -and -not $gatewaySucceeded)
        $issueSeverity = if (-not $internetOnline) {
            'Outage'
        }
        elseif ($failedInternetCount -eq 1 -and $gatewaySucceeded) {
            # One public ICMP endpoint can rate-limit or deprioritize ping while the
            # router and other independent Internet probes remain fully reachable.
            'Noise'
        }
        elseif ($issueDetected) { 'Potential' }
        else { $null }
        $bestLatency = if ($successfulInternetResults.Count -gt 0) {
            [int64](($successfulInternetResults | Measure-Object -Property LatencyMs -Minimum).Minimum)
        } else { $null }

        $sampleMinute = [DateTimeOffset]::new($now.Year, $now.Month, $now.Day, $now.Hour, $now.Minute, 0, $now.Offset)
        if ($sampleMinute -ne $minuteAccumulator.MinuteStart) {
            Write-MinuteSummary -Accumulator $minuteAccumulator
            Write-PacketLossSummary -Accumulator $minuteAccumulator
            $minuteAccumulator = New-MinuteAccumulator -Timestamp $now
        }
        $minuteAccumulator.Samples++
        if ($issueDetected) {
            $minuteAccumulator.Failures++
        }
        if ($null -ne $bestLatency) {
            $minuteAccumulator.Latencies.Add($bestLatency)
        }
        $minuteAccumulator.InternetAttempts += $InternetTargets.Count
        $minuteAccumulator.InternetFailures += $failedInternetCount
        if ($failedInternetCount -eq $InternetTargets.Count) {
            $minuteAccumulator.CompleteInternetFailures++
        }
        for ($targetIndex = 0; $targetIndex -lt $InternetTargets.Count; $targetIndex++) {
            $target = [string]$InternetTargets[$targetIndex]
            if (-not $minuteAccumulator.TargetAttempts.ContainsKey($target)) {
                $minuteAccumulator.TargetAttempts[$target] = 0
                $minuteAccumulator.TargetFailures[$target] = 0
            }
            $minuteAccumulator.TargetAttempts[$target]++
            $targetResult = $internetResults[$targetIndex]
            if ($null -eq $targetResult -or -not $targetResult.Success) {
                $minuteAccumulator.TargetFailures[$target]++
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($context.Gateway)) {
            $minuteAccumulator.GatewayAttempts++
            if (-not $gatewaySucceeded) { $minuteAccumulator.GatewayFailures++ }
        }

        if ($issueDetected -and $null -eq $currentOutage) {
            # Refresh adapter and route state when an issue begins to improve the likely-source diagnosis.
            $context = Get-WifiContext
            $lastContextRefresh = $now

            $classification = if ($tcpConfirmationSucceeded) {
                'ICMP probes missed; TCP Internet confirmation succeeded'
            }
            elseif ($issueSeverity -eq 'Outage' -and $gatewaySucceeded) {
                'ISP/upstream internet (ICMP and TCP failed)'
            }
            elseif ($issueSeverity -eq 'Noise') {
                'Single diagnostic target missed; Internet and router stayed reachable'
            }
            else {
                Get-Classification -GatewaySucceeded $gatewaySucceeded -AdapterStatus $context.AdapterStatus -Gateway $context.Gateway -SuccessfulInternetTargets $successfulInternetResults.Count -TotalInternetTargets $InternetTargets.Count
            }
            $failedTargetList = @($internetResults | Where-Object { $null -eq $_ -or -not $_.Success } | ForEach-Object { $_.Target })
            if (-not [string]::IsNullOrWhiteSpace($context.Gateway) -and -not $gatewaySucceeded) { $failedTargetList += "Gateway:$($context.Gateway)" }
            $failedTargets = $failedTargetList -join '; '
            $currentOutage = [pscustomobject]@{
                Id             = [guid]::NewGuid().ToString('N')
                Start          = $now
                Severity       = $issueSeverity
                Classification = $classification
                Gateway       = $context.Gateway
                FailedTargets = $failedTargets
                AdapterStatus = $context.AdapterStatus
                WifiSignalPercent = $context.WifiSignalPercent
                GatewaySuccess = $gatewaySucceeded
            }

            Write-CsvRow -Path $eventPath -InputObject ([pscustomobject]@{
                EventTimestampLocal = $now.ToString('o')
                EventTimestampUtc   = $now.UtcDateTime.ToString('o')
                Event               = 'Start'
                OutageId            = $currentOutage.Id
                StartLocal          = $now.ToString('o')
                StartUtc            = $now.UtcDateTime.ToString('o')
                EndLocal            = ''
                EndUtc              = ''
                DurationSeconds     = ''
                Severity            = $issueSeverity
                Classification      = $classification
                Gateway             = $context.Gateway
                FailedTargets       = $failedTargets
                AdapterStatus       = $context.AdapterStatus
                WifiSignalPercent   = $context.WifiSignalPercent
                GatewaySuccess      = $gatewaySucceeded
            })
        }
        elseif ($issueDetected -and $null -ne $currentOutage) {
            # Preserve the worst state if a single-target miss develops into a
            # multi-target problem or complete loss of Internet reachability.
            $severityRanks = @{ Noise = 1; Potential = 2; Outage = 3 }
            if ($severityRanks[$issueSeverity] -gt $severityRanks[$currentOutage.Severity]) {
                $currentOutage.Severity = $issueSeverity
                $currentOutage.Classification = if ($tcpConfirmationSucceeded) {
                    'ICMP probes missed; TCP Internet confirmation succeeded'
                }
                elseif ($issueSeverity -eq 'Outage' -and $gatewaySucceeded) {
                    'ISP/upstream internet (ICMP and TCP failed)'
                }
                elseif ($issueSeverity -eq 'Noise') {
                    'Single diagnostic target missed; Internet and router stayed reachable'
                }
                else {
                    Get-Classification -GatewaySucceeded $gatewaySucceeded -AdapterStatus $context.AdapterStatus -Gateway $context.Gateway -SuccessfulInternetTargets $successfulInternetResults.Count -TotalInternetTargets $InternetTargets.Count
                }
            }
            $failedTargetList = @($internetResults | Where-Object { $null -eq $_ -or -not $_.Success } | ForEach-Object { $_.Target })
            if (-not [string]::IsNullOrWhiteSpace($context.Gateway) -and -not $gatewaySucceeded) { $failedTargetList += "Gateway:$($context.Gateway)" }
            $existingFailedTargets = @($currentOutage.FailedTargets -split ';\s*' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $currentOutage.FailedTargets = @($existingFailedTargets + $failedTargetList | Select-Object -Unique) -join '; '
            if ($context.AdapterStatus -ne 'Up') { $currentOutage.AdapterStatus = $context.AdapterStatus }
            if ($null -ne $context.WifiSignalPercent) { $currentOutage.WifiSignalPercent = $context.WifiSignalPercent }
            if (-not $gatewaySucceeded) { $currentOutage.GatewaySuccess = $false }
        }
        elseif (-not $issueDetected -and $null -ne $currentOutage) {
            $durationSeconds = [math]::Round(($now - $currentOutage.Start).TotalSeconds, 3)
            Write-CsvRow -Path $eventPath -InputObject ([pscustomobject]@{
                EventTimestampLocal = $now.ToString('o')
                EventTimestampUtc   = $now.UtcDateTime.ToString('o')
                Event               = 'End'
                OutageId            = $currentOutage.Id
                StartLocal          = $currentOutage.Start.ToString('o')
                StartUtc            = $currentOutage.Start.UtcDateTime.ToString('o')
                EndLocal            = $now.ToString('o')
                EndUtc              = $now.UtcDateTime.ToString('o')
                DurationSeconds     = $durationSeconds
                Severity            = $currentOutage.Severity
                Classification      = $currentOutage.Classification
                Gateway             = $currentOutage.Gateway
                FailedTargets       = $currentOutage.FailedTargets
                AdapterStatus       = $currentOutage.AdapterStatus
                WifiSignalPercent   = $currentOutage.WifiSignalPercent
                GatewaySuccess      = $currentOutage.GatewaySuccess
            })
            $currentOutage = $null
        }

        $targetStatuses = @($InternetTargets | ForEach-Object {
            $result = $probeResults[$_]
            [pscustomobject]@{
                Target    = $_
                Success   = $null -ne $result -and $result.Success
                LatencyMs = if ($null -ne $result) { $result.LatencyMs } else { $null }
            }
        })

        $status = [pscustomobject]@{
            Running             = $true
            ProcessId           = $PID
            InstanceId          = $instanceId
            MonitorStartedLocal = $startedAt.ToString('o')
            MonitorStartedUtc   = $startedAt.UtcDateTime.ToString('o')
            LastCheckedLocal    = $now.ToString('o')
            LastCheckedUtc      = $now.UtcDateTime.ToString('o')
            Online              = $internetOnline
            Healthy             = -not $issueDetected
            IssueDetected       = $issueDetected
            IssueSeverity       = if ($null -ne $currentOutage) { $currentOutage.Severity } else { $issueSeverity }
            OutageStartLocal    = if ($null -ne $currentOutage) { $currentOutage.Start.ToString('o') } else { $null }
            OutageType          = if ($null -ne $currentOutage) { $currentOutage.Classification } else { $null }
            AdapterName         = $context.AdapterName
            WifiName            = $context.WifiName
            WifiSignalPercent   = $context.WifiSignalPercent
            WifiRssiDbm         = $context.WifiRssiDbm
            AdapterStatus       = $context.AdapterStatus
            LocalAddress        = $context.LocalAddress
            Gateway             = $context.Gateway
            GatewaySuccess      = $gatewaySucceeded
            TcpConfirmationSucceeded = if ($tcpConfirmationResults.Count -gt 0) { $tcpConfirmationSucceeded } else { $null }
            TcpConfirmationTargets = @($tcpConfirmationResults)
            FailedTargetCount   = $failedInternetCount + $(if (-not [string]::IsNullOrWhiteSpace($context.Gateway) -and -not $gatewaySucceeded) { 1 } else { 0 })
            IssueTargets        = if ($null -ne $currentOutage) { $currentOutage.FailedTargets } else { $null }
            BestInternetLatencyMs = $bestLatency
            Targets             = $targetStatuses
            IntervalSeconds     = $IntervalSeconds
            TimeoutMs           = $TimeoutMs
        }
        Write-JsonAtomic -InputObject $status -Path $statusPath

        $sampleCount++
        if ($MaxSamples -gt 0 -and $sampleCount -ge $MaxSamples) {
            $keepRunning = $false
        }

        if (Test-Path -LiteralPath $stopRequestPath) {
            try {
                $request = Get-Content -Raw -LiteralPath $stopRequestPath | ConvertFrom-Json
                if ($request.InstanceId -eq $instanceId) {
                    $keepRunning = $false
                }
            }
            catch {
                # Ignore incomplete or stale stop requests.
            }
        }

        $iterationWatch.Stop()
        $remainingMilliseconds = [math]::Floor(($IntervalSeconds * 1000) - $iterationWatch.Elapsed.TotalMilliseconds)
        if ($keepRunning -and $remainingMilliseconds -gt 0) {
            Start-Sleep -Milliseconds $remainingMilliseconds
        }
    }

    Write-MinuteSummary -Accumulator $minuteAccumulator
    Write-PacketLossSummary -Accumulator $minuteAccumulator
}
finally {
    try {
        if (Get-Variable -Name statusPath -ErrorAction SilentlyContinue) {
            $stoppedAt = [DateTimeOffset]::Now
            $finalStatus = if (Test-Path -LiteralPath $statusPath) {
                Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json
            } else {
                [pscustomobject]@{}
            }
            $finalStatus.Running = $false
            $finalStatus | Add-Member -NotePropertyName StoppedLocal -NotePropertyValue $stoppedAt.ToString('o') -Force
            Write-JsonAtomic -InputObject $finalStatus -Path $statusPath
        }
        if (Get-Variable -Name stopRequestPath -ErrorAction SilentlyContinue) {
            Remove-Item -LiteralPath $stopRequestPath -Force -ErrorAction SilentlyContinue
        }
        if (Get-Variable -Name resetRequestPath -ErrorAction SilentlyContinue) {
            Remove-Item -LiteralPath $resetRequestPath -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        # Best-effort cleanup must not obscure the original monitor failure.
    }

    if ($ownsMutex) {
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}
