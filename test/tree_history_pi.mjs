import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [source, cwd] = process.argv.slice(2);
const { SessionManager } = await import(pathToFileURL(join(source, "packages/coding-agent/src/core/session-manager.ts")));
const session = SessionManager.inMemory(cwd);
const user = (content) => ({ role: "user", content, timestamp: 1 });
const assistant = (text) => ({ role: "assistant", content: [{ type: "text", text }], api: "openai-completions", provider: "fixture", model: "fixture", stopReason: "stop", timestamp: 2 });
session.appendMessage(user("first"));
const first = session.appendMessage(assistant("reply:first"));
session.appendMessage(user("second"));
const original = session.appendMessage(assistant("reply:second"));
session.branch(first);
session.appendMessage(user("alternative"));
const alternative = session.appendMessage(assistant("reply:alternative"));
const context = (leaf) => {
    session.branch(leaf);
    return session.buildSessionContext().messages.map((message) => typeof message.content === "string" ? message.content : message.content.map((part) => part.text).join(""));
};
process.stdout.write(JSON.stringify([context(original), context(alternative)]));
