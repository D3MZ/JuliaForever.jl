import { mkdtempSync, mkdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { register } from "node:module";
register("./tool_options_loader.mjs", import.meta.url);

const source = process.argv[2];
const root = mkdtempSync(join(tmpdir(), "jf-pi-tool-options-"));
const core = join(source, "packages/coding-agent/src/core");
const load = path => import(pathToFileURL(path));
const { parseArgs } = await load(join(source, "packages/coding-agent/src/cli/args.ts"));
const { createAgentSession } = await load(join(core, "sdk.ts"));
const { SettingsManager } = await load(join(core, "settings-manager.ts"));
const { DefaultResourceLoader } = await load(join(core, "resource-loader.ts"));
const { SessionManager } = await load(join(core, "session-manager.ts"));
const model = { id: "fixture", name: "fixture", api: "openai-completions", provider: "fixture", baseUrl: "http://localhost", reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 8192, maxTokens: 1024 };
const settingsManager = SettingsManager.inMemory();
const agentDir = join(root, "agent");
mkdirSync(agentDir, { recursive: true });
const extensionFactories = [pi => pi.registerTool({ name: "greet", label: "Greeting", description: "Greeting fixture", parameters: { type: "object", properties: {} }, execute: async () => ({ content: [{ type: "text", text: "hello" }], details: {} }) })];
const resourceLoader = new DefaultResourceLoader({ cwd: root, agentDir, settingsManager, extensionFactories });
await resourceLoader.reload();
const cases = JSON.parse(process.argv[3]);
const results = [];
try {
    for (const args of cases) {
        const parsed = parseArgs(args);
        const errors = parsed.diagnostics.filter(d => d.type === "error").map(d => d.message);
        if (errors.length) { results.push({ errors }); continue; }
        const noTools = parsed.noTools ? "all" : parsed.noBuiltinTools ? "builtin" : undefined;
        const { session } = await createAgentSession({ cwd: root, agentDir, model, settingsManager, resourceLoader, sessionManager: SessionManager.inMemory(root), tools: parsed.tools, excludeTools: parsed.excludeTools, noTools });
        try { results.push({ tools: session.getActiveToolNames().sort() }); }
        finally { session.dispose(); }
    }
} finally { rmSync(root, { recursive: true, force: true }); }
process.stdout.write(JSON.stringify(results));
