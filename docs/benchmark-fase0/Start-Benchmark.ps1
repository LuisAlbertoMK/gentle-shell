#Requires -Version 5.1
<#
.SYNOPSIS
  Runs one benchmark scenario sample series for a tool (Fase-0 protocol).

.DESCRIPTION
  Scenarios from plan_agente_liviano_refutado.md section 7.1:

    A  Idle right after start          -> decision baseline (idle RAM)
    B  Active task                      -> active behaviour
    C  With ONE subagent active         -> per-subagent delta (informative)
    D  After ~30 min of session         -> growth behaviour

  Preconditions checked before sampling (protocol 7.1):
    * the OTHER tool must not be running
    * the workload repository must exist

  Outputs (in -OutputDir):
    samples_<tool>_<scenario>_run<run>[_smoke].csv    tree totals per sample
    processes_<tool>_<scenario>_run<run>[_smoke].csv   per-pid attribution

  Notes:
    Scenario C is sampled while the human drives the subagent: the script
    cannot spawn a tool's subagent itself. Pass -Label to mark it (e.g.
    -Label 'subagent-1').
    Use -DryRun only to validate the machinery: it takes two samples and
    writes *_smoke.csv files, never the real run files.

.EXAMPLE
  pwsh -File bench\Start-Benchmark.ps1 -Tool opencode -Scenario A -Run 1
.EXAMPLE
  pwsh -File bench\Start-Benchmark.ps1 -Tool gentle-shell -Scenario B -Run 2 -DurationMinutes 30
#>

[CmdletBinding()]
param(
  [ValidateSet('opencode', 'gentle-shell', 'auto')]
  [string]$Tool = 'auto',

  [ValidateSet('A', 'B', 'C', 'D')]
  [string]$Scenario = 'A',

  [ValidateRange(1, 99)]
  [int]$Run = 1,

  [ValidateRange(1, 3600)]
  [int]$IntervalSeconds = 60,

  [ValidateRange(1, 480)]
  [int]$DurationMinutes = 30,

  [string]$OutputDir = (Join-Path $PSScriptRoot 'results'),

  [string]$Repo = 'D:\socialemperors',

  # Explicit root PID override, mainly for -DryRun smoke tests.
  [int]$ProcessId = 0,

  [string]$Label = ('run{0}-{1}' -f $Run, (Get-Date -Format 'HHmmss')),

  # Regex over CommandLine for SIBLING agent sessions created during this
  # run (scenario C). gentle-shell subagents are their own
  # launcher + cli.js pair, siblings of the measured session, so a
  # single-root tree misses them. Suggested:
  #   -NewProcessPattern 'gentle-shell\.mjs|pi-coding-agent'
  [string]$NewProcessPattern = '',

  # Regex over CommandLine matched at EVERY sample, any process age. When set,
  # the run has no single root: the sampled unit is every matching process
  # (plus its tree). Needed to measure scripted `opencode run` workloads,
  # whose processes are siblings of the TUI, not children.
  [string]$AnyProcessPattern = '',

  # Reusing (tool, scenario, run) normally throws so the three repetitions
  # stay separate; this overrides.
  [switch]$Force,

  # Protocol deviation: allow measuring while ANOTHER agent tool is running.
  # Needed when the sampler itself lives inside the other tool (e.g. this
  # harness measuring opencode from a gentle-shell session). The metrology
  # of the measured tree is unaffected (sampling starts at that tool's root),
  # but CPU numbers carry concurrent-load noise and the protocol's fairness
  # condition is knowingly broken: the deviation is stamped into the Label
  # of every sample so no CSV can be mistaken for a clean protocol run.
  [switch]$AllowConcurrentTools,

  [switch]$DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($AnyProcessPattern -and $Tool -eq 'auto') {
  throw 'Pattern-only mode (-AnyProcessPattern) requires an explicit -Tool (opencode or gentle-shell): auto-detection would resolve to whichever tool hosts the sampler.'
}

. (Join-Path $PSScriptRoot 'ProcessTree.ps1')

# --- Preconditions -----------------------------------------------------------

# Resolve 'auto' BEFORE preconditioning: with -Tool auto the measured tool
# IS whatever auto-detection finds, so "is the other tool running" can only
# be answered after resolution (previously auto always self-threw).
$effectiveTool = $Tool
if ($Tool -eq 'auto') {
  $autoRoot = Find-ToolRoot -Tool 'auto'
  $effectiveTool = if ($autoRoot) { $autoRoot.Tool } else { $null }
}

foreach ($other in @('opencode', 'gentle-shell')) {
  if ($null -eq $effectiveTool -or $other -eq $effectiveTool) { continue }
  $otherRoot = Find-ToolRoot -Tool $other
  if ($otherRoot) {
    if (-not $AllowConcurrentTools) {
      throw ("Protocol precondition failed: '{0}' is running (pid {1}). Close every agent tool except the one under test before measuring (plan 7.1, step 1). If the sampler itself must run inside the other tool, pass -AllowConcurrentTools knowingly: the deviation is stamped into the CSV Label." -f $other, $otherRoot.Process.Id)
    }
    Write-Warning ("DEVIATION from plan 7.1: '{0}' is running (pid {1}) while measuring '{2}'. Tree metrics stay valid (sampling starts at the measured root); CPU numbers carry concurrent-load noise. Stamping Label." -f $other, $otherRoot.Process.Id, $effectiveTool)
    $Label = "{0}|concurrent:{1}" -f $Label, $other
  }
}

if (-not (Test-Path -LiteralPath $Repo)) {
  throw ("Workload repo not found: {0}. Pass -Repo with an existing repository (the plan suggests the same repo for both tools)." -f $Repo)
}

# --- Root resolution ----------------------------------------------------------

$root = $null
if ($AnyProcessPattern) {
  $root = [pscustomobject]@{
    Tool        = $Tool
    Process     = $null
    DetectedVia = "pattern-only: $AnyProcessPattern"
    RootReason  = 'pattern-only'
  }
}
elseif ($ProcessId -gt 0) {
  $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
  if (-not $proc) { throw ("No process with pid {0}." -f $ProcessId) }
  $root = [pscustomobject]@{
    Tool        = if ($Tool -eq 'auto') { 'explicit' } else { $Tool }
    Process     = $proc
    DetectedVia = "explicit -ProcessId {0}" -f $ProcessId
    RootReason  = 'explicit override'
  }
}
else {
  $root = Find-ToolRoot -Tool $Tool
  if (-not $root) {
    if ($NewProcessPattern) {
      # Automated mode: no TUI root needed, pattern-only sampling
      $root = [pscustomobject]@{
        Tool        = $Tool
        Process     = $null
        DetectedVia = "pattern-only: $NewProcessPattern"
        RootReason  = 'pattern-only'
      }
    } else {
      throw ("Could not find a running root process for tool '{0}'. Start the tool first, or pass -ProcessId (use -DryRun plus -ProcessId to smoke-test the machinery)." -f $Tool)
    }
  }
}

# --- Self-contamination guard (pattern-only mode) -------------------------------
# `opencode run` workload procs are matched by CommandLine pattern. When the
# sampler itself runs INSIDE an agent session (e.g. the orchestrator launched
# from opencode), the invoker's own tree matches the pattern too and inflates
# every sample (measured 2026-10-13: 24 procs / 2650 MB vs 10 procs / 950 MB
# clean). That offset is roughly constant, so B-vs-C deltas stay informative,
# but the run must be stamped so it can never pass as a clean protocol run.
if ($AnyProcessPattern -or $NewProcessPattern) {
  try {
    # Start from the PARENT: this process' own CommandLine trivially contains
    # the pattern (it was passed as an argument), which would self-stamp
    # every pattern run. Ancestors match only when really hosted in a session.
    $selfProc = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue
    $selfId = if ($selfProc) { [int]$selfProc.ParentProcessId } else { 0 }
    $selfHit = $null
    $hops = 0
    while ($selfId -gt 0 -and $hops -lt 25) {
      $selfProc = Get-CimInstance Win32_Process -Filter "ProcessId=$selfId" -ErrorAction SilentlyContinue
      if (-not $selfProc) { break }
      if ($selfProc.CommandLine -match 'opencode\.exe|opencode\.cmd|pi-coding-agent|gentle-shell\.mjs') {
        $selfHit = $selfProc.CommandLine
        break
      }
      $parentId = [int]$selfProc.ParentProcessId
      if ($parentId -le 0 -or $parentId -eq $selfId) { break }
      $selfId = $parentId
      $hops++
    }
    if ($selfHit) {
      $short = if ($selfHit.Length -gt 80) { $selfHit.Substring(0, 80) + '...' } else { $selfHit }
      Write-Warning ("SELF-CONTAMINATION: the sampler runs inside an agent session ('{0}'). Its tree matches the sampling pattern and inflates every sample by a roughly constant offset. Prefer a neutral terminal for clean protocol runs. Stamping Label." -f $short)
      $Label = "{0}|self:agent-session" -f $Label
    }
  } catch {
    Write-Warning ("Self-contamination check skipped: {0}" -f $_.Exception.Message)
  }
}

$scenarioText = @{
  A = 'idle right after start'
  B = 'active task'
  C = 'with ONE subagent active (drive it yourself; use -Label and -NewProcessPattern)'
  D = 'after ~30 minutes of session'
}[$Scenario]

$interval = $IntervalSeconds
$totalSamples = [int][math]::Ceiling(($DurationMinutes * 60) / $interval) + 1
if ($DryRun) {
  $interval = 2
  $totalSamples = 2
}

Write-Host ("Tool        : {0} ({1})" -f $root.Tool, $root.DetectedVia)
Write-Host ("Root pid    : {0}" -f $(if ($AnyProcessPattern -or $NewProcessPattern) { 'n/a (pattern-only)' } else { $root.Process.Id }))
Write-Host ("Scenario    : {0} - {1}" -f $Scenario, $scenarioText)
Write-Host ("Run         : {0}" -f $Run)
Write-Host ("Interval    : {0}s, samples: {1}" -f $interval, $totalSamples)
Write-Host ("Output dir  : {0}" -f $OutputDir)
if ($DryRun) { Write-Host 'DRY RUN: 2 samples, *_smoke.csv files only.' }
Write-Host ''

$suffix = ''
if ($DryRun) { $suffix = '_smoke' }

$taken = 0
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$runStart = Get-Date

if (-not $DryRun -and -not $Force) {
  $dupSamples = Join-Path $OutputDir ("samples_{0}_{1}_run{2}.csv" -f $root.Tool, $Scenario, $Run)
  $dupProcs = Join-Path $OutputDir ("processes_{0}_{1}_run{2}.csv" -f $root.Tool, $Scenario, $Run)
  foreach ($dup in @($dupSamples, $dupProcs)) {
    if (Test-Path -LiteralPath $dup) {
      throw ("CSV already exists: {0}. The protocol needs three SEPARATE repetitions: use -Run {1} next, or -Force to append anyway." -f $dup, ([int]$Run + 1))
    }
  }
}

if ($NewProcessPattern) {
  Write-Host ("Sibling pattern : {0} (only processes created after {1})" -f $NewProcessPattern, $runStart.ToString('s'))
}
try {
  while ($taken -lt $totalSamples) {
    try {
      $sample = Save-TreeSample -RootId $(if ($AnyProcessPattern -or $NewProcessPattern) { 0 } else { $root.Process.Id }) -Tool $root.Tool -Scenario $Scenario -Run $Run -OutputDir $OutputDir -Label $Label -FileSuffix $suffix -NewProcessPattern $NewProcessPattern -Since $runStart -AnyProcessPattern $AnyProcessPattern
      $taken++
      Write-Host ("[{0}] sample {1,2}/{2}  procs={3,2}  WS={4,6} MB  private={5,6} MB  cpu={6,7} s" -f $sample.Timestamp, $taken, $totalSamples, $sample.Procs, $sample.WS_MB, $sample.Private_MB, $sample.CPU_s)
    } catch {
      Write-Host "ERROR in Save-TreeSample: $_" -ForegroundColor Red
      throw
    }
    if ($taken -ge $totalSamples) { break }
    # For scenario D the nominal duration is session time, elapsed here
    # matches the sampling window only when the session started with it.
    $sleepFor = $interval
    if (-not $DryRun) {
      $target = $stopwatch.Elapsed.TotalSeconds + $interval
      while ($stopwatch.Elapsed.TotalSeconds -lt $target) {
        Start-Sleep -Milliseconds 500
      }
      $sleepFor = 0
    }
    if ($sleepFor -gt 0) { Start-Sleep -Seconds $sleepFor }
  }
}
finally {
  Write-Host ''
  Write-Host ("Finished {0} samples in {1:N1} min (wall clock)." -f $taken, $stopwatch.Elapsed.TotalMinutes)
  if ($Scenario -eq 'C') {
    Write-Host ("Scenario C reminder: confirm a subagent was active for most samples; the chosen label was '{0}'." -f $Label)
  }
  if ($Scenario -eq 'D') {
    Write-Host 'Scenario D reminder: this measures the sampling window, not the whole session. The session must have been running ~30 min before this script started.'
  }
  Write-Host ("CSVs: {0}" -f (Join-Path $OutputDir ("samples_{0}_{1}_run{2}{3}.csv" -f $root.Tool, $Scenario, $Run, $suffix)))
  Write-Host ("      {0}" -f (Join-Path $OutputDir ("processes_{0}_{1}_run{2}{3}.csv" -f $root.Tool, $Scenario, $Run, $suffix)))
}
