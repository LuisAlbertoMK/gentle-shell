# Feature: Fase 0 — scripts de benchmark ejecutables

> Source: `plan_agente_liviano_refutado.md` sections 7 and 8.
> Goal: turn the paper protocol into runnable PowerShell artifacts so the
> RAM/CPU comparison (opencode vs Gentle Shell) can be executed without
> manual PID hunting or spreadsheet work.

## Context

- The plan's own verdict: measure properly and try cheap levers before any
  Rust rewrite. Section 7 defines the protocol; section 8 the cheap levers.
- The repo contains only the plan `.md`. No code, no git history yet.
- Measured facts at feature start: PowerShell 7.6.6 on Windows, Node v24.21.0,
  `D:\socialemperors` exists (suggested workload repo), no tool running.

## Tasks

- [x] T1. `bench/ProcessTree.ps1` — tree sampler module: `Get-ProcTree`,
      `Find-ToolRoot` (auto-detect opencode / gentle-shell via CommandLine),
      `Save-TreeSample` (per-sample totals + per-process attribution CSV).
- [x] T2. `bench/Start-Benchmark.ps1` — scenario runner: scenarios A/B/C/D,
      3 runs, interval/duration params, protocol precondition checks, `-DryRun`.
- [x] T3. `bench/Compare-Benchmark.ps1` — report: idle median private RAM,
      growth slope (MB/min linear regression), idle CPU %, per-subagent delta,
      section 7.4 decision table in markdown.
- [x] T4. `bench/README.md` — protocol, 5-task workload script, root detection,
      heap-cap alternative (8.3), limits. English (technical artifact).
- [x] T5. Smoke test: dry-run sampling against a live node PID, CSV validation,
      `Compare-Benchmark` against a synthetic CSV. Observed evidence below.

## Constraints / decisions

- Artifacts are technical: all code, comments, help text and README in English.
  Chat with the user stays in Spanish.
- Default workload repo: `D:\socialemperors` (exists; plan's own suggestion).
- Target PowerShell 7 (7.6.6 present), keep 5.1-compatible syntax.
- Metrics per protocol: BOTH `WorkingSet64` and `PrivateMemorySize64`
  (correction #3), tree totals from a single root PID (#4), per-process
  `CommandLine` capture for attribution (#5).
- Scenario C (with subagent) is sampled while the human runs the subagent;
  the script cannot spawn tool subagents itself. Documented in README.
- Repo has no git: initialize it so work-unit commits (ODD step 6) are possible.
  No remote, no push.

## Evidence

- Commits: 427bb47 (T1), f98a248 (T2), c33430a (T3), fc4e0e4 (T4),
  6c43771 (T5). Git repo initialized during feature (was absent).
- Dry run 2026-10-09T13:45 against live tree root 12600 (gentle-shell launcher):
  4 procs, 388.4 MB private stable across 2 samples; attribution CSV captured
  the real tree: launcher 23 MB, cli.js 295.4 MB, conhost 1.1 MB and
  windows-session-transport.ps1 68.8 MB — a naive "sum all node" would miss
  the PowerShell transport.
- Synthetic Compare run: slope/growth/CPU math verified; `*_smoke.csv`
  correctly excluded.
- Bugs found by smoke and fixed: (a) CPU % was 60x inflated (seconds delta
  divided by minutes); (b) gentle-shell detection regex required
  `pi-coding-agent[\/]cli\.js` but the real Windows path is
  `pi-coding-agent\dist\bundle\cli.js`.
- Guard test: running with `-Tool opencode` while gentle-shell is live fails
  closed with the protocol precondition message.
- **Live mini-run B (2026-10-09T14:00-14:04, 13 samples x 20 s):**
  gentle-shell scenario B, read-only workload driven during sampling:
  median 464.3 MB private (final 463.8, flat), WS median 419.7 MB,
  slope 1.563 MB/min, avg CPU 13.95% of one core (includes sampler
  observer cost). First REAL data point; proves capture -> CSV -> report
  end to end on production scripts.
- Bugs found during live run and fixed: `$files.Count` / single-object
  arrays crash under StrictMode with one run CSV; decision table compared
  active-task CPU (B) against the idle threshold (now tagged with basis,
  verdict only from A idle).
- **Live scenario C (2026-10-09T14:58-15:02, 13 samples x 20 s, sibling
  capture ON):** parent-only baseline inside the run (sample 1: 4 procs,
  467.3 MB) vs with one bulk-reader subagent (samples 2-13: 6 procs,
  median 570.0 MB, peak 572.2 MB). **First real per-subagent cost:
  ~+105 MB private** (C median minus B-run-2 baseline 465.2). Subagent
  window CPU 2.71% of one core (model-wait dominated read task).
- **Crash found by the live C run:** attribution loop used `$pid`, which
  collides with PowerShell's read-only automatic `$PID`; sample 1 landed,
  processes CSV write threw. Renamed to `$processId`. Three audit rounds by
  a bulk-reader subagent drove further fixes: `-Tool auto` used to
  self-throw in preconditioning (now resolves first); Find-ToolRoot accepts
  only tool-looking ancestors (no more rooting at explorer.exe); observer
  cost cut (one WMI enumeration per sample instead of N+1; HashSet dedup);
  attribution refreshes Name/CommandLine too (PID reuse); dup-check covers
  both CSVs; doc claims corrected (multi-root header, tool-look walk-up,
  implemented PeakPriv_MB, honest second-window wording, CPU-churn caveat).
- Final validation: syntax OK on all three scripts; C attribution CSV shows
  refreshed LastSeen; post-fix DryRun 2/2 samples OK.
