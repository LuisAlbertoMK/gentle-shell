#Requires -Version 5.1
<#
.SYNOPSIS
  Builds the decision report from benchmark CSVs (plan section 7.4).

.DESCRIPTION
  Reads samples_*.csv files written by Start-Benchmark.ps1 (smoke files are
  ignored) and computes, per tool and per scenario/run:

  * median and final PRIVATE memory in MB
  * growth slope in MB/min (linear regression)
  * average CPU usage in percent of one core
  * peak private memory in the window

  Then emits the comparison: idle baseline per tool (scenario A), growth
  after 30 min (scenario D) and per-subagent cost (scenario C minus A).

  Output: a markdown report is written to
  <OutputDir>/benchmark_report_<timestamp>.md and echoed to the host.

.EXAMPLE
  pwsh -File bench\Compare-Benchmark.ps1
.EXAMPLE
  pwsh -File bench\Compare-Benchmark.ps1 -OutputDir bench\results | Out-Null; cat bench\results\benchmark_report_*.md
#>

[CmdletBinding()]
param(
  [string]$OutputDir = (Join-Path $PSScriptRoot 'results'),

  # Suggested thresholds from plan section 7.4 (explicitly "a validar").
  [double]$GrowthThresholdPercent = 20.0,

  [double]$IdleCpuThresholdPercent = 1.0
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $OutputDir)) {
  throw ("Output dir not found: {0}. Run Start-Benchmark.ps1 first." -f $OutputDir)
}

$files = Get-ChildItem -LiteralPath $OutputDir -Filter 'samples_*.csv' |
  Where-Object { $_.Name -notlike '*_smoke*' }
if (-not $files) { throw ("No samples_*.csv files in {0}." -f $OutputDir) }

function Get-SlopeMbPerMinute {
  param($Rows)
  $n = @($Rows).Count
  if ($n -lt 2) { return 0.0 }
  $t0 = $Rows[0].Time
  $sumX = 0.0; $sumY = 0.0; $sumXY = 0.0; $sumXX = 0.0
  foreach ($r in @($Rows)) {
    $x = ($r.Time - $t0).TotalMinutes
    $y = $r.Private_MB
    $sumX += $x; $sumY += $y; $sumXY += $x * $y; $sumXX += $x * $x
  }
  $den = $n * $sumXX - $sumX * $sumX
  if ([math]::Abs($den) -lt 1e-9) { return 0.0 }
  return ($n * $sumXY - $sumX * $sumY) / $den
}

$groups = @{}
foreach ($f in @($files)) {
  $rows = Import-Csv -LiteralPath $f.FullName | ForEach-Object {
    [pscustomobject]@{
      Time      = [datetimeoffset]::ParseExact($_.Timestamp, 's', [ globalization.cultureinfo]::InvariantCulture)
      Tool      = $_.Tool
      Scenario  = $_.Scenario
      Run       = [int]$_.Run
      Procs     = [int]$_.Procs
      WS_MB     = [double]$_.WS_MB
      Private_MB = [double]$_.Private_MB
      CPU_s     = [double]$_.CPU_s
    }
  }
  foreach ($g in ($rows | Group-Object Tool, Scenario, Run)) {
    $sorted = $g.Group | Sort-Object Time
    $key = "{0}|{1}|{2}" -f $sorted[0].Tool, $sorted[0].Scenario, $sorted[0].Run
    $groups[$key] = $sorted
  }
}

$summary = foreach ($key in ($groups.Keys | Sort-Object)) {
  $rows = $groups[$key]
  $elapsedMin = ($rows[-1].Time - $rows[0].Time).TotalMinutes
  $cpuAvg = 0.0
  if ($elapsedMin -gt 0) {
    # Process CPU delta in seconds over wall-clock seconds = fraction of one core.
    $cpuAvg = ($rows[-1].CPU_s - $rows[0].CPU_s) / ($elapsedMin * 60) * 100.0
  }
  $privs = @($rows.Private_MB | Sort-Object)
  $mid = [int]($privs.Count / 2)
  $median = if ($privs.Count % 2) { $privs[$mid] } else { ($privs[$mid - 1] + $privs[$mid]) / 2 }
  # Pattern-mode duty cycle: fraction of samples that caught a live proc.
  # Short-lived `opencode run` procs sampled slower than their lifetime
  # oscillate hit/miss; medians over mixed samples are meaningless, so the
  # report also shows the median over HITS only. Hit rate < 50% => the run
  # cannot support a decision (fix: sustained workload + shorter interval).
  $hits = @($rows | Where-Object { $_.Procs -gt 0 })
  $hitRate = if ($rows.Count -gt 0) { [math]::Round($hits.Count / $rows.Count * 100.0, 1) } else { 0.0 }
  $hitMedian = $null
  if ($hits.Count -gt 0) {
    $hitPrivs = @($hits.Private_MB | Sort-Object)
    $hmid = [int]($hitPrivs.Count / 2)
    $hitMedian = if ($hitPrivs.Count % 2) { $hitPrivs[$hmid] } else { ($hitPrivs[$hmid - 1] + $hitPrivs[$hmid]) / 2 }
  }
  $wsSorted = @($rows.WS_MB | Sort-Object)
  $wsMid = [int]($wsSorted.Count / 2)
  $wsMedian = if ($wsSorted.Count % 2) { $wsSorted[$wsMid] } else { ($wsSorted[$wsMid - 1] + $wsSorted[$wsMid]) / 2 }
  $growth = 0.0
  if ($rows[0].Private_MB -gt 0) {
    $growth = ($rows[-1].Private_MB - $rows[0].Private_MB) / $rows[0].Private_MB * 100.0
  }
  [pscustomobject]@{
    Tool          = $key.Split('|')[0]
    Scenario      = $key.Split('|')[1]
    Run           = $key.Split('|')[2]
    Samples       = $rows.Count
    Minutes       = [math]::Round($elapsedMin, 1)
    PeakProcs     = ($rows.Procs | Measure-Object -Maximum).Maximum
    MinProcs      = ($rows.Procs | Measure-Object -Minimum).Minimum
    PeakPriv_MB   = [math]::Round(($rows.Private_MB | Measure-Object -Maximum).Maximum, 1)
    MinPriv_MB    = [math]::Round(($rows.Private_MB | Measure-Object -Minimum).Minimum, 1)
    MedianPriv_MB = [math]::Round($median, 1)
    HitRate_pct   = $hitRate
    HitMedianPriv_MB = if ($null -ne $hitMedian) { [math]::Round($hitMedian, 1) } else { 'n/a' }
    FinalPriv_MB  = $rows[-1].Private_MB
    MedianWS_MB   = [math]::Round($wsMedian, 1)
    Slope_MB_min  = [math]::Round((Get-SlopeMbPerMinute $rows), 3)
    Growth_pct    = [math]::Round($growth, 1)
    AvgCPU_pct    = [math]::Round($cpuAvg, 2)
  }
}

# --- Comparison views ----------------------------------------------------------

$tools = $summary.Tool | Sort-Object -Unique

function Get-ScenarioMedian {
  param($Summary, $Tool, $Scenario)
  $rows = $Summary | Where-Object { $_.Tool -eq $Tool -and $_.Scenario -eq $Scenario }
  if (-not $rows) { return $null }
  return $rows
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# Benchmark report (Fase-0 protocol)')
$lines.Add('')
$lines.Add(("Generated: {0}" -f (Get-Date -Format s)))
$lines.Add(("Files read: {0}" -f @($files).Count))
$lines.Add('')
$lines.Add('## Raw per run')
$lines.Add('')
$lines.Add('| Tool | Scenario | Run | Samples | Min | Procs min-max | Priv MB min/med/peak | Hit rate % | Final priv MB | Slope MB/min | Growth % | Avg CPU % |')
$lines.Add('| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |')
foreach ($s in $summary) {
  $lines.Add(("| {0} | {1} | {2} | {3} | {4} | {5}-{6} | {7}/{8}/{9} | {10} | {11} | {12} | {13} | {14} |" -f
    $s.Tool, $s.Scenario, $s.Run, $s.Samples, $s.Minutes, $s.MinProcs, $s.PeakProcs, $s.MinPriv_MB,
    $s.MedianPriv_MB, $s.PeakPriv_MB, $s.HitRate_pct, $s.FinalPriv_MB, $s.Slope_MB_min, $s.Growth_pct, $s.AvgCPU_pct))
}
$lines.Add('')

$lines.Add('## Decision table (plan 7.4)')
$lines.Add('')
$lines.Add('| Tool | Idle median priv MB (A) | Growth trend | Avg CPU % | 30-min growth % (D) | Per-subagent cost MB (C-A, informative) | Verdict vs thresholds |')
$lines.Add('| --- | --- | --- | --- | --- | --- | --- |')
foreach ($tool in $tools) {
  $aRows = Get-ScenarioMedian $summary $tool 'A'
  $dRows = Get-ScenarioMedian $summary $tool 'D'
  $cRows = Get-ScenarioMedian $summary $tool 'C'
  $bRows = Get-ScenarioMedian $summary $tool 'B'
  $idle = if ($aRows) { [math]::Round((($aRows.MedianPriv_MB | Measure-Object -Average).Average), 1) } else { 'n/a' }
  # Growth slope is a leak/growth metric (plan 7.4: "cercana a 0"). Prefer
  # idle (A), then 30-min (D); active (B) only as last resort, always
  # labelled, because workload allocation inflates it.
  $slope = 0.0; $slopeFrom = ''
  foreach ($scenarioName in @('A', 'D', 'B')) {
    $scRows = Get-ScenarioMedian $summary $tool $scenarioName
    if ($scRows) {
      $slope = ($scRows.Slope_MB_min | Measure-Object -Average).Average
      $slopeFrom = $scenarioName
      break
    }
  }
  # The <1% threshold applies to IDLE (scenario A). Prefer A; fall back to B but
  # label the basis so an active-task CPU is never mistaken for an idle one.
  $cpu = $null; $cpuFrom = ''
  if ($aRows) { $cpu = ($aRows.AvgCPU_pct | Measure-Object -Average).Average; $cpuFrom = 'A idle' }
  elseif ($bRows) { $cpu = ($bRows.AvgCPU_pct | Measure-Object -Average).Average; $cpuFrom = 'B active' }
  $growthD = if ($dRows) { ($dRows.Growth_pct | Measure-Object -Average).Average } else { $null }
  $perAgent = if ($aRows -and $cRows) {
    [math]::Round(((($cRows.MedianPriv_MB | Measure-Object -Average).Average) - (($aRows.MedianPriv_MB | Measure-Object -Average).Average)), 1)
  } else { 'n/a' }
  $verdicts = @()
  if ($growthD -ne $null) { $verdicts += ("growth {0:N1}% vs <{1}% => {2}" -f $growthD, $GrowthThresholdPercent, $(if ($growthD -lt $GrowthThresholdPercent) { 'OK' } else { 'REVIEW' })) }
  if ($cpu -ne $null -and $cpuFrom -eq 'A idle') { $verdicts += ("cpu {0:N2}% ({1}) vs <{2}% => {3}" -f $cpu, $cpuFrom, $IdleCpuThresholdPercent, $(if ($cpu -lt $IdleCpuThresholdPercent) { 'OK' } else { 'REVIEW' })) }
  $verdict = if ($verdicts.Count) { $verdicts -join '; ' } else { 'insufficient data' }
  $lines.Add(("| {0} | {1} | slope {2:N3} MB/min ({3}) | {4} | {5} | {6} | {7} |" -f
    $tool, $idle, $slope, $(if ($slopeFrom) { $slopeFrom } else { 'n/a' }),
    $(if ($null -ne $cpu) { "$([math]::Round($cpu,2))% ($cpuFrom)" } else { 'n/a' }),
    $(if ($null -ne $growthD) { "$([math]::Round($growthD,1))%" } else { 'n/a' }), $perAgent, $verdict))
}
$lines.Add('')

$lines.Add('## Caveats')
$lines.Add('')
$lines.Add('- Thresholds are the plan''s suggestions ("a validar"), not facts.')
$lines.Add('- Scenario C requires a subagent active during sampling; without it, the delta is meaningless.')
$lines.Add('- Scenario D measures the sampling window; the session must already be ~30 min old at start.')
$lines.Add('- Compare only runs with the same scenario, same workload repo and same model/provider.')
$lines.Add('- Pattern-mode runs (short-lived `opencode run` procs): trust a run only when Hit rate % >= 50 AND the Priv min/med/peak spread is tight; a wide spread (e.g. min 42 / med 47 / peak 969) means hit/miss oscillation between live procs and residuals, and medians/slopes are meaningless.')
$lines.Add('- Pattern-mode CPU sums cumulative per-process counters over a changing set: procs exiting mid-window remove their accumulated CPU (negative Avg CPU % possible). Prefer windows where the process set is stable.')

$report = $lines -join "`n"
$reportPath = Join-Path $OutputDir ("benchmark_report_{0}.md" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
Set-Content -LiteralPath $reportPath -Value $report -Encoding utf8
Write-Host $report
Write-Host ''
Write-Host ("Report written to: {0}" -f $reportPath)
