# Project audit and optimization pass

Branch: `chore/project-audit-optimizations` (from `upstream/main` at `145485c85`). `main` is untouched; nothing is pushed.

## Objective

Decompose the project by area, audit each area for gaps, performance, safety and refactor
opportunities, and rank what is worth changing. Every candidate must be proven still-open before
any code is written, because two previously "free" issues turned out to be already fixed on `main`
(see Corrections).

## Method

1. Area map by measured size rather than by directory name.
2. Structural reading through CodeGraph (symbols, callers, blast radius) instead of ad-hoc grep.
3. For each candidate: verify the claim against the current `main` source, then verify it is not
   already delivered by a **merged** commit (`git log -S<symbol>`), not only by an open PR.
4. Rank by (verified open) x (measurable) x (risk).

## Area map

| Area | Files | Lines |
| --- | ---: | ---: |
| `extensions/` (the Pi-facing surface: shell UI, agents, history, skills) | 27 | 23,312 |
| `lib/` (engine: native review, safety, installers, git, views) | 187 | 48,820 |
| `runtime/` (generated runtime modules) | 16 | 8,324 |
| `scripts/` (gates, perf harness, generators) | 29 | 11,705 |
| `tests/` | 461 | — |
| `docs/` | 38 | — |
| `odd/` (task records) | 147 | — |

Counts are non-blank lines (`Measure-Object -Line` semantics), so they run a few percent under raw
line counts: `extensions/gentle-ai.ts` is 10,827 raw lines, not 10,258.

Largest single files, which are the real review risk: `extensions/gentle-ai.ts` (10,258),
`lib/review-integration-v2.ts` (2,798), `extensions/gentle-shell.ts` (2,549),
`lib/native-review-cli.ts` (2,534), `extensions/gentle-agents.ts` (2,354).

## Corrections (verified against `main`, not assumed)

These two were proposed as our next contribution and are **already fixed**. Nobody should redo them.

- **#990 `candidate owner preparation fails when a PowerShell spawn exceeds its 5 s timeout` is
  FIXED.** The issue cites `timeout: 5000` at `lib/review-candidate-view-owner.ts:39,48,58,154,178`.
  Current `main` has `WINDOWS_SYSTEM_PROBE_TIMEOUT_MS = 15_000` (line 35), a `120_000` ceiling
  (line 36), an override through `GENTLE_PI_CANDIDATE_WINDOWS_PROBE_TIMEOUT_MS` (line 37), a
  resolver with validation (lines 39-46), a bounded one-shot retry for `ETIMEDOUT`/`EAGAIN`/`EBUSY`
  (`TRANSIENT_WINDOWS_PROBE_CODES` line 48, `withWindowsSystemProbeRetry` lines 50-57), and every
  probe (`whoami` line 68, PowerShell line 77, `icacls` line 87) already passes
  `resolveWindowsSystemProbeTimeoutMs()` plus `windowsHide: true`.
- **#967 `hide remaining internal CodeGraph and review process launches` is FIXED.** All six files
  named by the issue carry `windowsHide` on their internal launches, added by merged commit
  `dcedd0747 "fix(windows): hide internal process launches"`. That commit is the issue's own GREEN
  candidate, so the issue was delivered and simply left open. Verified with
  `git log -S"windowsHide"` per file: `dcedd0747` is the single origin in
  `lib/review-publication-gate.ts` (11 sites / 11 flags), `lib/review-transaction.ts`,
  `lib/review-snapshot.ts` and `lib/review-repository.ts`.

Methodology lesson, recorded so it is not repeated: an "is this issue free?" check that only scans
**open** PRs will call an already-merged fix free. Cross-reference `git log -S<symbol>` and merged
commits before proposing work.

## Findings

### #994 render pulse CPU — partially stale, residual verified open

- The issue states `main` retains `PETAL_PULSE_MS = 160`. That symbol does not exist. The pulse is
  `SHELL_PULSE_MS = 80` (`lib/shell-prompt.ts:29`), so the quality cadence is 12.5 renders/second,
  twice the frequency the issue reports.
- The cadence is already policy-gated in `startPulse()` (`extensions/gentle-shell.ts:564-571`):
  `potato` arms no pulse at all, `performance` uses 1000 ms, `quality` uses the 80 ms default. The
  interval is `unref()`ed.
- `sessionCost()` (`extensions/gentle-shell.ts:267`) walks every session entry, but it is no longer
  called per frame: `sessionStats()` (lines 286-305) memoizes it in a `WeakMap` keyed by the
  session manager with `sessionId`/`leafId`/`entryCount`/`model`/`contextWindow` invalidation, and
  `buildShellBarModel` (line 307) consumes the cached value.
- Residual, verified open: each pulse tick still forces a full TUI render (`requestRender()`), and
  the sidebar rails compute their change digest as
  `() => JSON.stringify([footerModel(), tracker.model, visualSettings, cardStyle()])`
  (`extensions/gentle-shell.ts:1963` and `:1972`), where `footerModel()` rebuilds the whole bar
  model (status map sort plus a fresh object) on every evaluation, next to the separate model built
  for the render itself.

### Structural

- `extensions/gentle-ai.ts` at 10,258 lines is larger than the entire `runtime/` area and is the
  single biggest refactor and review-risk candidate in the tree.
- The render hot path is well instrumented already, which makes it the cheapest area to change
  safely: `scripts/render-cache-performance.mjs` plus `scripts/render-cache-performance-worker.mjs`
  provide a paired AB/BA multi-replica harness with enforced output equivalence, and
  `docs/render-cache-performance.md` documents how to read it. `node_modules` already contains
  `@earendil-works/pi-coding-agent`, so the harness has its `--pi-root`.

## Measurement instrument

The repo's own paired harness is the way to prove a render change:

```bash
node scripts/render-cache-performance.mjs \
  --baseline-root=<before-worktree> \
  --candidate-root=<after-worktree> \
  --pi-root=<installed-pi-package> \
  --output=<path outside the source/harness/host roots>
```

It requires two worktrees of the same commit and refuses output paths inside the source roots; the
full matrix is 100/1,000/5,000 tools x 100/160 columns x float/neon x many actions with four fresh
process replicas, which is far too slow for an interactive loop. Use small `--counts`, `--widths`,
`--styles`, `--samples` and `--repetitions` for a smoke run and keep the full matrix for the real
claim.

Status: the harness is **not runnable here**. It asserts Pi exactly `1.1.0`
(`render-cache-performance-worker.mjs:11-12`) while the installed host is Pi `1.2.0` / pi-tui `1.2.0`,
so it fails closed by design; `--pi-root` also has to be a Pi install root carrying `dist/` and a
`node_modules/@earendil-works/` with pi-tui, pi-ai, pi-agent-core and jiti. On top of that,
`tests/render-cache-performance.test.ts:39` fails on this host with `EPERM` when it creates a symlink.
Measuring a render change therefore needs the harness revived (pin Pi 1.1.0 in a scratch root) and an
otherwise idle machine; the timing numbers are unusable next to live agent sessions.

## Ranked backlog (verified open)

1. **Render pulse residual (#994)** — reuse the per-frame bar model between the render and the
   sidebar digest, and skip a pulse render when the visible frame cannot change. Measurable with the
   paired harness. Highest value, needs the harness for a defensible claim.
2. **`extensions/gentle-ai.ts` decomposition** — extract cohesive units, keeping behaviour identical
   and gates green. Large, must be sliced to stay reviewable. Two slices delivered.
   `d0ba917cf` moved the Judgment Day fix-dispatch authorization to
   `lib/judgment-day-dispatch.ts` (164 lines out of the monolith) and added a 9-case suite, because
   that authorization had no direct coverage at all. `229b51d21` moved the guard vocabulary and the
   YOLO reversibility analysis to `lib/runtime-guardrails-analysis.ts` (113 lines), where the
   existing seven guard suites already pinned the behaviour. Coverage is uneven across the
   monolith: guard and YOLO are well covered, the Judgment Day dispatch was not.
3. **`sessionCost`/`sessionStats` hardening** — extend the memoization fingerprint only if a real
   uncached path is found; today the cache looks correct and should be left alone.

## Limits

- The full `tests/*.test.ts` suite does not terminate on this Windows host (>40 min) and
  `tests/review-candidate-view.test.ts` hangs on its own; both are pre-existing and unrelated to
  this branch. Verification here relies on targeted suites plus the repo's gates.
- No claim in this document is measured yet: everything above is source-verified, and only the first
  decomposition slice is delivered. The render residual stays unmeasured because the paired harness
  cannot run on this host (see Status above).
