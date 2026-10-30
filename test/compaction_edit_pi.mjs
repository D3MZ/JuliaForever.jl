import { join } from "node:path";
import { pathToFileURL } from "node:url";

const core = join(process.argv[2], "packages/coding-agent/src/core");
const { AgentSession } = await import(pathToFileURL(join(core, "agent-session.ts")));
const { SessionManager } = await import(pathToFileURL(join(core, "session-manager.ts")));
const { estimateProjectedContextTokens } = await import(pathToFileURL(join(core, "compaction/compaction.ts")));
const model = { id: "small", provider: "fixture", contextWindow: 100, maxTokens: 20 };
const usage = (n) => ({ input: n, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: n, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } });
const assistant = (text, n, timestamp) => ({ role: "assistant", content: [{ type: "text", text }], api: "openai-completions", provider: "fixture", model: "small", usage: usage(n), stopReason: "stop", timestamp });
async function check(fresh, edited = "s".repeat(400), tokens = 50) {
    const manager = SessionManager.inMemory();
    manager.appendMessage({ role: "user", content: "first", timestamp: 1 });
    manager.appendMessage(assistant("first answer", 50, 1));
    const kept = manager.appendMessage({ role: "user", content: "second", timestamp: 1 });
    const old = assistant("second answer", 81, 1);
    const oldId = manager.appendMessage(old);
    manager.appendCompaction("initial checkpoint", kept, 81);
    const last = fresh ? assistant("third answer", tokens, Date.now() + 1000) : old;
    const lastId = fresh ? manager.appendMessage(last) : oldId;
    manager.appendContextEdit(kept, { content: edited });
    const projection = manager.buildSessionProjection();
    const checks = [];
    const mock = {
        model,
        settingsManager: { getCompactionSettings: () => ({ enabled: true, reserveTokens: 20, keepRecentTokens: 0 }) },
        sessionManager: manager,
        agent: { state: { messages: projection.messages } },
        _modelForMessage: () => model,
        _findPersistedMessageEntryId: () => lastId,
        _runAutoCompaction: async (reason) => { checks.push(reason); return false; },
    };
    await AgentSession.prototype._checkCompaction.call(mock, last, false);
    return { checks, estimate: estimateProjectedContextTokens(projection, manager.getBranch()).tokens };
}
const edited = await check(true);
const stale = await check(false);
const small = await check(true, "small", 81);
process.stdout.write(JSON.stringify({ editedChecks: edited.checks, editedEstimate: edited.estimate, staleChecks: stale.checks, smallChecks: small.checks }));
