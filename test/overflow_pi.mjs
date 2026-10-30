import { join } from "node:path";
import { pathToFileURL } from "node:url";

const source = process.argv[2];
const load = path => import(pathToFileURL(join(source, path)));
const { AgentSession } = await load("packages/coding-agent/src/core/agent-session.ts");
const { SessionManager } = await load("packages/coding-agent/src/core/session-manager.ts");
const { prepareCompaction, DEFAULT_COMPACTION_SETTINGS } = await load("packages/coding-agent/src/core/compaction/compaction.ts");
const { isContextOverflow } = await load("packages/ai/src/utils/overflow.ts");

const usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
const message = errorMessage => ({ role: "assistant", content: [], api: "test", provider: "test", model: "model", stopReason: "error", errorMessage, usage, timestamp: Date.now() });
const model = { id: "model", provider: "test", contextWindow: 100, maxTokens: 20 };
const session = SessionManager.inMemory();
const events = [];
let attempts = 0;
let omissions = 0;
const mock = {
    model,
    settingsManager: { getCompactionSettings: () => ({ enabled: true, reserveTokens: 20 }) },
    sessionManager: session,
    agent: { state: { messages: [] } },
    _overflowRecoveryAttempted: false,
    _modelForMessage: () => model,
    _findPersistedMessageEntryId: () => undefined,
    _omitRecoveryAttempt: () => { omissions++; },
    _runAutoCompaction: async () => { attempts++; return true; },
    _emit: event => events.push(event),
    _emitSessionCompactFailed: async () => {},
};
const check = msg => AgentSession.prototype._checkCompaction.call(mock, msg);
const first = await check(message("413"));
const second = await check(message("413"));
const emptySession = SessionManager.inMemory();
emptySession.appendMessage({ role: "user", content: "current", timestamp: 1 });
const noProgress = prepareCompaction(emptySession.getBranch(), DEFAULT_COMPACTION_SETTINGS) === undefined;
const detection = ["413", "request_too_large", "429 too many requests", "rate limit: too many tokens"].map(text => isContextOverflow(message(text)));

const live = SessionManager.inMemory();
const failed = message("413");
const originals = [
    { role: "user", content: [{ type: "text", text: "old request" }], timestamp: 1 },
    { ...message(undefined), content: [{ type: "text", text: "old answer" }], stopReason: "stop", timestamp: 2 },
    { role: "user", content: [{ type: "text", text: "current" }], timestamp: 3 },
    failed,
];
const ids = new WeakMap();
for (const item of originals) ids.set(item, live.appendMessage(item));
const liveEvents = [];
const actual = {
    model,
    settingsManager: { getCompactionSettings: () => ({ ...DEFAULT_COMPACTION_SETTINGS, keepRecentTokens: 1 }) },
    sessionManager: live,
    agent: { state: { messages: originals }, hasQueuedMessages: () => false },
    _entryIdsByMessage: ids,
    _extensionRunner: { hasHandlers: () => false, emit: async () => {} },
    _overflowRecoveryAttempted: false,
    _modelForMessage: () => model,
    _findPersistedMessageEntryId: item => ids.get(item),
    _refreshFinalizedContext() { this.agent.state.messages = live.buildSessionContext().messages; },
    _runDefaultCompaction: async preparation => ({ summary: "checkpoint", firstKeptEntryId: preparation.firstKeptEntryId, tokensBefore: preparation.tokensBefore }),
    _emit: event => liveEvents.push(event),
    _emitSessionCompactFailed: async () => {},
    _resolveIdleWaitIfIdle: () => {},
};
actual._omitRecoveryAttempt = msg => AgentSession.prototype._omitRecoveryAttempt.call(actual, msg);
actual._runAutoCompaction = (...args) => AgentSession.prototype._runAutoCompaction.call(actual, ...args);
const liveRetry = await AgentSession.prototype._checkCompaction.call(actual, failed);
const entries = live.getBranch();
const liveResult = {
    retry: liveRetry,
    omitted: entries.some(entry => entry.type === "context_edit" && entry.targetId === ids.get(failed) && entry.replacement === null),
    compacted: entries.some(entry => entry.type === "compaction" && entry.summary === "checkpoint"),
    failedVisible: live.buildSessionContext().messages.some(item => item === failed),
    ends: liveEvents.filter(event => event.type === "compaction_end").map(event => ({ reason: event.reason, willRetry: event.willRetry })),
};
process.stdout.write(JSON.stringify({ first, second, attempts, omissions, failed: events.some(event => event.type === "compaction_end" && !event.willRetry), noProgress, detection, liveResult }));
