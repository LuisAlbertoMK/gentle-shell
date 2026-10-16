#Requires -Version 5.1
<#
.SYNOPSIS
  Automated short validation of the Fase-0 benchmark protocol (non-interactive).

.DESCRIPTION
  Runs scenarios A, B, C for gentle-shell with 1 repetition of 10 minutes each.
  Non-interactive: uses Start-Sleep instead of Read-Host for manual scenarios.

  Usage:
    pwsh -File D:\shell-MK\bench\Run-Validation.ps1

  For manual scenarios (B and C), the script prints instructions and waits
  a fixed time before starting sampling. Prepare the workload/subagent
  during the wait window.

.NOTES
  Scenario B: read/edit files in D:\socialemperors during sampling.
  Scenario C: launch a Gentle Shell subagent during sampling.
#>

[CmdletBinding()]
param(
  [string]$Repo = 'D:\socialemperors',
  [string]$OutputDir = (Join-Path $PSScriptRoot 'results'),
  [int]$DurationMinutes = 10,
  [int]$PreScenarioDelaySeconds = 30
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot

Write-Host '=== Fase-0 Benchmark Validation (Automated) ===' -ForegroundColor Cyan
Write-Host ''

# --- Preconditions ---------------------------------------------------------

Write-Host 'Checking preconditions...' -ForegroundColor Yellow

$opencodeProcs = Get-Process -Name 'opencode' -ErrorAction SilentlyContinue
if ($opencodeProcs) {
  Write-Host 'ERROR: opencode is running. Close it before validation (protocol 7.1.1).' -ForegroundColor Red
  exit 1
}
Write-Host '  [OK] opencode not running' -ForegroundColor Green

if (-not (Test-Path -LiteralPath $Repo)) {
  Write-Host "ERROR: Workload repo not found: $Repo" -ForegroundColor Red
  exit 1
}
Write-Host "  [OK] Workload repo exists: $Repo" -ForegroundColor Green

. (Join-Path $scriptDir 'ProcessTree.ps1')
$gsRoot = Find-ToolRoot -Tool 'gentle-shell'
if (-not $gsRoot) {
  Write-Host 'ERROR: gentle-shell not running. Start Gentle Shell before validation.' -ForegroundColor Red
  exit 1
}
Write-Host "  [OK] gentle-shell running (pid $($gsRoot.Process.Id))" -ForegroundColor Green

Write-Host ''
Write-Host "Duration: $DurationMinutes minutes per scenario" -ForegroundColor Cyan
Write-Host "Pre-scenario delay: $PreScenarioDelaySeconds seconds (time to prepare manual workload)" -ForegroundColor Cyan
Write-Host "Output: $OutputDir" -ForegroundColor Cyan
Write-Host ''

# --- Helper function -------------------------------------------------------

function Invoke-Scenario {
  param(
    [string]$Scenario,
    [string]$Description,
    [string]$ManualInstruction,
    [string]$ExtraArgs = ''
  )

  Write-Host "=== Scenario $Scenario - $Description ===" -ForegroundColor Cyan
  Write-Host ''

  if ($ManualInstruction) {
    Write-Host ">>> PREPARE: $ManualInstruction" -ForegroundColor Yellow
    Write-Host ">>> Waiting $PreScenarioDelaySeconds seconds before starting..." -ForegroundColor Yellow
    Write-Host ''
    for ($i = $PreScenarioDelaySeconds; $i -gt 0; $i -= 5) {
      Write-Host "    Starting in $i seconds... (Ctrl+C to abort)" -ForegroundColor DarkGray
      Start-Sleep -Seconds ([Math]::Min(5, $i))
    }
    Write-Host ''
  }

  $label = "validation-$Scenario"
  $args = @(
    '-File', (Join-Path $scriptDir 'Start-Benchmark.ps1'),
    '-Tool', 'gentle-shell',
    '-Scenario', $Scenario,
    '-Run', '1',
    '-DurationMinutes', $DurationMinutes,
    '-Label', $label,
    '-Repo', $Repo,
    '-OutputDir', $OutputDir
  )
  if ($ExtraArgs) {
    $args += $ExtraArgs -split ' '
  }

  Write-Host "Starting scenario $Scenario..." -ForegroundColor Green
  & pwsh @args

  if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Scenario $Scenario failed with exit code $LASTEXITCODE" -ForegroundColor Red
    exit 1
  }

  Write-Host ''
  Write-Host "Scenario $Scenario completed." -ForegroundColor Green
  Write-Host ''
}

# --- Run scenarios ----------------------------------------------------------

try {
  # Scenario A - Idle (no manual action needed)
  Invoke-Scenario -Scenario 'A' -Description 'Idle right after start' -ManualInstruction ''

  # Scenario B - Active task (manual workload)
  Invoke-Scenario -Scenario 'B' -Description 'Active task' -ManualInstruction 'Read and edit files in D:\socialemperors NOW'

  # Scenario C - With subagent (manual subagent)
  Invoke-Scenario -Scenario 'C' -Description 'With ONE subagent active' -ManualInstruction 'Launch a Gentle Shell subagent NOW' -ExtraArgs '-NewProcessPattern gentle-shell\.mjs|pi-coding-agent'

  # --- Final report ---------------------------------------------------------
  Write-Host '=== Generating report ===' -ForegroundColor Cyan
  Write-Host ''

  & pwsh -File (Join-Path $scriptDir 'Compare-Benchmark.ps1') -OutputDir $OutputDir

  Write-Host ''
  Write-Host '=== Validation Complete ===' -ForegroundColor Green
  Write-Host ''
  Write-Host 'Next steps:' -ForegroundColor Yellow
  Write-Host '  1. Review the report above'
  Write-Host "  2. Check CSVs in: $OutputDir"
  Write-Host '  3. If validation looks good, run the full protocol (3 reps x 30 min)'

}
catch {
  Write-Host ''
  Write-Host "FATAL ERROR: $_" -ForegroundColor Red
  Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
  exit 1
}
