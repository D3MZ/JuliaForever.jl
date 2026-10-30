import { pathToFileURL } from "node:url";
import { join } from "node:path";
import { readFileSync } from "node:fs";

const source = process.argv[2];
let fixtures = [
  ["openai", "openai-completions", "openai", "openai-completions.ts", "fixture"],
  ["responses", "openai-responses", "openai", "openai-responses.ts", "fixture"],
  ["google", "google-generative-ai", "google", "google-generative-ai.ts", "gemini-3-fixture"],
  ["anthropic", "anthropic-messages", "anthropic", "anthropic-messages.ts", "claude-fixture"],
];
if (process.argv[3] === "native") fixtures = [
  ["openai", "openai-completions", "openrouter", "openai-completions.ts", "openai/gpt-5.4"],
  ["responses", "openai-responses", "openai", "openai-responses.ts", "gpt-5.4"],
  ["anthropic", "anthropic-messages", "anthropic", "anthropic-messages.ts", "claude-opus-5"],
];
if (process.argv[3] === "order") fixtures = [["anthropic", "anthropic-messages", "anthropic", "anthropic-messages.ts", "claude-opus-5"]];
if (process.argv[3] === "reasoning") fixtures = [["responses", "openai-responses", "openai", "openai-responses.ts", "gpt-5.4"]];
if (process.argv[3] === "reasoning_collapsed") fixtures = [["responses", "openai-responses", "openai", "openai-responses.ts", "gpt-5"]];
if (process.argv[3] === "reasoning_completions") fixtures = [["openai", "openai-completions", "openrouter", "openai-completions.ts", "openai/gpt-5.4"]];
const catalog = JSON.parse(readFileSync(new URL("../data/pi-rpc-models.json", import.meta.url)));
const tool = name => ({ name, description: name, parameters: { type: "object", properties: { kind: { const: "synthetic" }, const: { const: 7 }, flag: { const: true }, existing: { const: 5, enum: [5, 6] }, nested: { default: { const: "literal" }, items: { const: "inner" } } } } });
let messages = [
  { role: "system", content: "base", sections: { zebra: "first", apple: "old" }, toolsAdded: [tool("alpha")], timestamp: 0 },
  { role: "user", content: "hello", timestamp: 0 },
  { role: "system", content: "extra", sections: { apple: "new", zebra: null, banana: "last" }, toolsRemoved: [{ name: "alpha" }], toolsAdded: [tool("beta")], timestamp: 1 },
];
if (process.argv[3] === "order") messages = [
  { role: "system", content: "base", toolsAdded: [tool("write")], timestamp: 0 },
  { role: "user", content: "go", timestamp: 1 },
  { role: "assistant", api: "anthropic-messages", provider: "anthropic", model: "claude-opus-5", content: [{ type: "toolCall", id: "call", name: "write", arguments: { path: "a", content: "ok" } }], usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: "toolUse", timestamp: 2 },
  { role: "system", content: "extra", toolsRemoved: [{ name: "write" }], toolsAdded: [tool("beta")], timestamp: 3 },
  { role: "toolResult", toolCallId: "call", toolName: "write", content: [{ type: "text", text: "ok" }], isError: false, timestamp: 4 },
  { role: "user", content: "next", timestamp: 5 },
];
const output = {};
for (const [name, api, provider, file, id] of fixtures) {
  const { stream } = await import(pathToFileURL(join(source, "packages/ai/src/api", file)));
  const base = { id, name: id, api, provider, baseUrl: "http://127.0.0.1:1/v1", reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 1000, maxTokens: 100, compat: { supportsEagerToolInputStreaming: false } };
  let model = process.argv[3] ? { ...catalog.find(m => m.provider === provider && m.id === id && m.api === api), baseUrl: base.baseUrl } : base;
  if (["reasoning", "reasoning_completions"].includes(process.argv[3])) model = { ...model, reasoning: false };
  await stream(model, { messages }, { apiKey: "synthetic-key", onPayload: value => { output[name] = value; throw new Error("captured"); } }).result();
  if (!output[name]) throw new Error(`No ${name} payload captured`);
}
process.stdout.write(JSON.stringify(output));
