[CmdletBinding()]
param(
    [string]$DataDirectory = (Join-Path $env:LOCALAPPDATA 'WifiConnectivityMonitor'),
    [ValidateRange(1024, 65525)]
    [int]$PreferredPort = 8765,
    [string]$ResetPasswordPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$mutex = New-Object System.Threading.Mutex($false, 'Local\WifiConnectivityMonitor.Dashboard.Singleton')
$ownsMutex = $false
$listener = $null
$serverInfoPath = Join-Path $DataDirectory 'dashboard-server.json'
$serverInstanceId = [guid]::NewGuid().ToString('N')

function Write-HttpResponse {
    param(
        [Parameter(Mandatory = $true)][System.Net.Sockets.TcpClient]$Client,
        [Parameter(Mandatory = $true)][int]$StatusCode,
        [Parameter(Mandatory = $true)][string]$ContentType,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Body
    )

    $reason = switch ($StatusCode) {
        200 { 'OK' }
        204 { 'No Content' }
        400 { 'Bad Request' }
        401 { 'Unauthorized' }
        404 { 'Not Found' }
        405 { 'Method Not Allowed' }
        429 { 'Too Many Requests' }
        503 { 'Service Unavailable' }
        default { 'Error' }
    }
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $header = "HTTP/1.1 $StatusCode $reason`r`nContent-Type: $ContentType`r`nContent-Length: $($bodyBytes.Length)`r`nCache-Control: no-store, no-cache, must-revalidate`r`nX-Content-Type-Options: nosniff`r`nX-Frame-Options: DENY`r`nReferrer-Policy: no-referrer`r`nConnection: close`r`n`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
    $stream = $Client.GetStream()
    $stream.Write($headerBytes, 0, $headerBytes.Length)
    if ($bodyBytes.Length -gt 0) { $stream.Write($bodyBytes, 0, $bodyBytes.Length) }
    $stream.Flush()
}

function Convert-ToNullableDouble {
    param($Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    return [double]$Value
}

try {
    $ownsMutex = $mutex.WaitOne(0, $false)
    if (-not $ownsMutex) { exit 0 }

    New-Item -ItemType Directory -Path $DataDirectory -Force | Out-Null
    if ([string]::IsNullOrWhiteSpace($ResetPasswordPath)) {
        $ResetPasswordPath = Join-Path $DataDirectory 'reset-password.txt'
    }
    if (-not (Test-Path -LiteralPath $ResetPasswordPath)) {
        throw 'Dashboard reset password is not configured. Run Set Dashboard Password.cmd first.'
    }
    $ResetPassword = [System.IO.File]::ReadAllText($ResetPasswordPath).Trim()
    if ([string]::IsNullOrWhiteSpace($ResetPassword)) {
        throw 'Dashboard reset password cannot be empty.'
    }

    $statusPath = Join-Path $DataDirectory 'status.json'
    $shareInfoPath = Join-Path $DataDirectory 'public-share.json'
    $eventPath = Join-Path $DataDirectory 'outage-events.csv'
    $resetRequestPath = Join-Path $DataDirectory 'reset.request.json'
    $resetCompletedPath = Join-Path $DataDirectory 'reset.completed.json'
    $minuteDirectory = Join-Path $DataDirectory 'minute-stats'
    $packetLossDirectory = Join-Path $DataDirectory 'packet-loss'
    $dashboardPath = Join-Path $PSScriptRoot 'dashboard.html'

    if (-not (Test-Path -LiteralPath $dashboardPath)) { throw "Dashboard file not found: $dashboardPath" }
    $dashboardHtml = [System.IO.File]::ReadAllText($dashboardPath)

    $port = $null
    foreach ($candidatePort in $PreferredPort..([math]::Min($PreferredPort + 10, 65535))) {
        $candidateListener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $candidatePort)
        try {
            $candidateListener.Start()
            $listener = $candidateListener
            $port = $candidatePort
            break
        }
        catch { $candidateListener.Stop() }
    }
    if ($null -eq $listener) { throw "No free dashboard port was available between $PreferredPort and $($PreferredPort + 10)." }

    $lanUrl = $null
    if (Test-Path -LiteralPath $statusPath) {
        try {
            $startupStatus = Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json
            $lanAddress = [string]$startupStatus.LocalAddress
            $parsedAddress = $null
            if ([System.Net.IPAddress]::TryParse($lanAddress, [ref]$parsedAddress) -and -not [System.Net.IPAddress]::IsLoopback($parsedAddress)) {
                $lanUrl = "http://${lanAddress}:$port/"
            }
        }
        catch { $lanUrl = $null }
    }

    $serverInfo = [pscustomobject]@{
        Running    = $true
        ProcessId  = $PID
        InstanceId = $serverInstanceId
        Port        = $port
        Url         = "http://127.0.0.1:$port/"
        LanUrl      = $lanUrl
        StartedAt   = [DateTimeOffset]::Now.ToString('o')
    }
    $serverInfo | ConvertTo-Json | Set-Content -LiteralPath $serverInfoPath -Encoding UTF8

    $cachedMinutePoints = @()
    $cachedPacketLossPoints = @()
    $cachedCompletedOutages = @()
    $cachedBaseSummaries = @{}
    $lastEventStamp = -1L
    $nextStatsRefresh = [DateTimeOffset]::MinValue
    $failedResetAttempts = @{}

    function Invoke-HistoryReset {
        param([string]$Password)

        if ($Password -cne $ResetPassword) {
            return [pscustomobject]@{ StatusCode = 401; Body = '{"error":"Incorrect password."}' }
        }

        $status = $null
        if (Test-Path -LiteralPath $statusPath) {
            try { $status = Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json } catch { $status = $null }
        }
        if ($null -eq $status -or -not $status.Running -or $null -eq (Get-Process -Id $status.ProcessId -ErrorAction SilentlyContinue)) {
            return [pscustomobject]@{ StatusCode = 503; Body = '{"error":"The monitor must be running to reset safely."}' }
        }

        $requestId = [guid]::NewGuid().ToString('N')
        Remove-Item -LiteralPath $resetCompletedPath -Force -ErrorAction SilentlyContinue
        $requestBody = [pscustomobject]@{ RequestId = $requestId; RequestedAtUtc = [DateTimeOffset]::UtcNow.ToString('o') } | ConvertTo-Json
        $temporaryRequestPath = "$resetRequestPath.$requestId.tmp"
        [System.IO.File]::WriteAllText($temporaryRequestPath, $requestBody, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporaryRequestPath -Destination $resetRequestPath -Force

        $deadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
        do {
            Start-Sleep -Milliseconds 50
            if (Test-Path -LiteralPath $resetCompletedPath) {
                try {
                    $completed = Get-Content -Raw -LiteralPath $resetCompletedPath | ConvertFrom-Json
                    if ($completed.RequestId -eq $requestId) {
                        Remove-Item -LiteralPath $resetCompletedPath -Force -ErrorAction SilentlyContinue
                        $script:cachedMinutePoints = @()
                        $script:cachedPacketLossPoints = @()
                        $script:cachedCompletedOutages = @()
                        $script:cachedBaseSummaries = @{}
                        $script:lastEventStamp = -1L
                        $script:nextStatsRefresh = [DateTimeOffset]::MinValue
                        Refresh-DashboardCache -Force $true
                        return [pscustomobject]@{ StatusCode = 200; Body = '{"ok":true,"message":"History reset. Monitoring continues from now."}' }
                    }
                }
                catch { }
            }
        } while ([DateTimeOffset]::UtcNow -lt $deadline)

        return [pscustomobject]@{ StatusCode = 503; Body = '{"error":"The monitor did not confirm the reset. No reset was reported."}' }
    }

    function Refresh-DashboardCache {
        param([bool]$Force)

        $now = [DateTimeOffset]::UtcNow
        $eventStamp = if (Test-Path -LiteralPath $eventPath) { (Get-Item -LiteralPath $eventPath).LastWriteTimeUtc.Ticks } else { 0L }
        $eventsChanged = $eventStamp -ne $script:lastEventStamp
        $statsDue = $now -ge $script:nextStatsRefresh
        if (-not $Force -and -not $eventsChanged -and -not $statsDue) { return }

        if ($eventsChanged -or $Force) {
            try {
                $events = if (Test-Path -LiteralPath $eventPath) { @(Import-Csv -LiteralPath $eventPath) } else { @() }
                $script:cachedCompletedOutages = @($events | Where-Object { $_.Event -eq 'End' } | ForEach-Object {
                    $severity = if ($null -ne $_.PSObject.Properties['Severity'] -and -not [string]::IsNullOrWhiteSpace($_.Severity)) { $_.Severity } else { 'Outage' }
                    if ($severity -eq 'Potential' -and $_.Classification -match '^Potential' -and $_.FailedTargets -match '^\d+\.\d+\.\d+\.\d+$') {
                        $severity = 'Noise'
                    }
                    [pscustomobject]@{
                        Id              = $_.OutageId
                        StartUtc        = $_.StartUtc
                        EndUtc          = $_.EndUtc
                        DurationSeconds = [double]$_.DurationSeconds
                        Severity        = $severity
                        Classification  = $_.Classification
                        Gateway         = $_.Gateway
                        FailedTargets   = $_.FailedTargets
                        AdapterStatus   = if ($null -ne $_.PSObject.Properties['AdapterStatus']) { $_.AdapterStatus } else { '' }
                        WifiSignalPercent = if ($null -ne $_.PSObject.Properties['WifiSignalPercent']) { $_.WifiSignalPercent } else { '' }
                        GatewaySuccess  = if ($null -ne $_.PSObject.Properties['GatewaySuccess']) { $_.GatewaySuccess } else { '' }
                        Active          = $false
                    }
                } | Sort-Object { [DateTimeOffset]::Parse($_.StartUtc) } -Descending)
                $script:lastEventStamp = $eventStamp
            }
            catch { }
        }

        if ($statsDue -or $Force) {
            try {
                $cutoff = (Get-Date).AddDays(-31)
                $points = @()
                if (Test-Path -LiteralPath $minuteDirectory) {
                    $files = @(Get-ChildItem -LiteralPath $minuteDirectory -Filter 'minute-stats-*.csv' -File | Where-Object { $_.LastWriteTime -ge $cutoff })
                    foreach ($file in $files) {
                        foreach ($row in @(Import-Csv -LiteralPath $file.FullName)) {
                            $points += [pscustomobject]@{
                                Time       = [DateTimeOffset]::Parse($row.MinuteStartUtc)
                                TimeUtc    = $row.MinuteStartUtc
                                Samples    = [double]$row.Samples
                                Failures   = [double]$row.FailureSamples
                                FailurePct = [double]$row.FailurePercent
                                AvgLatency = Convert-ToNullableDouble $row.AverageLatencyMs
                                MaxLatency = Convert-ToNullableDouble $row.MaximumLatencyMs
                            }
                        }
                    }
                }
                $script:cachedMinutePoints = @($points | Sort-Object Time)

                $packetLossPoints = @()
                if (Test-Path -LiteralPath $packetLossDirectory) {
                    $files = @(Get-ChildItem -LiteralPath $packetLossDirectory -Filter 'packet-loss-*.csv' -File | Where-Object { $_.LastWriteTime -ge $cutoff })
                    foreach ($file in $files) {
                        foreach ($row in @(Import-Csv -LiteralPath $file.FullName)) {
                            $packetLossPoints += [pscustomobject]@{
                                Time                     = [DateTimeOffset]::Parse($row.MinuteStartUtc)
                                TimeUtc                  = $row.MinuteStartUtc
                                InternetAttempts         = [int64]$row.InternetProbeAttempts
                                InternetFailures         = [int64]$row.InternetProbeFailures
                                InternetLossPercent      = Convert-ToNullableDouble $row.InternetProbeLossPercent
                                GatewayAttempts          = [int64]$row.GatewayProbeAttempts
                                GatewayFailures          = [int64]$row.GatewayProbeFailures
                                GatewayLossPercent       = Convert-ToNullableDouble $row.GatewayProbeLossPercent
                                CompleteInternetFailures = [int64]$row.CompleteInternetFailureChecks
                                TargetStatsJson          = [string]$row.TargetStatsJson
                            }
                        }
                    }
                }
                $script:cachedPacketLossPoints = @($packetLossPoints | Sort-Object Time)
                $script:nextStatsRefresh = $now.AddSeconds(30)
            }
            catch { $script:nextStatsRefresh = $now.AddSeconds(5) }
        }

        $summaries = @{}
        foreach ($period in @(
            [pscustomobject]@{ Key = '15m'; Since = $now.AddMinutes(-15) },
            [pscustomobject]@{ Key = '24h'; Since = $now.AddHours(-24) },
            [pscustomobject]@{ Key = '7d'; Since = $now.AddDays(-7) },
            [pscustomobject]@{ Key = '30d'; Since = $now.AddDays(-30) }
        )) {
            $samples = 0.0
            $failures = 0.0
            foreach ($point in @($script:cachedMinutePoints | Where-Object { $_.Time -ge $period.Since })) {
                $samples += $point.Samples
                $failures += $point.Failures
            }
            $internetAttempts = 0L
            $internetFailures = 0L
            $gatewayAttempts = 0L
            $gatewayFailures = 0L
            $completeInternetFailures = 0L
            $targetTotals = @{}
            foreach ($point in @($script:cachedPacketLossPoints | Where-Object { $_.Time -ge $period.Since })) {
                $internetAttempts += $point.InternetAttempts
                $internetFailures += $point.InternetFailures
                $gatewayAttempts += $point.GatewayAttempts
                $gatewayFailures += $point.GatewayFailures
                $completeInternetFailures += $point.CompleteInternetFailures
                $pointTargetStats = @()
                if (-not [string]::IsNullOrWhiteSpace($point.TargetStatsJson)) {
                    try { $pointTargetStats = @($point.TargetStatsJson | ConvertFrom-Json | ForEach-Object { $_ }) }
                    catch { $pointTargetStats = @() }
                }
                foreach ($targetStat in $pointTargetStats) {
                    if (-not $targetTotals.ContainsKey($targetStat.Target)) {
                        $targetTotals[$targetStat.Target] = [pscustomobject]@{ Attempts = 0L; Failures = 0L }
                    }
                    $targetTotals[$targetStat.Target].Attempts += $targetStat.Attempts
                    $targetTotals[$targetStat.Target].Failures += $targetStat.Failures
                }
            }
            $targetLoss = @($targetTotals.Keys | Sort-Object | ForEach-Object {
                $target = [string]$_
                $total = $targetTotals[$target]
                [pscustomobject]@{
                    Target      = $target
                    Attempts    = $total.Attempts
                    Failures    = $total.Failures
                    LossPercent = if ($total.Attempts -gt 0) { [math]::Round(($total.Failures * 100.0) / $total.Attempts, 3) } else { $null }
                }
            })
            $downtime = 0.0
            $affectedTime = 0.0
            $eventCount = 0
            $outageCount = 0
            $probableUpstreamCount = 0
            $localPathCount = 0
            $deviceEventCount = 0
            $potentialCount = 0
            $noiseCount = 0
            foreach ($outage in $script:cachedCompletedOutages) {
                $start = [DateTimeOffset]::Parse($outage.StartUtc)
                $end = [DateTimeOffset]::Parse($outage.EndUtc)
                if ($end -gt $period.Since) {
                    $overlapStart = if ($start -gt $period.Since) { $start } else { $period.Since }
                    $overlapSeconds = [math]::Max(0.0, ($end - $overlapStart).TotalSeconds)
                    if ($outage.Severity -eq 'Outage') {
                        $eventCount++
                        $affectedTime += $overlapSeconds
                        if ($outage.Classification -eq 'ISP/upstream internet (ICMP and TCP failed)') {
                            $outageCount++
                            $downtime += $overlapSeconds
                        }
                        elseif ($outage.Classification -eq 'ISP/upstream internet') { $probableUpstreamCount++ }
                        elseif ($outage.Classification -eq 'Wi-Fi adapter disconnected') { $deviceEventCount++ }
                        else { $localPathCount++ }
                    }
                    elseif ($outage.Severity -eq 'Noise') { $noiseCount++ }
                    else {
                        $eventCount++
                        $affectedTime += $overlapSeconds
                        $potentialCount++
                    }
                }
            }
            $observedSeconds = $samples * 0.5
            $summaries[$period.Key] = [pscustomobject]@{
                Samples         = [int64]$samples
                FailedChecks    = [int64]$failures
                Availability    = if ($observedSeconds -gt 0) { [math]::Round((1 - ([math]::Min($downtime, $observedSeconds) / $observedSeconds)) * 100, 4) } else { $null }
                EventCount      = $eventCount
                OutageCount     = $outageCount
                ProbableUpstreamCount = $probableUpstreamCount
                LocalPathCount  = $localPathCount
                DeviceEventCount = $deviceEventCount
                PotentialCount  = $potentialCount
                NoiseCount      = $noiseCount
                DowntimeSeconds = [math]::Round($downtime, 3)
                AffectedSeconds = [math]::Round($affectedTime, 3)
                InternetProbeAttempts = $internetAttempts
                InternetProbeFailures = $internetFailures
                InternetProbeLossPercent = if ($internetAttempts -gt 0) { [math]::Round(($internetFailures * 100.0) / $internetAttempts, 3) } else { $null }
                GatewayProbeAttempts = $gatewayAttempts
                GatewayProbeFailures = $gatewayFailures
                GatewayProbeLossPercent = if ($gatewayAttempts -gt 0) { [math]::Round(($gatewayFailures * 100.0) / $gatewayAttempts, 3) } else { $null }
                CompleteInternetFailureChecks = $completeInternetFailures
                TargetLoss       = $targetLoss
            }
        }
        $script:cachedBaseSummaries = $summaries
    }

    function Get-DashboardPayload {
        Refresh-DashboardCache -Force $false
        $status = $null
        if (Test-Path -LiteralPath $statusPath) {
            try { $status = Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json } catch { $status = $null }
        }

        $monitorAlive = $false
        if ($null -ne $status -and $status.Running) {
            $monitorAlive = $null -ne (Get-Process -Id $status.ProcessId -ErrorAction SilentlyContinue)
        }

        $publicShare = $null
        if (Test-Path -LiteralPath $shareInfoPath) {
            try {
                $shareInfo = Get-Content -Raw -LiteralPath $shareInfoPath | ConvertFrom-Json
                if ($shareInfo.Running -and $null -ne (Get-Process -Id $shareInfo.TunnelProcessId -ErrorAction SilentlyContinue)) {
                    $publicShare = [pscustomobject]@{
                        Url          = $shareInfo.Url
                        TemporaryUrl = [bool]$shareInfo.TemporaryUrl
                    }
                }
            }
            catch { $publicShare = $null }
        }

        $now = [DateTimeOffset]::UtcNow
        $activeOutage = $null
        $issueDetected = if ($null -ne $status -and $null -ne $status.PSObject.Properties['IssueDetected']) { [bool]$status.IssueDetected } else { $null -ne $status -and -not $status.Online }
        if ($monitorAlive -and $issueDetected -and $status.OutageStartLocal) {
            $start = [DateTimeOffset]::Parse($status.OutageStartLocal).ToUniversalTime()
            $activeOutage = [pscustomobject]@{
                Id              = 'active'
                StartUtc        = $start.ToString('o')
                EndUtc          = $null
                DurationSeconds = [math]::Round(($now - $start).TotalSeconds, 3)
                Severity        = if ($null -ne $status.PSObject.Properties['IssueSeverity']) { $status.IssueSeverity } else { 'Outage' }
                Classification  = $status.OutageType
                Gateway         = $status.Gateway
                FailedTargets   = if ($null -ne $status.PSObject.Properties['IssueTargets']) { $status.IssueTargets } else { '' }
                AdapterStatus   = $status.AdapterStatus
                WifiSignalPercent = if ($null -ne $status.PSObject.Properties['WifiSignalPercent']) { $status.WifiSignalPercent } else { $null }
                GatewaySuccess  = $status.GatewaySuccess
                Active          = $true
            }
        }

        $summaries = @{}
        foreach ($period in @(
            [pscustomobject]@{ Key = '15m'; Since = $now.AddMinutes(-15) },
            [pscustomobject]@{ Key = '24h'; Since = $now.AddHours(-24) },
            [pscustomobject]@{ Key = '7d'; Since = $now.AddDays(-7) },
            [pscustomobject]@{ Key = '30d'; Since = $now.AddDays(-30) }
        )) {
            $base = $script:cachedBaseSummaries[$period.Key]
            $summary = [pscustomobject]@{
                Samples         = if ($null -ne $base) { $base.Samples } else { 0 }
                FailedChecks    = if ($null -ne $base) { $base.FailedChecks } else { 0 }
                Availability    = if ($null -ne $base) { $base.Availability } else { $null }
                EventCount      = if ($null -ne $base) { $base.EventCount } else { 0 }
                OutageCount     = if ($null -ne $base) { $base.OutageCount } else { 0 }
                ProbableUpstreamCount = if ($null -ne $base) { $base.ProbableUpstreamCount } else { 0 }
                LocalPathCount  = if ($null -ne $base) { $base.LocalPathCount } else { 0 }
                DeviceEventCount = if ($null -ne $base) { $base.DeviceEventCount } else { 0 }
                PotentialCount  = if ($null -ne $base) { $base.PotentialCount } else { 0 }
                NoiseCount      = if ($null -ne $base) { $base.NoiseCount } else { 0 }
                DowntimeSeconds = if ($null -ne $base) { $base.DowntimeSeconds } else { 0 }
                AffectedSeconds = if ($null -ne $base) { $base.AffectedSeconds } else { 0 }
                InternetProbeAttempts = if ($null -ne $base) { $base.InternetProbeAttempts } else { 0 }
                InternetProbeFailures = if ($null -ne $base) { $base.InternetProbeFailures } else { 0 }
                InternetProbeLossPercent = if ($null -ne $base) { $base.InternetProbeLossPercent } else { $null }
                GatewayProbeAttempts = if ($null -ne $base) { $base.GatewayProbeAttempts } else { 0 }
                GatewayProbeFailures = if ($null -ne $base) { $base.GatewayProbeFailures } else { 0 }
                GatewayProbeLossPercent = if ($null -ne $base) { $base.GatewayProbeLossPercent } else { $null }
                CompleteInternetFailureChecks = if ($null -ne $base) { $base.CompleteInternetFailureChecks } else { 0 }
                TargetLoss       = if ($null -ne $base) { $base.TargetLoss } else { @() }
            }
            if ($null -ne $activeOutage) {
                $activeStart = [DateTimeOffset]::Parse($activeOutage.StartUtc)
                $overlapStart = if ($activeStart -gt $period.Since) { $activeStart } else { $period.Since }
                if ($now -gt $overlapStart) {
                    $overlapSeconds = ($now - $overlapStart).TotalSeconds
                    if ($activeOutage.Severity -eq 'Outage') {
                        $summary.EventCount++
                        $summary.AffectedSeconds = [math]::Round($summary.AffectedSeconds + $overlapSeconds, 3)
                        if ($activeOutage.Classification -eq 'ISP/upstream internet (ICMP and TCP failed)') {
                            $summary.OutageCount++
                            $summary.DowntimeSeconds = [math]::Round($summary.DowntimeSeconds + $overlapSeconds, 3)
                        }
                        elseif ($activeOutage.Classification -eq 'ISP/upstream internet') { $summary.ProbableUpstreamCount++ }
                        elseif ($activeOutage.Classification -eq 'Wi-Fi adapter disconnected') { $summary.DeviceEventCount++ }
                        else { $summary.LocalPathCount++ }
                    }
                    elseif ($activeOutage.Severity -eq 'Noise') { $summary.NoiseCount++ }
                    else {
                        $summary.EventCount++
                        $summary.AffectedSeconds = [math]::Round($summary.AffectedSeconds + $overlapSeconds, 3)
                        $summary.PotentialCount++
                    }
                }
            }
            $summaries[$period.Key] = $summary
        }

        $history = @($script:cachedCompletedOutages | Select-Object -First 500)
        if ($null -ne $activeOutage) { $history = @($activeOutage) + $history }
        $timelineCutoff = $now.AddDays(-30)
        $timeline = @($history | Where-Object {
            $end = if ($_.Active) { $now } else { [DateTimeOffset]::Parse($_.EndUtc) }
            $end -ge $timelineCutoff
        })
        $latencyCutoff = $now.AddHours(-24)
        $latencySeries = @($script:cachedMinutePoints | Where-Object { $_.Time -ge $latencyCutoff } | ForEach-Object {
            [pscustomobject]@{
                TimeUtc    = $_.TimeUtc
                AvgLatency = $_.AvgLatency
                MaxLatency = $_.MaxLatency
                FailurePct = $_.FailurePct
            }
        })
        $packetLossSeries = @($script:cachedPacketLossPoints | Where-Object { $_.Time -ge $latencyCutoff } | ForEach-Object {
            [pscustomobject]@{
                TimeUtc             = $_.TimeUtc
                InternetLossPercent = $_.InternetLossPercent
                GatewayLossPercent  = $_.GatewayLossPercent
            }
        })

        return [pscustomobject]@{
            ServerNowUtc  = $now.ToString('o')
            MonitorAlive  = $monitorAlive
            Monitor       = $status
            PublicShare   = $publicShare
            ActiveOutage  = $activeOutage
            Summaries     = $summaries
            Outages       = $history
            Timeline      = $timeline
            LatencySeries = $latencySeries
            PacketLossSeries = $packetLossSeries
        }
    }

    Refresh-DashboardCache -Force $true
    $keepRunning = $true
    $lastMonitorCheck = [DateTimeOffset]::MinValue
    while ($keepRunning) {
        if ($listener.Pending()) {
            $client = $listener.AcceptTcpClient()
            try {
                $client.ReceiveTimeout = 3000
                $reader = New-Object System.IO.StreamReader($client.GetStream(), [System.Text.Encoding]::ASCII, $false, 1024, $true)
                $requestLine = $reader.ReadLine()
                $headers = @{}
                while ($true) {
                    $headerLine = $reader.ReadLine()
                    if ([string]::IsNullOrEmpty($headerLine)) { break }
                    $separator = $headerLine.IndexOf(':')
                    if ($separator -gt 0) {
                        $headers[$headerLine.Substring(0, $separator).Trim().ToLowerInvariant()] = $headerLine.Substring($separator + 1).Trim()
                    }
                }
                $requestMethod = ''
                $requestPath = ''
                if ($requestLine -match '^([A-Z]+)\s+([^\s]+)') {
                    $requestMethod = $matches[1]
                    $requestPath = $matches[2].Split('?')[0]
                }
                $contentLength = 0
                if ($headers.ContainsKey('content-length')) { [int]::TryParse($headers['content-length'], [ref]$contentLength) | Out-Null }
                if ($contentLength -lt 0 -or $contentLength -gt 4096) {
                    Write-HttpResponse -Client $client -StatusCode 400 -ContentType 'application/json; charset=utf-8' -Body '{"error":"Invalid request body."}'
                    continue
                }
                $body = ''
                if ($contentLength -gt 0) {
                    $buffer = New-Object char[] $contentLength
                    $read = 0
                    while ($read -lt $contentLength) {
                        $count = $reader.Read($buffer, $read, $contentLength - $read)
                        if ($count -le 0) { break }
                        $read += $count
                    }
                    $body = -join $buffer[0..([math]::Max(0, $read - 1))]
                }
                if ($requestMethod -eq 'GET' -and ($requestPath -eq '/' -or $requestPath -eq '/index.html')) {
                    Write-HttpResponse -Client $client -StatusCode 200 -ContentType 'text/html; charset=utf-8' -Body $dashboardHtml
                }
                elseif ($requestMethod -eq 'GET' -and $requestPath -eq '/api/data') {
                    try {
                        $payload = Get-DashboardPayload
                        Write-HttpResponse -Client $client -StatusCode 200 -ContentType 'application/json; charset=utf-8' -Body ($payload | ConvertTo-Json -Depth 10 -Compress)
                    }
                    catch {
                        Write-HttpResponse -Client $client -StatusCode 500 -ContentType 'application/json; charset=utf-8' -Body '{"error":"Dashboard data is temporarily unavailable."}'
                    }
                }
                elseif ($requestMethod -eq 'POST' -and $requestPath -eq '/api/reset') {
                    $clientKey = if ($headers.ContainsKey('cf-connecting-ip')) { $headers['cf-connecting-ip'] } else { [string]$client.Client.RemoteEndPoint }
                    $attempt = if ($failedResetAttempts.ContainsKey($clientKey)) { $failedResetAttempts[$clientKey] } else { $null }
                    if ($null -ne $attempt -and ([DateTimeOffset]::UtcNow - $attempt.WindowStart).TotalMinutes -ge 5) {
                        $failedResetAttempts.Remove($clientKey)
                        $attempt = $null
                    }
                    if ($null -ne $attempt -and $attempt.Count -ge 5) {
                        Write-HttpResponse -Client $client -StatusCode 429 -ContentType 'application/json; charset=utf-8' -Body '{"error":"Too many incorrect attempts. Try again in a few minutes."}'
                        continue
                    }
                    try {
                        $requestJson = $body | ConvertFrom-Json
                        $password = if ($null -ne $requestJson.PSObject.Properties['password']) { [string]$requestJson.password } else { '' }
                        $resetResult = Invoke-HistoryReset -Password $password
                        if ($resetResult.StatusCode -eq 401) {
                            if ($null -eq $attempt) { $attempt = [pscustomobject]@{ Count = 0; WindowStart = [DateTimeOffset]::UtcNow } }
                            $attempt.Count++
                            $failedResetAttempts[$clientKey] = $attempt
                        }
                        elseif ($resetResult.StatusCode -eq 200) { $failedResetAttempts.Remove($clientKey) }
                        Write-HttpResponse -Client $client -StatusCode $resetResult.StatusCode -ContentType 'application/json; charset=utf-8' -Body $resetResult.Body
                    }
                    catch {
                        Write-HttpResponse -Client $client -StatusCode 400 -ContentType 'application/json; charset=utf-8' -Body '{"error":"Invalid reset request."}'
                    }
                }
                elseif ($requestMethod -eq 'GET' -and $requestPath -eq '/favicon.ico') {
                    Write-HttpResponse -Client $client -StatusCode 204 -ContentType 'image/x-icon' -Body ''
                }
                elseif ($requestPath -eq '/api/reset') {
                    Write-HttpResponse -Client $client -StatusCode 405 -ContentType 'application/json; charset=utf-8' -Body '{"error":"Method not allowed."}'
                }
                else {
                    Write-HttpResponse -Client $client -StatusCode 404 -ContentType 'text/plain; charset=utf-8' -Body 'Not found'
                }
            }
            catch { }
            finally { $client.Close() }
        }
        else { Start-Sleep -Milliseconds 100 }

        $now = [DateTimeOffset]::Now
        if (($now - $lastMonitorCheck).TotalSeconds -ge 1) {
            $lastMonitorCheck = $now
            $status = $null
            if (Test-Path -LiteralPath $statusPath) {
                try { $status = Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json } catch { $status = $null }
            }
            if ($null -ne $status) {
                $monitorProcess = if ($status.Running) { Get-Process -Id $status.ProcessId -ErrorAction SilentlyContinue } else { $null }
                if (-not $status.Running -or $null -eq $monitorProcess) { $keepRunning = $false }
            }
        }
    }
}
finally {
    if ($null -ne $listener) { $listener.Stop() }
    try {
        if (Test-Path -LiteralPath $serverInfoPath) {
            $currentInfo = Get-Content -Raw -LiteralPath $serverInfoPath | ConvertFrom-Json
            if ($currentInfo.InstanceId -eq $serverInstanceId) { Remove-Item -LiteralPath $serverInfoPath -Force }
        }
    }
    catch { }
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
