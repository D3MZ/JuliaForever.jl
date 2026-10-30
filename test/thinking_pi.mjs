import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { readFile } from "node:fs/promises";
const source = process.argv[2];
const data = JSON.parse(await readFile(join(source, "node_modules/@earendil-works/pi-ai/dist/providers/data/openai.json")));
const model = data["openai-responses"]["chat:gpt-5.2"];
const { streamSimple } = await import(pathToFileURL(join(source, "packages/ai/src/api/openai-responses.ts")));
let payload;
const response = streamSimple(model, { messages: [{ role: "user", content: "hello", timestamp: 0 }] }, {
    apiKey: "synthetic", reasoning: "high", onPayload: value => { payload = value; },
    fetch: async () => new Response('data: {"type":"response.completed","response":{"status":"completed","output":[]}}\n\n', { headers: { "content-type": "text/event-stream" } }),
});
await response.result();
process.stdout.write(JSON.stringify(payload.reasoning));
