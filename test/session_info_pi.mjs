import { pathToFileURL } from "node:url";
import { join } from "node:path";

const source = process.argv[2];
const { SessionManager } = await import(pathToFileURL(join(source, "packages/coding-agent/src/core/session-manager.ts")));
const { AgentSession } = await import(pathToFileURL(join(source, "packages/coding-agent/src/core/agent-session.ts")));
const manager = SessionManager.inMemory();
const usage = (input, output, cacheRead, cacheWrite, total, cost) => ({ input, output, cacheRead, cacheWrite, totalTokens: total, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: cost } });
const assistant = (text, usage) => ({ role: "assistant", content: [{ type: "text", text }], api: "openai-completions", provider: "openai", model: "fixture", usage, stopReason: "stop", timestamp: 1 });
manager.appendMessage({ role: "user", content: "first", timestamp: 1 });
const first = manager.appendMessage(assistant("reply:first", usage(100, 20, 30, 10, 160, 0.012)));
manager.appendMessage({ role: "user", content: "second", timestamp: 1 });
manager.appendMessage(assistant("reply:second", usage(50, 10, 5, 0, 65, 0.003)));
manager.branch(first);
const stats = AgentSession.prototype.getSessionStats.call({ sessionManager: manager, sessionId: manager.getSessionId(), sessionFile: manager.getSessionFile(), getContextUsage: () => undefined });
console.log(JSON.stringify(stats));
