import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [source, operation, title] = process.argv.slice(2);
const { SessionManager } = await import(pathToFileURL(join(source, "packages/coding-agent/src/core/session-manager.ts")));
const cwd = process.cwd();
if (operation === "create") SessionManager.create(cwd).appendMessage({ role: "user", content: title, timestamp: Date.now() });
process.stdout.write(JSON.stringify((await SessionManager.list(cwd)).map((session) => session.firstMessage)));
