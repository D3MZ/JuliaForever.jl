import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { readFile } from "node:fs/promises";
const [source, id = "gpt-5.2", level = "high"] = process.argv.slice(2);
const data = JSON.parse(await readFile(join(source, "node_modules/@earendil-works/pi-ai/dist/providers/data/openai.json")));
const model = data["openai-responses"][`chat:${id}`];
const { streamSimple } = await import(pathToFileURL(join(source, "packages/ai/src/api/openai-responses.ts")));
const { findExactModelReferenceMatch } = await import(pathToFileURL(join(source, "packages/coding-agent/src/core/model-resolver.ts")));
let payload;
const response = streamSimple(model, { messages: [{ role: "user", content: "hello", timestamp: 0 }] }, {
    apiKey: "sk-synthetic", reasoning: level, onPayload: value => { payload = value; },
    fetch: async () => new Response('data: {"type":"response.completed","response":{"status":"completed","output":[]}}\n\n', { headers: { "content-type": "text/event-stream" } }),
});
await response.result();
process.stdout.write(JSON.stringify({ reasoning: payload.reasoning, updates: payload.input.filter(item => item.type === "configuration_update"), exact: findExactModelReferenceMatch(id, [model])?.id ?? null, suffixed: findExactModelReferenceMatch(`${id}:low`, [model])?.id ?? null }));
