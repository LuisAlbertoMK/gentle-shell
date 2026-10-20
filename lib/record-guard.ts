/** Narrow a parsed JSON value to a plain record: objects only, never null or arrays. */
export function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}
