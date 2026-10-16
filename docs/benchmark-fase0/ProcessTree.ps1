#Requires -Version 5.1
<#
.SYNOPSIS
  Process-tree sampling helpers for the Fase-0 benchmark protocol.

.DESCRIPTION
  Implements the methodology corrections demanded by the plan
  (plan_agente_liviano_refutado.md, sections 5 and 7):

  - Records BOTH WorkingSet64 and PrivateMemorySize64 per sample
    (correction #3: WorkingSet alone mixes shareable pages).
  - Sums the process tree from one root PID, so MCP children and
    auxiliary node processes are included but foreign ones are not
    (corrections #4 and #5). Scenario C extends this with EXTRA roots:
    processes matching -NewProcessPattern created after -Since are unioned
    in, because gentle-shell subagents are sibling agent sessions, not
    descendants of the measured session.
  - Keeps a per-process attribution CSV with CommandLine, so every
    sampled PID can be identified later instead of assumed to be an MCP.

.NOTES
  Language of this artifact: English (repository-facing technical artifact).
#>

Set-StrictMode -Version 2.0

# Shell / launcher processes we are willing to skip while walking up from the
# agent process to the true user-visible root of the tool.
$script:ShellProcessNames = @(
  'cmd', 'powershell', 'pwsh', 'windowsterminal', 'wt', 'explorer',
  'conhost'
)

function Get-ProcTree {
  <#
    .SYNOPSIS
      Returns every PID in the tree rooted at RootId, including the root.
  #>
  [CmdletBinding()]
  [OutputType([int[]])]
  param(
    [Parameter(Mandatory = $true)]
    [int]$RootId
  )

  $all = Get-CimInstance Win32_Process
  $children = @{}
  foreach ($p in $all) {
    $parent = [int]$p.ParentProcessId
    if (-not $children.ContainsKey($parent)) {
      $children[$parent] = [System.Collections.Generic.List[int]]::new()
    }
    $children[$parent].Add([int]$p.ProcessId)
  }

  $result = [System.Collections.Generic.List[int]]::new()
  $seen = [System.Collections.Generic.HashSet[int]]::new()
  $queue = [System.Collections.Generic.Queue[int]]::new()
  $queue.Enqueue($RootId)
  while ($queue.Count -gt 0) {
    $id = $queue.Dequeue()
    if (-not $seen.Add($id)) { continue }
    $result.Add($id)
    if ($children.ContainsKey($id)) {
      foreach ($child in $children[$id]) { $queue.Enqueue($child) }
    }
  }
  return $result.ToArray()
}

function Find-ToolRoot {
  <#
    .SYNOPSIS
      Locates the root process of a tool by inspecting CommandLine.

    .DESCRIPTION
      opencode       : the process named 'opencode'.
      gentle-shell   : a node process running pi-coding-agent/.../cli.js, then
                       walk up ParentProcessId until the first ancestor that
                       is not a shell/launcher process AND plausibly belongs
                       to the tool (node, or CommandLine mentions
                       gentle-shell/pi-coding-agent/opencode). If no such
                       ancestor exists, the agent process itself is used.
      auto           : prefer opencode, fall back to gentle-shell.

    .OUTPUTS
      PSCustomObject with Process (the System.Diagnostics.Process), Tool,
      DetectedVia and RootReason. Returns $null when nothing matches.
  #>
  [CmdletBinding()]
  param(
    [ValidateSet('opencode', 'gentle-shell', 'auto')]
    [string]$Tool = 'auto'
  )

  $wanted = @()
  if ($Tool -eq 'opencode' -or $Tool -eq 'auto') { $wanted += 'opencode' }
  if ($Tool -eq 'gentle-shell' -or $Tool -eq 'auto') { $wanted += 'gentle-shell' }

  foreach ($candidate in $wanted) {
    if ($candidate -eq 'opencode') {
      $procs = Get-Process -Name 'opencode' -ErrorAction SilentlyContinue
      foreach ($p in $procs) {
        return [pscustomobject]@{
          Tool        = 'opencode'
          Process     = $p
          DetectedVia = "process name 'opencode' (pid $($p.Id))"
          RootReason  = 'direct process'
        }
      }
    }
    else {
      $wmi = Get-CimInstance Win32_Process -Filter "Name='node.exe' or Name='node'" |
        Where-Object { $_.CommandLine -match 'pi-coding-agent[\\/].*cli\.js' }
      foreach ($w in $wmi) {
        $proc = Get-Process -Id $w.ProcessId -ErrorAction SilentlyContinue
        if (-not $proc) { continue }
        # Walk up to the first ancestor that is not a shell/launcher.
        $current = $w
        $hops = 0
        while ($current -and $hops -lt 20) {
          $parentId = [int]$current.ParentProcessId
          if ($parentId -le 0 -or $parentId -eq $current.ProcessId) { break }
          $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$parentId" -ErrorAction SilentlyContinue
          if (-not $parent) { break }
          # Win32_Process.Name always carries .exe; compare normalized names.
          $parentBase = ($parent.Name -replace '\.exe$', '').ToLower()
          # Only accept an ancestor that plausibly belongs to the tool itself
          # (its node launcher). Otherwise a terminal-launched agent would
          # root at explorer.exe and sample every shell-launched app.
          $looksLikeTool = ($parentBase -eq 'node') -or ($parent.CommandLine -match 'gentle-shell|pi-coding-agent|opencode')
          if ((-not ($script:ShellProcessNames -contains $parentBase)) -and $looksLikeTool) {
            $rootProc = Get-Process -Id $parent.ProcessId -ErrorAction SilentlyContinue
            if ($rootProc) {
              return [pscustomobject]@{
                Tool        = 'gentle-shell'
                Process     = $rootProc
                DetectedVia = "node pid $($w.ProcessId) running pi-coding-agent/.../cli.js"
                RootReason  = "ascended to non-shell ancestor pid $($parent.ProcessId) ($($parent.Name))"
              }
            }
          }
          $current = $parent
          $hops++
        }
        # No non-shell ancestor found: fall back to the agent process itself.
        return [pscustomobject]@{
          Tool        = 'gentle-shell'
          Process     = $proc
          DetectedVia = "node pid $($w.ProcessId) running pi-coding-agent/.../cli.js"
          RootReason  = 'no tool ancestor found; using agent process itself'
        }
      }
    }
  }
  return $null
}

function Get-ProcTreeSet {
  <#
    .SYNOPSIS
      Returns the union of the trees rooted at each of RootIds (deduplicated).

    .DESCRIPTION
      Scenario C needs this: gentle-shell subagents are SIBLING agent
      sessions (their own launcher + cli.js pair), NOT descendants of the
      session that spawned them, so a single-root tree cannot see them.
      Verified live: a bulk-reader subagent spawned its own
      gentle-shell.mjs + pi-coding-agent pair as siblings of this session.
  #>
  [CmdletBinding()]
  [OutputType([int[]])]
  param(
    [Parameter(Mandatory = $true)]
    [int[]]$RootIds
  )

  $all = Get-CimInstance Win32_Process
  $children = @{}
  foreach ($p in $all) {
    $parent = [int]$p.ParentProcessId
    if (-not $children.ContainsKey($parent)) {
      $children[$parent] = [System.Collections.Generic.List[int]]::new()
    }
    $children[$parent].Add([int]$p.ProcessId)
  }

  $result = [System.Collections.Generic.List[int]]::new()
  $seen = [System.Collections.Generic.HashSet[int]]::new()
  $queue = [System.Collections.Generic.Queue[int]]::new()
  foreach ($r in $RootIds) { $queue.Enqueue([int]$r) }
  while ($queue.Count -gt 0) {
    $id = $queue.Dequeue()
    if (-not $seen.Add($id)) { continue }
    $result.Add($id)
    if ($children.ContainsKey($id)) {
      foreach ($child in $children[$id]) { $queue.Enqueue($child) }
    }
  }
  return $result.ToArray()
}

function Get-TreeSample {
  <#
    .SYNOPSIS
      Takes one sample of the tree rooted at RootId, plus any extra roots
      matched by NewProcessPattern (see that parameter's comment).

    .OUTPUTS
      PSCustomObject: Timestamp, RootPid, Procs, WS_MB, Private_MB, CPU_s
      plus a Details property with one row per process (Pid, Name, WS_MB,
      Private_MB, CommandLine).
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [int]$RootId,

    # Regex over CommandLine. Matching processes CREATED after $Since are
    # added as extra tree roots, so subagents spawned during the run are
    # captured even though they are sibling sessions.
    [string]$NewProcessPattern = '',

    # Regex over CommandLine matched against EVERY process at sample time,
    # regardless of age. Used when the unit of work is short-lived sibling
    # processes (e.g. scripted `opencode run` invocations driven by
    # Drive-AutomatedWorkload.ps1).
    [string]$AnyProcessPattern = '',

    [datetime]$Since = [datetime]::MinValue
  )

  # One WMI enumeration per sample feeds BOTH the sibling match and the
  # per-PID CommandLine map (avoids the N+1 per-process queries that
  # inflate the observer cost documented in the README).
  $wmiAll = @(Get-CimInstance Win32_Process)
  $cmdByPid = @{}
  foreach ($w in $wmiAll) { $cmdByPid[[int]$w.ProcessId] = $w.CommandLine }

  $rootIds = [System.Collections.Generic.List[int]]::new()
  # In pattern-only mode (NewProcessPattern without AnyProcessPattern), RootId is 0
  # and must NOT be added as a root: Get-ProcTreeSet with PID 0 would include
  # all system processes. Only add RootId when it's a real PID.
  if ($RootId -gt 0) {
    $rootIds.Add($RootId)
  }
  if ($NewProcessPattern -and $Since -ne [datetime]::MinValue) {
    $late = $wmiAll |
      Where-Object { $_.CommandLine -match $NewProcessPattern -and $_.CreationDate -gt $Since }
    foreach ($l in $late) { $rootIds.Add([int]$l.ProcessId) }
  }
  if ($AnyProcessPattern) {
    $anyMatch = $wmiAll | Where-Object { $_.CommandLine -match $AnyProcessPattern }
    foreach ($m in $anyMatch) { $rootIds.Add([int]$m.ProcessId) }
  }
  # If no roots found (e.g. pattern-only mode with no matches yet),
  # return empty sample instead of calling Get-ProcTreeSet with empty array
  if ($rootIds.Count -eq 0) {
    return [pscustomobject]@{
      Timestamp  = (Get-Date).ToString('s')
      RootPid    = $RootId
      ExtraRoots = 0
      Procs      = 0
      WS_MB      = 0
      Private_MB = 0
      CPU_s      = 0
      Details    = @()
    }
  }
  $tree = Get-ProcTreeSet -RootIds $rootIds.ToArray()
  # Filter out system processes (PID < 100) when using pattern-only mode
  # to avoid including System, Registry, smss, etc.
  if ($AnyProcessPattern -or $NewProcessPattern) {
    $tree = @($tree | Where-Object { $_ -ge 100 })
  }
  $procs = Get-Process -Id $tree -ErrorAction SilentlyContinue

  $details = foreach ($p in $procs) {
    $cmd = ''
    if ($cmdByPid.ContainsKey($p.Id)) { $cmd = $cmdByPid[$p.Id] }
    if ($cmd -and $cmd.Length -gt 500) { $cmd = $cmd.Substring(0, 500) + '...' }
    [pscustomobject]@{
      Pid        = $p.Id
      Name       = $p.ProcessName
      WS_MB      = [math]::Round($p.WorkingSet64 / 1MB, 1)
      Private_MB = [math]::Round($p.PrivateMemorySize64 / 1MB, 1)
      CommandLine = $cmd
    }
  }

  $wsSum = 0; $privSum = 0; $cpuSum = 0.0
  if ($procs) {
    $wsSum = ($procs | Measure-Object WorkingSet64 -Sum).Sum
    $privSum = ($procs | Measure-Object PrivateMemorySize64 -Sum).Sum
    $cpuSum = ($procs | Measure-Object CPU -Sum).Sum
  }

  return [pscustomobject]@{
    Timestamp  = (Get-Date).ToString('s')
    RootPid    = $RootId
    ExtraRoots = ($rootIds.Count - 1)
    Procs      = @($procs).Count
    WS_MB      = [math]::Round($wsSum / 1MB, 1)
    Private_MB = [math]::Round($privSum / 1MB, 1)
    CPU_s      = [math]::Round($cpuSum, 1)
    Details    = @($details)
  }
}

function Save-TreeSample {
  <#
    .SYNOPSIS
      Samples the tree once and appends to the scenario CSVs.

    .DESCRIPTION
      Writes/creates two CSVs in OutputDir:

      samples_<tool>_<scenario>_run<run>.csv
        One row per sample: tree totals (the input for growth slopes).
      processes_<tool>_<scenario>_run<run>.csv
        One row per DISTINCT pid ever seen: attribution (fixes "we assumed
        the ~42-86 MB node processes were MCPs").

    .OUTPUTS
      The sample object from Get-TreeSample (so callers can log it live).
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [int]$RootId,

    [Parameter(Mandatory = $true)]
    [string]$Tool,

    [Parameter(Mandatory = $true)]
    [ValidateSet('A', 'B', 'C', 'D')]
    [string]$Scenario,

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 99)]
    [int]$Run,

    [Parameter(Mandatory = $true)]
    [string]$OutputDir,

    [string]$Label = '',

    # Suffix appended to the CSV file names (used to keep smoke-test data
    # out of the real run files).
    [string]$FileSuffix = '',

    # Passed through to Get-TreeSample (scenario C sibling capture).
    [string]$NewProcessPattern = '',

    # Passed through to Get-TreeSample (short-lived sibling capture).
    [string]$AnyProcessPattern = '',

    [datetime]$Since = [datetime]::MinValue
  )

  if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
  }

  $sample = Get-TreeSample -RootId $RootId -NewProcessPattern $NewProcessPattern -Since $Since -AnyProcessPattern $AnyProcessPattern
  $now = (Get-Date).ToString('s')

  $samplesCsv = Join-Path $OutputDir ("samples_{0}_{1}_run{2}{3}.csv" -f $Tool, $Scenario, $Run, $FileSuffix)
  $sampleRow = [pscustomobject]@{
    Timestamp  = $sample.Timestamp
    Tool       = $Tool
    Scenario   = $Scenario
    Run        = $Run
    Label      = $Label
    RootPid    = $RootId
    ExtraRoots = $sample.ExtraRoots
    Procs      = $sample.Procs
    WS_MB      = $sample.WS_MB
    Private_MB = $sample.Private_MB
    CPU_s      = $sample.CPU_s
  }
  $sampleRow | Export-Csv -LiteralPath $samplesCsv -Append -NoTypeInformation -Force

  $procsCsv = Join-Path $OutputDir ("processes_{0}_{1}_run{2}{3}.csv" -f $Tool, $Scenario, $Run, $FileSuffix)
  $byPid = @{}
  if (Test-Path -LiteralPath $procsCsv) {
    foreach ($row in @(Import-Csv -LiteralPath $procsCsv)) {
      $byPid[[int]$row.Pid] = $row
    }
  }
  foreach ($d in $sample.Details) {
    # NB: do NOT name this $pid: PowerShell's automatic $PID is read-only.
    $processId = [int]$d.Pid
    if ($byPid.ContainsKey($processId)) {
      # Known pid: refresh last sighting, sizes AND identity fields (PID
      # reuse on Windows otherwise keeps the dead process' Name/CommandLine).
      $row = $byPid[$processId]
      $row.LastSeen = $now
      $row.WS_MB_Last = $d.WS_MB
      $row.Private_MB_Last = $d.Private_MB
      $row.Name = $d.Name
      $row.CommandLine = $d.CommandLine
    }
    else {
      $byPid[$processId] = [pscustomobject]@{
        Tool            = $Tool
        Scenario        = $Scenario
        Run             = $Run
        Pid             = $d.Pid
        Name            = $d.Name
        FirstSeen       = $now
        LastSeen        = $now
        WS_MB_Last      = $d.WS_MB
        Private_MB_Last = $d.Private_MB
        CommandLine     = $d.CommandLine
      }
    }
  }
  $byPid.Values | Sort-Object { [int]$_.Pid } |
    Export-Csv -LiteralPath $procsCsv -NoTypeInformation -Force

  return $sample
}
