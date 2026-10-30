import { join } from "node:path";
import { pathToFileURL } from "node:url";

const source = process.argv[2];
const { runPrintMode } = await import(pathToFileURL(join(source, "packages/coding-agent/src/modes/print-mode.ts")));
const session = {
    state: { messages: [] },
    agent: { subscribe: () => () => {} },
    subscribe: () => () => {},
    bindExtensions: async () => {},
    prompt: async () => session.state.messages.push({ role: "assistant", content: [{ type: "text", text: "partial content" }], stopReason: "length" }),
};
const runtime = { session, setRebindSession: () => {}, dispose: async () => {} };
process.exitCode = await runPrintMode(runtime, { mode: "text", initialMessage: "start" });
