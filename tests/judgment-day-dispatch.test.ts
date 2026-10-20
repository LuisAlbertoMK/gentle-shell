import assert from "node:assert/strict";
import test from "node:test";

import { hasJudgmentDayFixAgentReference, rejectInvalidJudgmentDayFixDispatch } from "../lib/judgment-day-dispatch.ts";
import { canonicalHash } from "../lib/review-transaction.ts";

const FROZEN_ROW = {
	id: "JD-RISK-1",
	lens: "judgment-day",
	location: "lib/judgment-day-dispatch.ts:1",
	severity: "BLOCKER",
	status_at_freeze: "open",
	evidence_class: "tool-observed",
	evidence_claim: "the extraction kept the dispatch decision unchanged",
};

const EDIT_SURFACES = ["## Allowed edit surfaces", "lib/judgment-day-dispatch.ts"];

function canonicalDispatch(overrides: { row?: Record<string, unknown>; hash?: string; editSurfaces?: boolean } = {}): string {
	const row = overrides.row ?? FROZEN_ROW;
	const hash = overrides.hash ?? canonicalHash([row]);
	return [
		"## Judgment Day activation",
		"User explicitly requested Judgment Day.",
		"## Exact authorized severe IDs",
		"- `JD-RISK-1`",
		"## Judgment Day correction batch",
		"Round: 1 of 2.",
		`Frozen ledger SHA-256: \`${hash}\``,
		"## Exact frozen finding rows",
		JSON.stringify(row),
		...(overrides.editSurfaces === false ? [] : EDIT_SURFACES),
	].join("\n");
}

test("hasJudgmentDayFixAgentReference accepts both agent shapes", () => {
	assert.equal(hasJudgmentDayFixAgentReference({ agent: "jd-fix-agent" }), true);
	assert.equal(hasJudgmentDayFixAgentReference({ agent: ["review-risk", "jd-fix-agent"] }), true);
	assert.equal(hasJudgmentDayFixAgentReference({ agents: "jd-fix-agent" }), true);
	assert.equal(hasJudgmentDayFixAgentReference({ agents: ["jd-fix-agent"] }), true);
	assert.equal(hasJudgmentDayFixAgentReference({ agent: "review-risk" }), false);
	assert.equal(hasJudgmentDayFixAgentReference({ agent: ["review-risk"] }), false);
	assert.equal(hasJudgmentDayFixAgentReference({}), false);
});

test("non Judgment Day dispatches stay untouched", () => {
	assert.equal(rejectInvalidJudgmentDayFixDispatch({ agent: "review-risk", task: "review this" }), undefined);
	assert.equal(rejectInvalidJudgmentDayFixDispatch("jd-fix-agent"), undefined);
	assert.equal(rejectInvalidJudgmentDayFixDispatch(undefined), undefined);
	assert.equal(rejectInvalidJudgmentDayFixDispatch([]), undefined);
});

test("a canonical bounded dispatch is admitted", () => {
	assert.equal(rejectInvalidJudgmentDayFixDispatch({ agent: "jd-fix-agent", task: canonicalDispatch() }), undefined);
});

test("the imperative agents form is rejected even with canonical text", () => {
	const result = rejectInvalidJudgmentDayFixDispatch({ agents: ["jd-fix-agent"], task: canonicalDispatch() });
	assert.equal(result?.block, true);
	assert.match(result?.reason ?? "", /^Judgment Day fix dispatch requires exactly one/);
});

test("missing canonical text is rejected", () => {
	for (const task of ["", "do the fixes", "## Judgment Day activation", canonicalDispatch({ editSurfaces: false })]) {
		const result = rejectInvalidJudgmentDayFixDispatch({ agent: "jd-fix-agent", task });
		assert.equal(result?.block, true, `expected a block for: ${JSON.stringify(task.slice(0, 40))}`);
	}
});

test("a corrupted frozen ledger hash is rejected", () => {
	const result = rejectInvalidJudgmentDayFixDispatch({
		agent: "jd-fix-agent",
		task: canonicalDispatch({ hash: "0".repeat(64) }),
	});
	assert.equal(result?.block, true);
});

test("a row whose severity is not BLOCKER or CRITICAL is rejected", () => {
	const result = rejectInvalidJudgmentDayFixDispatch({
		agent: "jd-fix-agent",
		task: canonicalDispatch({ row: { ...FROZEN_ROW, severity: "SUGGESTION" } }),
	});
	assert.equal(result?.block, true);
});

test("a row that is not open at freeze is rejected", () => {
	const result = rejectInvalidJudgmentDayFixDispatch({
		agent: "jd-fix-agent",
		task: canonicalDispatch({ row: { ...FROZEN_ROW, status_at_freeze: "closed" } }),
	});
	assert.equal(result?.block, true);
});

test("the rejection reason names every required section", () => {
	const result = rejectInvalidJudgmentDayFixDispatch({ agent: "jd-fix-agent", task: "no sections" });
	for (const section of [
		"## Judgment Day activation",
		"## Exact authorized severe IDs",
		"## Judgment Day correction batch",
		"## Exact frozen finding rows",
		"## Allowed edit surfaces",
	]) {
		assert.match(result?.reason ?? "", new RegExp(section.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
	}
});
