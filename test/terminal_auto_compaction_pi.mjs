import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { register } from "node:module";

register("./tool_options_loader.mjs", import.meta.url);
const core = join(process.argv[2], "packages/coding-agent/src/core");
const { SettingsManager } = await import(pathToFileURL(join(core, "settings-manager.ts")));
const { shouldCompact, prepareCompaction, findCutPoint } = await import(pathToFileURL(join(core, "compaction/compaction.ts")));
const { SessionManager } = await import(pathToFileURL(join(core, "session-manager.ts")));
const manager = SettingsManager.create(process.argv[3], process.argv[4]);
const settings = manager.getCompactionSettings({ provider: "fixture", id: "small" });
const decisions = [130, 131].map(tokens => shouldCompact(tokens, 16514, settings));
const sessions = SessionManager.inMemory();
const usage = { input: 130, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 130, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
for (const text of ["first", "second"]) {
    sessions.appendMessage({ role: "user", content: text, timestamp: 1 });
    sessions.appendMessage({ role: "assistant", content: [{ type: "text", text: `reply:${text}` }], api: "openai-completions", provider: "fixture", model: "small", usage, stopReason: "stop", timestamp: 1 });
}
const preparations = [0, 20000].map(keepRecentTokens => Boolean(prepareCompaction(sessions.getBranch(), { ...settings, keepRecentTokens })));
const entries = sessions.getBranch();
const cuts = [0, 1, 3, 4, 5, 7, 20000].map(keep => findCutPoint(entries, 0, entries.length, keep).firstKeptEntryIndex);
const tools = SessionManager.inMemory();
tools.appendMessage({ role: "user", content: "read file", timestamp: 1 });
tools.appendMessage({ role: "assistant", content: [{ type: "toolCall", id: "call", name: "read", arguments: {} }], api: "openai-completions", provider: "fixture", model: "small", usage, stopReason: "toolUse", timestamp: 1 });
tools.appendMessage({ role: "toolResult", toolCallId: "call", toolName: "read", content: [{ type: "text", text: "file contents" }], isError: false, timestamp: 1 });
tools.appendMessage({ role: "assistant", content: [{ type: "text", text: "done" }], api: "openai-completions", provider: "fixture", model: "small", usage, stopReason: "stop", timestamp: 1 });
const toolEntries = tools.getBranch();
const toolCuts = [0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 20000].map(keep => findCutPoint(toolEntries, 0, toolEntries.length, keep).firstKeptEntryIndex);
process.stdout.write(JSON.stringify({ settings, decisions, preparations, cuts, toolCuts }));
