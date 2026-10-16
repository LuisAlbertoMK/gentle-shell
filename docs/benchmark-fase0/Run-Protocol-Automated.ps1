#Requires -Version 5.1
<#
.SYNOPSIS
  Automated Fase-0 benchmark protocol for opencode headless (non-interactive).

.DESCRIPTION
  Runs scenarios A, B, C for opencode with 3 repetitions of 30 minutes each,
  fully automated: no human intervention needed during sampling.

  Scenarios (plan 7.1):
    A  Idle right after start          -> baseline (idle RAM)
    B  Active task                      -> 5-task workload via Drive-AutomatedWorkload.ps1
    C  With concurrent "subagent"       -> workload + second opencode run in parallel

  Scenario D (after 30 min) is covered by B's 30-min duration (tail samples show growth).

  Sampling uses -AnyProcessPattern 'opencode-ai' (pattern-only mode) because
  `opencode run` creates short-lived sibling processes, not children of a TUI.

  Two anti-aliasing measures (2026-10-14 fix): the workload driver loops its
  5 steps for the whole sampler window (sustained load, not one ~2.5 min
  burst), and sampling defaults to 15 s intervals because each `opencode run`
  proc lives ~15-40 s (60 s intervals guarantee hit/miss oscillation that
  poisons medians, slopes and CPU).

  Usage:
    pwsh -File D:\shell-MK\bench\Run-Protocol-Automated.ps1
    pwsh -File D:\shell-MK\bench\Run-Protocol-Automated.ps1 -DryRun
    pwsh -File D:\shell-MK\bench\Run-Protocol-Automated.ps1 -DurationMinutes 10 -Repetitions 1

.NOTES
  Total runtime: 3 scenarios × 3 reps × 30 min ≈ 4.5 hours (full protocol).
  Dry run: 3 scenarios × 1 rep × 2 min ≈ 6 minutes.
#>

[CmdletBinding()]
param(
  [string]$Repo = 'D:\socialemperors',
  [string]$OutputDir = (Join-Path $PSScriptRoot 'results\protocol-opencode'),
  [int]$DurationMinutes = 30,
  [int]$Repetitions = 3,
  [string]$Model = 'opencode/muse-spark-1.3-contributor-free',
  [int]$IntervalSeconds = 15,
  [int]$WorkloadStartDelaySeconds = 10,
  [switch]$DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot

if ($DryRun) {
  $DurationMinutes = 2
  $Repetitions = 1
  $IntervalSeconds = 10
  $OutputDir = Join-Path $OutputDir 'dryrun'
}

# --- Preconditions ---------------------------------------------------------

Write-Host '=== Fase-0 Protocol Automated (opencode headless) ===' -ForegroundColor Cyan
Write-Host ''

Write-Host 'Checking preconditions...' -ForegroundColor Yellow

$gsProcs = Get-Process -Name 'gentle-shell' -ErrorAction SilentlyContinue
if ($gsProcs) {
  Write-Host 'WARNING: gentle-shell is running. Protocol 7.1 says close it, but we continue (pattern-only mode is isolated).' -ForegroundColor Yellow
}

if (-not (Test-Path -LiteralPath $Repo)) {
  Write-Host "ERROR: Workload repo not found: $Repo" -ForegroundColor Red
  exit 1
}
Write-Host "  [OK] Workload repo exists: $Repo" -ForegroundColor Green

$opencodePath = (Get-Command opencode -ErrorAction SilentlyContinue).Source
if (-not $opencodePath) {
  Write-Host 'ERROR: opencode CLI not found in PATH. Install it first.' -ForegroundColor Red
  exit 1
}
Write-Host "  [OK] opencode found: $opencodePath" -ForegroundColor Green

if (-not (Test-Path -LiteralPath $OutputDir)) {
  New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}
Write-Host "  [OK] Output dir: $OutputDir" -ForegroundColor Green

Write-Host ''
Write-Host "Duration: $DurationMinutes minutes per scenario" -ForegroundColor Cyan
Write-Host "Repetitions: $Repetitions" -ForegroundColor Cyan
Write-Host "Interval: $IntervalSeconds seconds" -ForegroundColor Cyan
Write-Host "Model: $Model" -ForegroundColor Cyan
if ($DryRun) { Write-Host 'DRY RUN MODE' -ForegroundColor Magenta }
Write-Host ''

# --- Helper functions -------------------------------------------------------

function Wait-ForProcess {
  param(
    [System.Diagnostics.Process]$Process,
    [string]$Name,
    [int]$TimeoutSeconds = 0
  )
  if ($Process.HasExited) {
    Write-Host "  $Name exited early (code $($Process.ExitCode))" -ForegroundColor Yellow
    return
  }
  Write-Host "  Waiting for $Name (pid $($Process.Id))..." -ForegroundColor DarkGray
  if ($TimeoutSeconds -gt 0) {
    $exited = $Process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $exited) {
      Write-Host "  $Name timeout after ${TimeoutSeconds}s, killing..." -ForegroundColor Yellow
      $Process.Kill()
      $Process.WaitForExit()
      Write-Host "  $Name killed" -ForegroundColor Yellow
      return
    }
  } else {
    $Process.WaitForExit()
  }
  Write-Host "  $Name finished (code $($Process.ExitCode))" -ForegroundColor Green
}

function Start-WorkloadDriver {
  param([string]$Label)
  $logFile = Join-Path $OutputDir "workload_$Label.log"
  # Sustained load: loop the 5 steps ~1 min past the sampler window so the
  # tail sample still sees live procs (driver starts ~WorkloadStartDelaySeconds
  # before the sampler).
  $driverMinutes = $DurationMinutes + 1
  $args = @(
    '-File', (Join-Path $scriptDir 'Drive-AutomatedWorkload.ps1'),
    '-Repo', $Repo,
    '-Model', $Model,
    '-DurationMinutes', $driverMinutes,
    '-LogFile', $logFile
  )
  $proc = Start-Process -FilePath 'pwsh' -ArgumentList $args -PassThru -WindowStyle Hidden
  Write-Host "  Workload driver started (pid $($proc.Id)): $Label" -ForegroundColor Green
  return $proc
}

function Start-ConcurrentOpencode {
  param([string]$Label)
  $logFile = Join-Path $OutputDir "concurrent_$Label.log"
  $prompt = "Read the files README.md and PERFORMANCE.md in this repository. Show only the first 80 lines of each. Do not modify anything."
  # opencode is a .cmd shim, not a Win32 exe: use pwsh -File to launch it
  $opencodePath = (Get-Command opencode -ErrorAction Stop).Source
  $args = @('-File', $opencodePath, 'run', '-m', $Model, $prompt)
  $proc = Start-Process -FilePath 'pwsh' -ArgumentList $args -PassThru -WindowStyle Hidden -RedirectStandardOutput $logFile -RedirectStandardError "$logFile.err"
  Write-Host "  Concurrent opencode started (pid $($proc.Id)): $Label" -ForegroundColor Green
  return $proc
}

# --- Run protocol -----------------------------------------------------------

$scenarios = @(
  @{ Name = 'B'; Description = 'Active task (5-task workload)'; Workload = $true; Concurrent = $false },
  @{ Name = 'C'; Description = 'With concurrent subagent workload'; Workload = $true; Concurrent = $true }
)

$totalScenarios = $scenarios.Count * $Repetitions
$current = 0

foreach ($rep in 1..$Repetitions) {
  foreach ($scenario in $scenarios) {
    $current++
    $label = "run$rep-$($scenario.Name)"

    Write-Host ''
    Write-Host "=== [$current/$totalScenarios] Scenario $($scenario.Name) - $($scenario.Description) (rep $rep) ===" -ForegroundColor Cyan
    Write-Host ''

    # Initialize workload variables
    $workloadProc = $null
    $concurrentProc = $null

    # Start workload FIRST (so sampler can capture it)
    if ($scenario.Workload) {
      $workloadProc = Start-WorkloadDriver -Label $label
    }

    if ($scenario.Concurrent) {
      $concurrentProc = Start-ConcurrentOpencode -Label $label
    }

    # Wait for workload to initialize
    Start-Sleep -Seconds $WorkloadStartDelaySeconds

    # Start sampler in background (so workload can start while sampling)
    $samplerLog = Join-Path $OutputDir "sampler_$label.log"
    $samplerArgs = @(
      '-File', (Join-Path $scriptDir 'Start-Benchmark.ps1'),
      '-Tool', 'opencode',
      '-Scenario', $scenario.Name,
      '-Run', $rep,
      '-DurationMinutes', $DurationMinutes,
      '-IntervalSeconds', $IntervalSeconds,
      '-Label', $label,
      '-Repo', $Repo,
      '-OutputDir', $OutputDir,
      '-AnyProcessPattern', 'opencode-ai',
      '-AllowConcurrentTools'
    )
    if ($DryRun) { $samplerArgs += '-DryRun' }

    Write-Host "  Starting sampler (log: $samplerLog)" -ForegroundColor Green
    $samplerProc = Start-Process -FilePath 'pwsh' -ArgumentList $samplerArgs -PassThru -WindowStyle Hidden -RedirectStandardOutput $samplerLog -RedirectStandardError "$samplerLog.err"

    # Wait for sampler to finish
    if ($samplerProc -and -not $samplerProc.HasExited) {
      Write-Host "  Waiting for sampler (pid $($samplerProc.Id))..." -ForegroundColor DarkGray
      $samplerProc.WaitForExit()
      $samplerExitCode = $samplerProc.ExitCode
      if ($samplerExitCode -ne 0) {
        Write-Host "  ERROR: Sampler failed (exit $samplerExitCode)" -ForegroundColor Red
        if (Test-Path $samplerLog) {
          Write-Host "  Last 10 lines of sampler log:" -ForegroundColor Red
          Get-Content $samplerLog -Tail 10 | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        }
      } else {
        Write-Host "  Sampler finished (exit 0)" -ForegroundColor Green
      }
    }

    # Wait for workload to finish (if still running)
    # In dry-run, timeout workload after sampler duration + buffer
    $workloadTimeout = if ($DryRun) { $DurationMinutes * 60 + 30 } else { 0 }
    if ($workloadProc -and -not $workloadProc.HasExited) {
      Wait-ForProcess -Process $workloadProc -Name "Workload $label" -TimeoutSeconds $workloadTimeout
    }
    if ($concurrentProc -and -not $concurrentProc.HasExited) {
      Wait-ForProcess -Process $concurrentProc -Name "Concurrent $label" -TimeoutSeconds $workloadTimeout
    }

    Write-Host "  Scenario $($scenario.Name) rep $rep completed." -ForegroundColor Green
  }
}

# --- Final report -----------------------------------------------------------

Write-Host ''
Write-Host '=== Generating report ===' -ForegroundColor Cyan
Write-Host ''

& pwsh -File (Join-Path $scriptDir 'Compare-Benchmark.ps1') -OutputDir $OutputDir

Write-Host ''
Write-Host '=== Protocol Complete ===' -ForegroundColor Green
Write-Host ''
Write-Host "Results in: $OutputDir" -ForegroundColor Yellow
Write-Host "Total scenarios: $totalScenarios" -ForegroundColor Yellow
Write-Host "Duration per scenario: $DurationMinutes minutes" -ForegroundColor Yellow
