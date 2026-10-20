import { recognizeDestructiveCommands } from "./destructive-command-guard.ts";
import { defaultTempScratchFs, isTempScratchRemoval, type TempScratchFs } from "./yolo-temp-scratch.ts";

export const GUARD_ACTION = {
	ALLOW: "allow",
	CONFIRM: "confirm",
	BLOCK: "block",
} as const;

export type GuardAction = (typeof GUARD_ACTION)[keyof typeof GUARD_ACTION];
export type GuardClassification = GuardAction | "not-guarded";

export interface GuardMatch {
	key: GuardedCommandKey;
	action: GuardAction;
	triggerIndex: number;
}

export interface GuardEvaluation {
	action: GuardClassification;
	dataLoss?: boolean;
	key?: GuardedCommandKey;
	triggerIndex: number;
	matches: GuardMatch[];
}

export const GUARDED_COMMAND_KEY = {
	GIT_PUSH: "gitPush",
	GIT_REBASE: "gitRebase",
	GIT_BRANCH_DELETE_FORCE: "gitBranchDeleteForce",
	NPM_PUBLISH: "npmPublish",
	PI_REMOVE: "piRemove",
} as const;

export type GuardedCommandKey = (typeof GUARDED_COMMAND_KEY)[keyof typeof GUARDED_COMMAND_KEY];

export type GuardedCommandsConfig = Partial<Record<GuardedCommandKey, GuardAction>>;

export interface RuntimeGuardrailsConfig {
	autonomousMode: boolean;
	guardedCommands: GuardedCommandsConfig;
}

export interface LoadGuardrailsOptions {
	/** Override the config home directory (used in tests to avoid touching ~/.pi). */
	gentlePiConfigHome?: string;
}

// gentle-shell#2172: YOLO waives reversible delivery, not only one bare push.
// A guarded segment is judged from its trigger word (`push`/`rebase`) to the
// next command separator; a plain token or allow-listed option list is the
// whole eligible grammar, so quotes, wrappers and unknown options fall back
// to the ordinary confirmation. Everything that deletes or rewrites a remote
// ref, publishes, or runs arbitrary commands is deliberately absent:
// `--delete`/`-d`, `:dst` and `+src` refspecs, `--mirror`, `--prune`,
// `--all`, every force spelling, `--receive-pack`/`--exec`, `--repo`, `-o`.
export const YOLO_WAIVABLE_KEYS: ReadonlySet<GuardedCommandKey> = new Set(["gitPush", "gitRebase"]);
const YOLO_SEGMENT_END_RE = /&&|\|\||;|\||\n|\r/;
// Text between the segment start and the `push`/`rebase` word: optional
// variable assignments, `env`/`command` prefixes and the `git` word with at
// most a `-C <path>`. Other global options (`-c key=value`, `--exec-path`,
// `--git-dir`) can run or redirect code, so they keep the confirmation.
const YOLO_GIT_PREFIX_RE = /^\s*(?:[A-Za-z_][A-Za-z0-9_]*=[^\s'"`$]*\s+|env\s+(?:-i\s+)?|command\s+)*git(?:\s+-C\s+[^\s'"`$;&|]+)?\s+$/;
// Output redirections that write nothing: to stdout/stderr or /dev/null.
const YOLO_REDIRECT_SRC = String.raw`[12]?>&[12]|(?:[12]?|&)>>?\s*/dev/null(?![^\s;&|])`;
const YOLO_PUSH_SEGMENT_RE = new RegExp(String.raw`^push(?:\s+(?:${YOLO_REDIRECT_SRC}|-u|--set-upstream|-q|--quiet|-v|--verbose|--tags|--follow-tags|--no-verify|--porcelain|[A-Za-z0-9_][A-Za-z0-9_./-]*(?::[A-Za-z0-9_][A-Za-z0-9_./-]*)?))*\s*$`);
const YOLO_REBASE_SEGMENT_RE = new RegExp(String.raw`^rebase(?:\s+(?:${YOLO_REDIRECT_SRC}|--onto\s+[A-Za-z0-9_][A-Za-z0-9_./~^-]*|--continue|--abort|--skip|--autostash|--no-autostash|[A-Za-z0-9_][A-Za-z0-9_./~^-]*))*\s*$`);
// A pipe out of a waived segment may only feed read-only filters with plain or
// literally quoted arguments and end at a sequential separator. Git output
// carries remote-controlled text, so `| sh`, `| tee`, `| xargs` and a trailing
// background `&` keep the confirmation.
const YOLO_FILTER_PIPELINE_RE = new RegExp(String.raw`^(?:\|(?!\|)\s*(?:tail|head|cat|grep|wc)(?:\s+(?:${YOLO_REDIRECT_SRC}|[A-Za-z0-9_.,:=+/%@-]+|'[^'\n]*'|"[^"$\x60\\\n]*"))*\s*)*(?=$|&&|\|\||;|\n|\r)`);

function yoloGuardedSegment(command: string, triggerIndex: number): string {
	const rest = command.slice(triggerIndex);
	const end = rest.search(YOLO_SEGMENT_END_RE);
	return end < 0 ? rest : rest.slice(0, end);
}

function yoloSegmentPrefix(command: string, triggerIndex: number): string {
	const head = command.slice(0, triggerIndex);
	const separators = [...head.matchAll(new RegExp(YOLO_SEGMENT_END_RE.source, "g"))];
	const last = separators.at(-1);
	return last === undefined ? head : head.slice(last.index + last[0].length);
}

/**
 * Every guarded match and every recognized Git side effect must be a reversible
 * push or non-interactive rebase; the only data loss allowed is recursive
 * removal of the session's own temp scratch (lib/yolo-temp-scratch.ts).
 */
export function isReversibleYoloCommand(command: string, evaluation: GuardEvaluation, scratchFs?: TempScratchFs): boolean {
	if (evaluation.action !== "confirm") return false;
	const effects = recognizeDestructiveCommands(command);
	const scratch = effects.map((effect) => effect.removalTargets !== undefined && isTempScratchRemoval(effect, scratchFs ??= defaultTempScratchFs()));
	if (evaluation.matches.length === 0 && !scratch.includes(true)) return false;
	for (const match of evaluation.matches) {
		if (!YOLO_WAIVABLE_KEYS.has(match.key)) return false;
		if (!YOLO_GIT_PREFIX_RE.test(yoloSegmentPrefix(command, match.triggerIndex))) return false;
		const segment = yoloGuardedSegment(command, match.triggerIndex);
		if (!(match.key === "gitPush" ? YOLO_PUSH_SEGMENT_RE : YOLO_REBASE_SEGMENT_RE).test(segment)) return false;
		if (!YOLO_FILTER_PIPELINE_RE.test(command.slice(match.triggerIndex + segment.length))) return false;
	}
	// The data-loss recognizer leaves non-hard Git effects (reset, stash drop,
	// restore, checkout --) to the primary policy; under YOLO only a rebase that
	// a guarded match already vetted may remain.
	const rebaseTriggers = new Set(evaluation.matches.filter((match) => match.key === "gitRebase").map((match) => match.triggerIndex));
	for (const [index, effect] of effects.entries()) {
		if (scratch[index]) continue;
		if (effect.hardDeny || effect.kind !== "git") return false;
		const rebase = /^git(?:\s+(?:-C|-c|--git-dir|--work-tree|--namespace)\s+\S+|\s+-\S+)*\s+(rebase)\b/.exec(command.slice(effect.triggerIndex));
		if (rebase === null || !rebaseTriggers.has(effect.triggerIndex + rebase.index + rebase[0].lastIndexOf("rebase"))) return false;
	}
	return true;
}
