import { join } from "node:path";
import { pathToFileURL } from "node:url";

const source = process.argv[2];
const { SessionManager } = await import(pathToFileURL(join(source, "packages/coding-agent/src/core/session-manager.ts")));
const { convertToLlm } = await import(pathToFileURL(join(source, "packages/coding-agent/src/core/messages.ts")));

const session = SessionManager.inMemory();
session.appendMessage({ role: "system", content: "instructions", timestamp: 1 });
session.appendMessage({ role: "user", content: "old request", timestamp: 2 });
session.appendMessage({ role: "assistant", content: "old answer", timestamp: 3 });
const kept = session.appendMessage({ role: "user", content: "recent request", timestamp: 4 });
session.appendMessage({ role: "assistant", content: "recent answer", timestamp: 5 });
session.appendCompaction("checkpoint", kept, 100);

function view() {
    return convertToLlm(session.buildSessionContext().messages).map(({ role, content }) => ({
        role,
        content: Array.isArray(content) ? content.map(part => part.text ?? "").join("") : content,
    }));
}

const before = view();
session.appendMessage({ role: "user", content: "follow up", timestamp: 6 });
process.stdout.write(JSON.stringify({ before, after: view() }));
