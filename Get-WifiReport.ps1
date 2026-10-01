[CmdletBinding()]
param(
    [string]$DataDirectory = (Join-Path $env:LOCALAPPDATA 'WifiConnectivityMonitor'),
    [string]$OutputPath = (Join-Path (Join-Path $env:LOCALAPPDATA 'WifiConnectivityMonitor') 'wifi-report.html'),
    [switch]$NoOpen
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

New-Item -ItemType Directory -Path $DataDirectory -Force | Out-Null
if (-not $PSBoundParameters.ContainsKey('OutputPath')) {
    $OutputPath = Join-Path $DataDirectory 'wifi-report.html'
}

function ConvertTo-HtmlText {
    param($Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Format-Duration {
    param([double]$Seconds)
    if ($Seconds -lt 60) { return ('{0:N1} sec' -f $Seconds) }
    if ($Seconds -lt 3600) { return ('{0:N1} min' -f ($Seconds / 60)) }
    return ('{0:N2} hr' -f ($Seconds / 3600))
}

function Get-PeriodSummary {
    param(
        [object[]]$Rows,
        [DateTimeOffset]$Since
    )

    $selected = @($Rows | Where-Object { [DateTimeOffset]::Parse($_.MinuteStartUtc) -ge $Since })
    $samples = 0.0
    $failures = 0.0
    foreach ($row in $selected) {
        $samples += [double]$row.Samples
        $failures += [double]$row.FailureSamples
    }
    $availability = if ($samples -gt 0) { [math]::Round((1 - ($failures / $samples)) * 100, 4) } else { $null }
    return [pscustomobject]@{ Samples = $samples; Failures = $failures; Availability = $availability }
}

$statusPath = Join-Path $DataDirectory 'status.json'
$eventPath = Join-Path $DataDirectory 'outage-events.csv'
$minuteDirectory = Join-Path $DataDirectory 'minute-stats'

$status = $null
if (Test-Path -LiteralPath $statusPath) {
    try { $status = Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json } catch { $status = $null }
}

$events = if (Test-Path -LiteralPath $eventPath) { @(Import-Csv -LiteralPath $eventPath) } else { @() }
$completedOutages = @($events | Where-Object { $_.Event -eq 'End' } | Sort-Object { [DateTimeOffset]::Parse($_.StartUtc) } -Descending)

$cutoff = (Get-Date).AddDays(-31)
$minuteRows = @()
if (Test-Path -LiteralPath $minuteDirectory) {
    $minuteFiles = @(Get-ChildItem -LiteralPath $minuteDirectory -Filter 'minute-stats-*.csv' -File | Where-Object { $_.LastWriteTime -ge $cutoff })
    foreach ($file in $minuteFiles) {
        $minuteRows += @(Import-Csv -LiteralPath $file.FullName)
    }
}

$now = [DateTimeOffset]::UtcNow
$summary24 = Get-PeriodSummary -Rows $minuteRows -Since $now.AddHours(-24)
$summary7 = Get-PeriodSummary -Rows $minuteRows -Since $now.AddDays(-7)
$summary30 = Get-PeriodSummary -Rows $minuteRows -Since $now.AddDays(-30)

$running = $false
if ($null -ne $status -and $status.Running) {
    $running = $null -ne (Get-Process -Id $status.ProcessId -ErrorAction SilentlyContinue)
}
$online = $null -ne $status -and $status.Online
$stateText = if ($running -and $online) { 'ONLINE' } elseif ($running) { 'OUTAGE DETECTED' } else { 'MONITOR STOPPED' }
$stateClass = if ($running -and $online) { 'online' } elseif ($running) { 'outage' } else { 'stopped' }
$lastChecked = if ($null -ne $status -and $status.LastCheckedLocal) { ([DateTimeOffset]::Parse($status.LastCheckedLocal)).ToString('yyyy-MM-dd HH:mm:ss zzz') } else { 'No checks recorded yet' }
$latency = if ($null -ne $status -and $null -ne $status.BestInternetLatencyMs) { "$($status.BestInternetLatencyMs) ms" } else { '--' }
$activeOutageText = ''
if ($running -and -not $online -and $status.OutageStartLocal) {
    $activeSeconds = ([DateTimeOffset]::Now - [DateTimeOffset]::Parse($status.OutageStartLocal)).TotalSeconds
    $activeOutageText = "<div class='active-outage'>Current outage began $(ConvertTo-HtmlText (([DateTimeOffset]::Parse($status.OutageStartLocal)).ToString('yyyy-MM-dd HH:mm:ss'))) &mdash; $(ConvertTo-HtmlText (Format-Duration $activeSeconds)) so far. Likely: $(ConvertTo-HtmlText $status.OutageType).</div>"
}

function Get-AvailabilityHtml {
    param($Summary)
    if ($null -eq $Summary.Availability) { return 'Collecting data' }
    return ('{0:N4}%' -f $Summary.Availability)
}

$recentRows = @($completedOutages | Select-Object -First 100)
$outageTableRows = if ($recentRows.Count -eq 0) {
    "<tr><td colspan='5' class='empty'>No completed outages recorded yet.</td></tr>"
} else {
    ($recentRows | ForEach-Object {
        $start = ([DateTimeOffset]::Parse($_.StartLocal)).ToString('yyyy-MM-dd HH:mm:ss')
        $end = ([DateTimeOffset]::Parse($_.EndLocal)).ToString('yyyy-MM-dd HH:mm:ss')
        "<tr><td>$(ConvertTo-HtmlText $start)</td><td>$(ConvertTo-HtmlText $end)</td><td class='duration'>$(ConvertTo-HtmlText (Format-Duration ([double]$_.DurationSeconds)))</td><td>$(ConvertTo-HtmlText $_.Classification)</td><td>$(ConvertTo-HtmlText $_.Gateway)</td></tr>"
    }) -join [Environment]::NewLine
}

$targetsHtml = ''
if ($null -ne $status -and $null -ne $status.Targets) {
    $targetsHtml = (@($status.Targets) | ForEach-Object {
        $probeState = if ($_.Success) { 'OK' } else { 'FAILED' }
        $probeLatency = if ($null -ne $_.LatencyMs) { "$($_.LatencyMs) ms" } else { '--' }
        "<span class='probe $($probeState.ToLower())'>$(ConvertTo-HtmlText $_.Target): $probeState ($probeLatency)</span>"
    }) -join ''
}

$totalOutageSeconds = 0.0
foreach ($outage in $completedOutages) {
    $totalOutageSeconds += [double]$outage.DurationSeconds
}
$generated = [DateTimeOffset]::Now.ToString('yyyy-MM-dd HH:mm:ss zzz')
$adapterName = if ($null -ne $status) { $status.AdapterName } else { '--' }
$gateway = if ($null -ne $status) { $status.Gateway } else { '--' }

$html = @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta http-equiv="refresh" content="30">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Wi-Fi Connectivity Report</title>
  <style>
    :root { color-scheme: dark; --bg:#08111f; --panel:#101c2d; --line:#253651; --text:#eaf1fb; --muted:#94a7c2; --green:#39d98a; --red:#ff6577; --amber:#ffbe55; --blue:#62a9ff; }
    * { box-sizing:border-box; }
    body { margin:0; background:linear-gradient(145deg,#07101d,#0b1729 55%,#0a1321); color:var(--text); font-family:Segoe UI,system-ui,sans-serif; }
    main { max-width:1180px; margin:0 auto; padding:32px 20px 60px; }
    header { display:flex; justify-content:space-between; gap:20px; align-items:flex-end; margin-bottom:22px; }
    h1 { margin:0 0 5px; font-size:clamp(25px,4vw,38px); letter-spacing:-.03em; }
    .sub,.generated { color:var(--muted); font-size:14px; }
    .status { border:1px solid var(--line); background:rgba(16,28,45,.92); border-radius:18px; padding:24px; box-shadow:0 20px 50px rgba(0,0,0,.22); }
    .state { display:flex; align-items:center; gap:12px; font-size:22px; font-weight:750; }
    .dot { width:13px; height:13px; border-radius:50%; box-shadow:0 0 18px currentColor; }
    .online { color:var(--green); }.outage { color:var(--red); }.stopped { color:var(--amber); }
    .status-grid,.summary-grid { display:grid; grid-template-columns:repeat(4,minmax(0,1fr)); gap:14px; margin-top:22px; }
    .metric { background:#0a1525; border:1px solid var(--line); border-radius:13px; padding:15px; }
    .metric label { display:block; color:var(--muted); font-size:12px; text-transform:uppercase; letter-spacing:.08em; margin-bottom:7px; }
    .metric strong { font-size:20px; overflow-wrap:anywhere; }
    .active-outage { margin-top:16px; border:1px solid rgba(255,101,119,.5); background:rgba(255,101,119,.09); color:#ffd8dd; padding:13px 15px; border-radius:11px; }
    .probes { margin-top:16px; display:flex; flex-wrap:wrap; gap:8px; }
    .probe { display:inline-block; border:1px solid var(--line); border-radius:999px; padding:6px 10px; font-size:12px; color:var(--muted); }
    .probe.ok { border-color:rgba(57,217,138,.35); color:#9cf0c6; }.probe.failed { border-color:rgba(255,101,119,.4); color:#ffb5be; }
    section { margin-top:26px; }
    h2 { margin:0 0 13px; font-size:19px; }
    .summary-grid { margin-top:0; grid-template-columns:repeat(3,minmax(0,1fr)); }
    .summary-grid .metric strong { color:var(--blue); }
    .summary-grid small { display:block; color:var(--muted); margin-top:7px; }
    .table-wrap { overflow:auto; border:1px solid var(--line); border-radius:14px; background:var(--panel); }
    table { width:100%; border-collapse:collapse; min-width:800px; }
    th,td { padding:13px 15px; text-align:left; border-bottom:1px solid var(--line); font-size:13px; }
    th { color:var(--muted); font-size:11px; text-transform:uppercase; letter-spacing:.07em; background:#0c1828; }
    tr:last-child td { border-bottom:0; }.duration { color:var(--amber); font-weight:700; }.empty { color:var(--muted); text-align:center; padding:28px; }
    footer { color:var(--muted); margin-top:22px; font-size:12px; line-height:1.6; }
    @media(max-width:800px){ header{align-items:flex-start;flex-direction:column}.status-grid{grid-template-columns:repeat(2,1fr)}.summary-grid{grid-template-columns:1fr} }
  </style>
</head>
<body><main>
  <header><div><h1>Wi-Fi Connectivity Monitor</h1><div class="sub">Detecting brief internet interruptions once per second</div></div><div class="generated">Report refreshed $generated</div></header>
  <div class="status">
    <div class="state $stateClass"><span class="dot $stateClass"></span>$stateText</div>
    $activeOutageText
    <div class="status-grid">
      <div class="metric"><label>Last check</label><strong>$(ConvertTo-HtmlText $lastChecked)</strong></div>
      <div class="metric"><label>Best latency</label><strong>$(ConvertTo-HtmlText $latency)</strong></div>
      <div class="metric"><label>Wi-Fi adapter</label><strong>$(ConvertTo-HtmlText $adapterName)</strong></div>
      <div class="metric"><label>Router / gateway</label><strong>$(ConvertTo-HtmlText $gateway)</strong></div>
    </div>
    <div class="probes">$targetsHtml</div>
  </div>
  <section><h2>Measured availability</h2><div class="summary-grid">
    <div class="metric"><label>Last 24 hours</label><strong>$(Get-AvailabilityHtml $summary24)</strong><small>$([int64]$summary24.Failures) failed checks out of $([int64]$summary24.Samples)</small></div>
    <div class="metric"><label>Last 7 days</label><strong>$(Get-AvailabilityHtml $summary7)</strong><small>$([int64]$summary7.Failures) failed checks out of $([int64]$summary7.Samples)</small></div>
    <div class="metric"><label>Last 30 days</label><strong>$(Get-AvailabilityHtml $summary30)</strong><small>$([int64]$summary30.Failures) failed checks out of $([int64]$summary30.Samples)</small></div>
  </div></section>
  <section><h2>Outage history</h2><div class="table-wrap"><table><thead><tr><th>Started</th><th>Recovered</th><th>Duration</th><th>Likely source</th><th>Gateway</th></tr></thead><tbody>$outageTableRows</tbody></table></div></section>
  <footer>Completed outages: $($completedOutages.Count) &nbsp;&middot;&nbsp; Total recorded downtime: $(ConvertTo-HtmlText (Format-Duration $totalOutageSeconds))<br>Availability uses only checks actually performed, so time while the PC is asleep or the monitor is stopped is not counted. “Wi-Fi/local router” means the router also failed to answer; “ISP/upstream internet” means the router answered while all independent internet targets failed.</footer>
</main></body></html>
"@

[System.IO.File]::WriteAllText($OutputPath, $html, (New-Object System.Text.UTF8Encoding($false)))
if (-not $NoOpen) {
    Start-Process -FilePath $OutputPath
}
Write-Output $OutputPath
