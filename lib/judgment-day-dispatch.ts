import { allowedEditSurfaces as hasTaskScopedAllowedEditSurfaces } from "./bounded-writer-admission.ts";
import { isRecord } from "./record-guard.ts";
import { canonicalHash } from "./review-transaction.ts";

const JUDGMENT_DAY_FIX_AGENT_NAME = "jd-fix-agent";
const JUDGMENT_DAY_ACTIVATION_HEADING = "## Judgment Day activation";
const JUDGMENT_DAY_ACTIVATION_SENTENCE = "User explicitly requested Judgment Day.";
const JUDGMENT_DAY_AUTHORIZED_SEVERE_IDS_HEADING = "## Exact authorized severe IDs";
const JUDGMENT_DAY_CORRECTION_BATCH_HEADING = "## Judgment Day correction batch";
const JUDGMENT_DAY_FROZEN_FINDING_ROWS_HEADING = "## Exact frozen finding rows";

export function hasJudgmentDayFixAgentReference(input: Record<string, unknown>): boolean {
	return input.agent === JUDGMENT_DAY_FIX_AGENT_NAME ||
		(Array.isArray(input.agent) && input.agent.includes(JUDGMENT_DAY_FIX_AGENT_NAME)) ||
		input.agents === JUDGMENT_DAY_FIX_AGENT_NAME ||
		(Array.isArray(input.agents) && input.agents.includes(JUDGMENT_DAY_FIX_AGENT_NAME));
}

function canonicalJudgmentDaySectionBodies(value: unknown, heading: string): string[][] {
	if (typeof value !== "string") return [];
	const headingPattern = new RegExp(`^${heading.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}$`, "gm");
	return [...value.matchAll(headingPattern)].map((match) => {
		const body = value.slice((match.index ?? 0) + match[0].length);
		const nextHeading = body.search(/^ {0,3}#{1,6} /m);
		return body
			.slice(0, nextHeading === -1 ? undefined : nextHeading)
			.split(/\r?\n/)
			.filter((line) => line.length > 0);
	});
}

const JUDGMENT_DAY_SEVERE_ID_ENTRY = /^- `(JD-[A-Z][A-Z0-9]*-\d+)`$/;
const JUDGMENT_DAY_CORRECTION_ROUND_ENTRY = /^Round: [12] of 2\.$/;
const JUDGMENT_DAY_FROZEN_LEDGER_SHA256_ENTRY = /^Frozen ledger SHA-256: `([0-9a-f]{64})`$/;
const JUDGMENT_DAY_FROZEN_ROW_FIELDS = [
	"id",
	"lens",
	"location",
	"severity",
	"status_at_freeze",
	"evidence_class",
	"evidence_claim",
] as const;
const JUDGMENT_DAY_FIX_SECTION_HEADINGS = [
	JUDGMENT_DAY_ACTIVATION_HEADING,
	JUDGMENT_DAY_AUTHORIZED_SEVERE_IDS_HEADING,
	JUDGMENT_DAY_CORRECTION_BATCH_HEADING,
	JUDGMENT_DAY_FROZEN_FINDING_ROWS_HEADING,
	"## Allowed edit surfaces",
] as const;

function canonicalJudgmentDaySevereIds(entries: readonly string[]): string[] | undefined {
	const ids = entries.map((entry) => entry.match(JUDGMENT_DAY_SEVERE_ID_ENTRY)?.[1]);
	return ids.length > 0 && ids.every((id): id is string => id !== undefined) && new Set(ids).size === ids.length
		? ids
		: undefined;
}

function canonicalJudgmentDayCorrectionBatchHash(entries: readonly string[]): string | undefined {
	if (entries.length !== 2 || !JUDGMENT_DAY_CORRECTION_ROUND_ENTRY.test(entries[0]!)) return undefined;
	return entries[1]!.match(JUDGMENT_DAY_FROZEN_LEDGER_SHA256_ENTRY)?.[1];
}

function isNonEmptyJudgmentDayFrozenField(value: unknown): value is string {
	return typeof value === "string" && value.trim().length > 0;
}

function parseCanonicalJudgmentDayFrozenRows(
	entries: readonly string[],
	authorizedIds: readonly string[],
): Record<string, unknown>[] | undefined {
	if (entries.length !== authorizedIds.length) return undefined;
	const rows: Record<string, unknown>[] = [];
	const rowIds: string[] = [];
	for (const entry of entries) {
		let row: unknown;
		try {
			row = JSON.parse(entry) as unknown;
		} catch {
			return undefined;
		}
		if (!isRecord(row)) return undefined;
		const keys = Object.keys(row);
		if (keys.length !== JUDGMENT_DAY_FROZEN_ROW_FIELDS.length ||
			!JUDGMENT_DAY_FROZEN_ROW_FIELDS.every((field) => field in row) ||
			!isNonEmptyJudgmentDayFrozenField(row.id) ||
			!JUDGMENT_DAY_SEVERE_ID_ENTRY.test(`- \`${row.id}\``) ||
			row.lens !== "judgment-day" ||
			!isNonEmptyJudgmentDayFrozenField(row.location) ||
			(row.severity !== "BLOCKER" && row.severity !== "CRITICAL") ||
			row.status_at_freeze !== "open" ||
			!isNonEmptyJudgmentDayFrozenField(row.evidence_class) ||
			!isNonEmptyJudgmentDayFrozenField(row.evidence_claim)
		) return undefined;
		rows.push(row);
		rowIds.push(row.id);
	}
	return new Set(rowIds).size === rowIds.length &&
		rowIds.every((id, index) => id === authorizedIds[index])
		? rows
		: undefined;
}

function hasCanonicalJudgmentDayFixSectionOrder(...values: unknown[]): boolean {
	const dispatch = values.filter((value): value is string => typeof value === "string").join("\n");
	let previousPosition = -1;
	for (const heading of JUDGMENT_DAY_FIX_SECTION_HEADINGS) {
		const matches = [...dispatch.matchAll(new RegExp(`^${heading.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}$`, "gm"))];
		if (matches.length !== 1 || (matches[0]!.index ?? -1) <= previousPosition) return false;
		previousPosition = matches[0]!.index ?? -1;
	}
	return true;
}

function hasCanonicalJudgmentDayFixActivation(...values: unknown[]): boolean {
	const hasMalformedHeading = values.some((value) =>
		typeof value === "string" && value.split(/\r?\n/).some((line) => {
			const candidate = line.match(/^ {0,3}#{1,6} (Judgment Day activation|Exact authorized severe IDs|Judgment Day correction batch|Exact frozen finding rows)[ \t]*$/i);
			return candidate !== null &&
				line !== JUDGMENT_DAY_ACTIVATION_HEADING &&
				line !== JUDGMENT_DAY_AUTHORIZED_SEVERE_IDS_HEADING &&
				line !== JUDGMENT_DAY_CORRECTION_BATCH_HEADING &&
				line !== JUDGMENT_DAY_FROZEN_FINDING_ROWS_HEADING;
		}),
	);
	const activationBodies = values.flatMap((value) =>
		canonicalJudgmentDaySectionBodies(value, JUDGMENT_DAY_ACTIVATION_HEADING),
	);
	const severeIdBodies = values.flatMap((value) =>
		canonicalJudgmentDaySectionBodies(value, JUDGMENT_DAY_AUTHORIZED_SEVERE_IDS_HEADING),
	);
	const correctionBatchBodies = values.flatMap((value) =>
		canonicalJudgmentDaySectionBodies(value, JUDGMENT_DAY_CORRECTION_BATCH_HEADING),
	);
	const frozenFindingRowBodies = values.flatMap((value) =>
		canonicalJudgmentDaySectionBodies(value, JUDGMENT_DAY_FROZEN_FINDING_ROWS_HEADING),
	);
	const authorizedIds = severeIdBodies.length === 1
		? canonicalJudgmentDaySevereIds(severeIdBodies[0]!)
		: undefined;
	const correctionBatchHash = correctionBatchBodies.length === 1
		? canonicalJudgmentDayCorrectionBatchHash(correctionBatchBodies[0]!)
		: undefined;
	const frozenFindingRows = authorizedIds !== undefined && frozenFindingRowBodies.length === 1
		? parseCanonicalJudgmentDayFrozenRows(frozenFindingRowBodies[0]!, authorizedIds)
		: undefined;
	return !hasMalformedHeading && hasCanonicalJudgmentDayFixSectionOrder(...values) &&
		activationBodies.length === 1 &&
		activationBodies[0]!.length === 1 &&
		activationBodies[0]![0] === JUDGMENT_DAY_ACTIVATION_SENTENCE &&
		authorizedIds !== undefined && correctionBatchHash !== undefined &&
		frozenFindingRows !== undefined && correctionBatchHash === canonicalHash(frozenFindingRows);
}

const JUDGMENT_DAY_FIX_DISPATCH_REJECTION =
	"Judgment Day fix dispatch requires exactly one `agent: \"jd-fix-agent\"`, one exact `## Judgment Day activation` section containing only `User explicitly requested Judgment Day.`, one non-empty unique canonical `## Exact authorized severe IDs` section, one exact `## Judgment Day correction batch` section with `Round: 1 of 2.` or `Round: 2 of 2.` and the matching canonical lowercase SHA-256 of one exact `## Exact frozen finding rows` section whose BLOCKER/CRITICAL open Judgment Day rows equal the authorized IDs in the same order, and the existing exact `## Allowed edit surfaces` guard. The parent must provide the canonical bounded dispatch; do not infer activation, authorization, or frozen findings.";

export function rejectInvalidJudgmentDayFixDispatch(input: unknown): { block: true; reason: string } | undefined {
	if (!isRecord(input) || !hasJudgmentDayFixAgentReference(input)) return undefined;
	if (
		input.agent === JUDGMENT_DAY_FIX_AGENT_NAME &&
		!("agents" in input) &&
		hasCanonicalJudgmentDayFixActivation(input.task, input.context) &&
		hasTaskScopedAllowedEditSurfaces(input.task, input.context)
	) {
		return undefined;
	}
	return { block: true, reason: JUDGMENT_DAY_FIX_DISPATCH_REJECTION };
}
