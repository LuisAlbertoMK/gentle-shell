#Requires -Version 5.1
<#
.SYNOPSIS
  Drives the plan's 5-task workload automatically through `opencode run`.

.DESCRIPTION
  Companion of Start-Benchmark.ps1 pattern-only mode: each `opencode run`
  invocation is a short-lived sibling process, so the sampler cannot follow
  one root. This script runs the same five tasks the manual protocol defines
  (plan 7.1), sequentially, each in a FRESH session with the same model, so
  the workload is identical every repetition and needs no human typing.

  Steps: read with limits, grep, edit (revertible), run a command, summarize.
  Afterwards it reverts the repo (removes the probe file, restores tracked
  edits).

  The 5 steps take ~2.5 min per pass, far shorter than a 10-30 min sampling
  window. With -DurationMinutes > 0 the passes REPEAT until the time expires,
  so pattern-only sampling sees sustained load instead of one burst followed
  by emptiness (hit/miss oscillation that poisons medians and slopes).
  Pass 1 always runs fully even if the duration expires mid-pass.

.EXAMPLE
  pwsh -File bench\Drive-AutomatedWorkload.ps1 -Repo D:\socialemperors
#>

[CmdletBinding()]
param(
  [string]$Repo = 'D:\socialemperors',

  [string]$Model = 'opencode/muse-spark-1.3-contributor-free',

  [ValidateRange(0, 120)]
  [int]$PauseSeconds = 5,

  # Sustained-load loop: repeat the 5 steps until this many minutes elapse.
  # 0 (default) keeps the legacy single pass. The orchestrator passes the
  # sampler duration (+1 min buffer) so load covers the whole window.
  [ValidateRange(0, 480)]
  [int]$DurationMinutes = 0,

  [string]$LogFile = (Join-Path $PSScriptRoot 'results\workload_driver.log')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Repo)) {
  throw "Repo not found: $Repo"
}

$dir = Split-Path -Parent $LogFile
if (-not (Test-Path -LiteralPath $dir)) {
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

$steps = @(
  @{ Name = '1-read';      Prompt = "Read the files README.md and PERFORMANCE.md in this repository. Show only the first 80 lines of each, using offset/limit. Do not modify anything." },
  @{ Name = '2-grep';      Prompt = "Search this repository for the text 'opcode'. List every file that contains it with a match count per file. Do not modify anything." },
  @{ Name = '3-edit';      Prompt = "Create a new file named bench_probe_tmp.md containing exactly one line: 'probe'. Do not modify any other file." },
  @{ Name = '4-command';   Prompt = "Run the shell command 'git status --short' in this repository and show its output." },
  @{ Name = '5-summarize'; Prompt = "In five bullet points, summarize what this repository does, based on the files you read. Do not modify anything." }
)

function Write-Log {
  param([string]$Message)
  $line = ("[{0}] {1}" -f (Get-Date -Format s), $Message)
  Add-Content -LiteralPath $LogFile -Value $line
  Write-Host $line
}

Write-Log ("workload start repo={0} model={1} durationMin={2}" -f $Repo, $Model, $DurationMinutes)

$deadline = if ($DurationMinutes -gt 0) { (Get-Date).AddMinutes($DurationMinutes) } else { [datetime]::MaxValue }
$pass = 0
$continueLoop = $true
while ($continueLoop) {
$pass++
if ($pass -gt 1) { Write-Log ("pass {0}: repeat (sustained load)" -f $pass) }

foreach ($step in $steps) {
  Write-Log ("step {0}: running opencode run" -f $step.Name)
  $started = Get-Date
  try {
    # The workload MUST run with CWD inside $Repo: `opencode run` resolves
    # "this repository" from the working directory, not from -Repo. Without
    # this, prompts drift to wherever the orchestrator was launched from
    # (measured 2026-10-13: probes landed in D:\shell-MK instead of the
    # workload repo, and cleanup removed the wrong path).
    Push-Location -LiteralPath $Repo
    try {
      $output = & opencode run -m $Model $step.Prompt 2>&1
    }
    finally {
      Pop-Location
    }
    $exitCode = $LASTEXITCODE
    $tail = ($output | Select-Object -Last 3) -join ' | '
    if ($tail.Length -gt 300) { $tail = $tail.Substring(0, 300) + '...' }
    Write-Log ("step {0}: exit={1} secs={2:N0} tail={3}" -f $step.Name, $exitCode, ((Get-Date) - $started).TotalSeconds, $tail)
  }
  catch {
    Write-Log ("step {0}: ERROR {1}" -f $step.Name, $_.Exception.Message)
  }
  if ($PauseSeconds -gt 0 -and $step.Name -ne $steps[-1].Name) {
    Start-Sleep -Seconds $PauseSeconds
  }
}

$continueLoop = (Get-Date) -lt $deadline
} # while: pass 1 always completes; repeats only when -DurationMinutes is set
Write-Log ("passes completed: {0}" -f $pass)

# --- Cleanup: leave the repo exactly as it was found --------------------------
try {
  $probe = Join-Path $Repo 'bench_probe_tmp.md'
  if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Force }
  Push-Location $Repo
  & git checkout -- . 2>&1 | Out-Null
  Pop-Location
  Write-Log 'cleanup: probe removed, tracked files restored'
}
catch {
  Write-Log ("cleanup WARNING: {0}" -f $_.Exception.Message)
}

Write-Log ('workload end')
