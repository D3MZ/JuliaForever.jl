import { pathToFileURL } from "node:url";
import { join } from "node:path";

const source = process.argv[2];
const { SessionManager } = await import(pathToFileURL(join(source, "packages/coding-agent/src/core/session-manager.ts")));
const { AgentSession } = await import(pathToFileURL(join(source, "packages/coding-agent/src/core/agent-session.ts")));
const manager = SessionManager.inMemory();
const usage = (input, output, cacheRead, total, cost) => ({ input, output, cacheRead, cacheWrite: 0, totalTokens: total, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: cost } });
const assistant = text => ({ role: "assistant", content: [{ type: "text", text }], api: "openai-completions", provider: "openai", model: "fixture", usage: usage(100, 10, 20, 130, 0.01), stopReason: "stop", timestamp: 1 });
manager.appendMessage({ role: "user", content: "first", timestamp: 1 });
manager.appendMessage(assistant("reply:first"));
const kept = manager.appendMessage({ role: "user", content: "second", timestamp: 1 });
manager.appendMessage(assistant("reply:second"));
manager.appendCompaction("checkpoint", kept, 260, undefined, false, usage(40, 8, 5, 53, 0.002));
console.log(JSON.stringify(AgentSession.prototype.getSessionStats.call({ sessionManager: manager, sessionId: manager.getSessionId(), sessionFile: manager.getSessionFile(), getContextUsage: () => undefined })));
