import { join } from "node:path";
import { pathToFileURL } from "node:url";

const core = join(process.argv[2], "packages/coding-agent/src/core");
const { AgentSession } = await import(pathToFileURL(join(core, "agent-session.ts")));
const { SessionManager } = await import(pathToFileURL(join(core, "session-manager.ts")));
const { estimateContextTokens } = await import(pathToFileURL(join(core, "compaction/compaction.ts")));
const model = { id: "small", provider: "fixture", contextWindow: 100, maxTokens: 20 };
const usage = (totalTokens) => ({ input: totalTokens, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } });
const assistant = (text, tokens) => ({ role: "assistant", content: [{ type: "text", text }], api: "openai-completions", provider: "fixture", model: "small", usage: usage(tokens), stopReason: "stop", timestamp: 1 });

async function check(tokens, enabled, compacted, repeat = false) {
    const manager = SessionManager.inMemory();
    manager.appendMessage({ role: "user", content: "first", timestamp: 1 });
    manager.appendMessage(assistant("first answer", 50));
    const kept = manager.appendMessage({ role: "user", content: "second", timestamp: 1 });
    const last = assistant("second answer", tokens);
    manager.appendMessage(last);
    if (compacted) manager.appendCompaction("checkpoint", kept, tokens);
    const calls = [];
    const mock = {
        model,
        settingsManager: { getCompactionSettings: () => ({ enabled, reserveTokens: 20, keepRecentTokens: 0 }) },
        sessionManager: manager,
        agent: { state: { messages: manager.buildSessionContext().messages } },
        _modelForMessage: () => model,
        _findPersistedMessageEntryId: () => undefined,
        _runAutoCompaction: async (reason, retry) => { calls.push({ reason, retry }); return false; },
    };
    await AgentSession.prototype._checkCompaction.call(mock, last, false);
    if (repeat) await AgentSession.prototype._checkCompaction.call(mock, last, false);
    return calls;
}

const fallback = estimateContextTokens([
    { role: "user", content: "first", timestamp: 1 }, assistant("first answer", 75),
    { role: "user", content: "second", timestamp: 1 }, assistant("z".repeat(40), 0),
]);
const unreported = estimateContextTokens([
    { role: "user", content: "first", timestamp: 1 }, assistant("first answer", 0),
    { role: "user", content: "second", timestamp: 1 }, assistant("z".repeat(400), 0),
]);
process.stdout.write(JSON.stringify({ high: await check(81, true, false), boundary: await check(80, true, false), disabled: await check(81, false, false), stale: await check(81, true, true), retryAfterCancelled: await check(81, true, false, true), fallback, unreported }));
