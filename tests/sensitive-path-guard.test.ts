import assert from "node:assert/strict";
import { homedir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { evaluateSensitivePathTool, isSensitivePath } from "../lib/sensitive-path-guard.ts";

test("blocks every guarded tool when the path is a private key or credential store", () => {
	for (const toolName of ["read", "write", "edit"]) {
		const result = evaluateSensitivePathTool(toolName, { path: join(homedir(), ".ssh", "id_rsa") });
		assert.equal(result?.block, true, `${toolName} must be blocked`);
		assert.match(result?.reason ?? "", /sensitive path/);
	}
});

test("classifies sensitive locations across spellings", () => {
	const sensitive = [
		"~/.ssh/id_rsa",
		"~/.ssh/config",
		"/home/user/.credentials/service.json",
		"C:\\Users\\someone\\.aws\\credentials",
		"/repo/secrets/db-password.txt",
		"/repo/.env",
		"/repo/.env.local",
		"/repo/.env-production",
		"~/.config/gh/hosts.yml",
		"/Library/Keychains/login.keychain",
		"certs/server.pem",
		"certs/server.key",
		"certs/identity.p12",
		"certs/bundle.pfx",
		".SSH/ID_RSA",
	];
	for (const value of sensitive) {
		assert.equal(isSensitivePath(value), true, `${value} must be sensitive`);
	}
});

test("keeps ordinary project paths readable", () => {
	const benign = [
		"src/main.ts",
		"docs/readme.md",
		"/repo/environment.ts",
		"/repo/my.env.local",
		"/repo/ssh-keys.txt",
		"/repo/keyboard.ts",
		"package.json",
	];
	for (const value of benign) {
		assert.equal(isSensitivePath(value), false, `${value} must not be sensitive`);
	}
});

test("ignores tools outside the path guard", () => {
	for (const toolName of ["bash", "mem_save", "grep", ""]) {
		assert.equal(evaluateSensitivePathTool(toolName, { path: "~/.ssh/id_rsa" }), undefined);
	}
});

test("finds path inputs nested in objects and arrays", () => {
	const nested = evaluateSensitivePathTool("write", { input: { filePath: "/home/u/.ssh/authorized_keys" } });
	assert.equal(nested?.block, true);

	const listed = evaluateSensitivePathTool("read", { paths: ["src/main.ts", "/home/u/.ssh/id_rsa"] });
	assert.equal(listed?.block, true);

	const objects = evaluateSensitivePathTool("edit", { files: [{ path: "src/a.ts" }, { path: "/repo/.env" }] });
	assert.equal(objects?.block, true);
});

test("does not treat file contents or prompts as paths", () => {
	assert.equal(evaluateSensitivePathTool("write", { path: "src/config.ts", content: "~/.ssh/id_rsa" }), undefined);
	assert.equal(evaluateSensitivePathTool("read", { prompt: "/home/u/.ssh/id_rsa" }), undefined);
});

test("allows a guarded tool when every path input is safe", () => {
	assert.equal(evaluateSensitivePathTool("read", { path: "src/main.ts" }), undefined);
	assert.equal(evaluateSensitivePathTool("edit", { filePath: "docs/readme.md" }), undefined);
});

test("tolerates missing or malformed input", () => {
	assert.equal(evaluateSensitivePathTool("read", undefined), undefined);
	assert.equal(evaluateSensitivePathTool("read", null), undefined);
	assert.equal(evaluateSensitivePathTool("read", 42), undefined);
	assert.equal(evaluateSensitivePathTool("read", {}), undefined);
	assert.equal(evaluateSensitivePathTool("read", { path: 42 }), undefined);
});

test("strips terminal escapes from the reported path", () => {
	const result = evaluateSensitivePathTool("read", { path: "/tmp/.ssh/\u001b[31mhost\u001b[0m" });
	assert.equal(result?.block, true);
	assert.equal((result?.reason ?? "").includes("\u001b"), false);
});
