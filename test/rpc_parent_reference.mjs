import { existsSync, mkdtempSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { pathToFileURL } from "node:url";

const { SessionManager } = await import(pathToFileURL(join(process.argv[2], "packages/coding-agent/src/core/session-manager.ts")));
const root = mkdtempSync(join(tmpdir(), "jf-parent-"));
const session = SessionManager.create(root, join(root, "sessions"));
session.newSession({ parentSession: "../missing parent.jsonl" });
const file = session.getSessionFile();
const before = existsSync(file);
session.appendMessage({ role: "user", content: "hello", timestamp: Date.now() });
const header = JSON.parse(readFileSync(file, "utf8").split("\n")[0]);
const reopened = SessionManager.open(file);
process.stdout.write(JSON.stringify({ before, parent: header.parentSession, reopened: reopened.getHeader().parentSession }));
