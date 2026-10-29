import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [source, dir] = process.argv.slice(2);
const { SessionManager } = await import(pathToFileURL(join(source, "packages/coding-agent/src/core/session-manager.ts")));
const session = SessionManager.create(dir, dir);
session.appendMessage({ role: "user", content: "one", timestamp: 1 });
session.appendMessage({ role: "assistant", content: [{ type: "text", text: "reply:one" }], api: "openai-completions", provider: "fixture", model: "fixture", stopReason: "stop", timestamp: 2 });
const reopened = SessionManager.open(session.getSessionFile());
reopened.appendMessage({ role: "user", content: "two", timestamp: 3 });
const messages = reopened.buildSessionContext().messages.map((message) => [message.role, typeof message.content === "string" ? message.content : message.content.map((part) => part.text).join("")]);
process.stdout.write(JSON.stringify(messages));
