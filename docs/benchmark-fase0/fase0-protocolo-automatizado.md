# Feature: Fase 0 — protocolo benchmark automatizado con opencode

> Source: `plan_agente_liviano_refutado.md` section 7 (protocolo reproducible).
> User decision (2026-10-12): automate the full protocol using opencode headless
> (option C from the user's choice). Gentle-shell measurement stays manual.

## Context

- The bench harness (`bench/`) is complete and smoke-tested (Fase-0 feature closed).
- `Drive-AutomatedWorkload.ps1` already runs the 5-task workload via `opencode run`
  (headless, reproducible, no human typing needed).
- `Start-Benchmark.ps1` supports pattern-only sampling (sibling process capture).
- opencode 1.18.35 installed at `C:/Users/PC/.gentle-ai/bin`, never measured.
- The full protocol (7.1): scenarios A/B/C/D × 3 reps × 30 min, same repo, same prompts.
- Scenarios C (subagent) and D (after 30 min) need adaptation for headless opencode:
  - C: run a second `opencode run` concurrently as "subagent" workload
  - D: sample the tail of a 30-min B run (already covered by B duration)

## Tasks

- [x] T1. `bench/Run-Protocol-Automated.ps1` — orchestrator: runs scenarios A, B, C
      × 3 reps × 30 min for opencode headless, calling Start-Benchmark.ps1 with
      pattern-only mode + Drive-AutomatedWorkload.ps1 as workload driver.
      (Implemented, commit ef68820.)
- [x] T2. Dry-run validation of the orchestrator (short duration, verify CSV/flow).
      (Done 2026-10-13: dry-run 2 scenarios × 1 rep × 2 min + 10-min trial
      B/C × 11 samples. See evidence below.)
- [x] T3. Execute the full protocol (3 reps × 3 scenarios × 30 min ≈ 4.5 hours).
      DONE 2026-10-13/14: 6/6 × 121 samples, `protocol-opencode-full/`.
      Overnight gap (machine asleep) between rep 3 and rep 4: reps 1-3 day 1,
      reps 4-6 day 2.
- [x] T4. Generate final report with Compare-Benchmark.ps1 + decision table.
      Report `benchmark_report_20261014_203452.md`. HONEST VERDICT:
      - Day 1 (B1/B2/C1): tight spreads, B median ~2.65 GB (2 reps agree
        within 2%), slope ~0-8 MB/min. C1-B ≈ 0: one concurrent
        `opencode run` adds nothing measurable vs noise.
      - Day 2 (B3/C2/C3): ~2x higher. Attribution shows FOUR heavy bare
        opencode procs (1.2-1.9 GB each, no `run -m`) coexisting: foreign
        agent sessions on the box violated plan 7.1 fairness. EXCLUDED.
      - No scenario A => formal plan-7.4 verdict: insufficient data.
      - Open minor: only B1 carries `|self:agent-session`; later samplers
        (same parent chain) don't. Guard likely hit transient CIM
        failures (fail-open warning path). Totals unaffected (pattern
        includes everything regardless of stamp).
      - RECOMMENDATION: re-run B/C × 3 from a neutral terminal with the
        box cleaned + add scenario A; or accept day-1 B≈2.65 GB as the
        "active" answer. No rewrite decision can be made on this data.

## Constraints / decisions

- opencode headless only; no gentle-shell automation (user decision).
- Workload: `Drive-AutomatedWorkload.ps1` (5 tasks, same model, revertible).
- Sampling: `Start-Benchmark.ps1 -Tool opencode -NewProcessPattern` (sibling capture).
- Repo: `D:\socialemperors` (exists, protocol default).
- Output: `bench/results/protocol-opencode/`.
- Scenarios:
  - A (idle): start opencode, sample 30 min, no workload.
  - B (active): start opencode, run workload driver, sample concurrently.
  - C (concurrent "subagent"): start opencode, run workload driver + second
    opencode run in parallel, sample concurrently.
  - D: covered by B's 30-min duration (tail samples show growth).
- Model: `opencode/muse-spark-1.3-contributor-free` (driver default).

## Evidence

- **Dry-run successful (2026-10-13)**: 2 scenarios (B, C) × 1 rep × 2 min.
  - Sampler exit 0, CSVs generated with real opencode processes.
  - Scenario B: 10 procs, WS 843.8 MB, private 950.1 MB, CPU 15.3 s.
  - Tree includes: opencode.exe (792 MB private), engram MCP (20.9 MB), node/conhost support.
  - Bugs found and fixed: `$root.Process.Id` null in pattern-only mode, `\\$_` syntax error in Get-TreeSample, array vacío en Get-TreeSample.
- Workload driver timeout in dry-run (expected: 5 tasks > 2 min sampler).
- Compare-Benchmark.ps1 error in dry-run (expected: looks for `samples_*.csv`, dry-run generates `*_smoke.csv`).
- **10-min trial B/C (2026-10-13 17:40-18:00, 11 samples x 60 s):**
  - Sampler logs `sampler_run1-B.log` / `sampler_run1-C.log`, report
    `benchmark_report_20261013_180030.md`.
  - Samples oscillate between ~969 MB (10 procs, opencode run alive) and
    ~42 MB (2 procs, between tasks): pattern-only mode cannot measure
    short-lived `opencode run` procs at 60 s intervals. Medians/slopes
    meaningless (slope -66/-138 MB/min, CPU negative).
  - Deviation stamped: gentle-shell (pid 13808) was running concurrently;
    tree metrics valid, CPU carries noise.
  - Workload driver completed all 5 steps OK (`workload_run1-B.log`).
- **Plus untracked `bench/Run-Validation.ps1` (2026-10-13):** manual
  gentle-shell validation runner (A/B/C x 10 min, non-interactive waits
  instead of Read-Host) + final Compare-Benchmark report. Not yet committed.
- **Sampling fix (2026-10-13, commits TBD):** 10-min trial post-mortem found
  THREE compounding flaws, all fixed:
  1. Burst vs window: driver ran one ~2.5 min pass per 10-30 min window
     (hit/miss aliasing at 60 s vs ~15-40 s proc lifetimes). Fix:
     `Drive-AutomatedWorkload.ps1 -DurationMinutes` loops passes till the
     window expires; orchestrator passes DurationMinutes+1, interval 15 s.
  2. Wrong repo: driver ran `opencode run` with the orchestrator's CWD, so
     prompts measured D:\shell-MK and probes/cleanup hit the wrong path.
     Fix: Push-Location $Repo around every step.
  3. Self-contamination: pattern-only mode silently includes the invoker's
     own tree when launched from an agent session (24 procs/2650 MB vs
     10/950 MB clean). Fix: ancestor-walk guard stamps `|self:agent-session`
     + warning; clean runs need a neutral terminal.
  - Report now shows Hit rate % + Hit median priv MB and refuses decisions
    below 50% hits; pattern-mode CPU caveat documented (cumulative counters
    over a changing set can go negative).
  - Re-validation: orchestrator -DryRun (driver durationMin=3 logged, 5/5
    steps exit 0, sampler 2/2 stable hits) + sampler-only DryRun proving the
    self-stamp fires with `|self:agent-session` in the CSV Label.
- **Sustained-loop validation (2026-10-13 18:39-18:46): single B, run 2,
  5 min x 15 s = 21/21 samples, exit 0.** Driver did 3 full passes (all
  steps exit 0) against the RIGHT repo (tails show socialemperors content);
  cleanup removed probes, no strays. Sampler: procs 14-25, priv
  1799.9/2709/2787.8 min/med/peak (tight, no oscillation), slope -3.8
  MB/min, growth +1.7%. Label `validation-loop|self:agent-session`
  (run launched from inside opencode: honest stamp, numbers carry the
  constant self-offset). Report table now shows Procs min-max + Priv
  min/med/peak so the old garbage rows (42/47/969.5) condemn themselves.
  T3 UNBLOCKED: methodology proven; full protocol still pending (~4.5 h,
  preferably launched from a neutral terminal for clean numbers).
