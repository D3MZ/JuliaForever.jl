import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [source, path, mode] = process.argv.slice(2);
const chunks = JSON.parse(await readFile(path, "utf8"));
const { stream } = await import(pathToFileURL(join(source, "packages/ai/src/api/google-generative-ai.ts")));
const model = { id: "gemini-3-fixture", name: "Fixture", api: "google-generative-ai", provider: "google", baseUrl: "https://generativelanguage.googleapis.com/v1beta", reasoning: true, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 1000, maxTokens: 90 };
let payload;
globalThis.fetch = async (url, init) => {
  payload = JSON.parse(init.body);
  return new Response(chunks.map(chunk => `data: ${JSON.stringify(chunk)}\n\n`).join(""), { headers: { "content-type": "text/event-stream" } });
};
const messages = mode === "history" ? [
  { role: "user", content: "hi", timestamp: 0 },
  { role: "assistant", api: model.api, provider: model.provider, model: model.id, timestamp: 0, stopReason: "toolUse", usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, content: [{ type: "toolCall", id: "call-1", name: "write", arguments: { path: "a.txt", content: "ok" }, thoughtSignature: "c2lnbmVk" }] },
  { role: "toolResult", toolCallId: "call-1", toolName: "write", content: [{ type: "text", text: "failed" }], isError: true, timestamp: 0 }
] : [{ role: "user", content: "hi", timestamp: 0 }];
const result = await stream(model, { messages }, { apiKey: "synthetic" }).result();
process.stdout.write(JSON.stringify({ result, payload }));
