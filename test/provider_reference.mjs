import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [source, path] = process.argv.slice(2);
const { stream } = await import(pathToFileURL(join(source, "packages/ai/src/api/openai-completions.ts")));
const chunks = JSON.parse(await readFile(path, "utf8"));
const model = { id: "vendor/model", name: "Fixture", api: "openai-completions", provider: "openrouter", baseUrl: "https://openrouter.ai/api/v1", reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 1000, maxTokens: 100 };
const fetch = async () => new Response(chunks.map(chunk => `data: ${JSON.stringify(chunk)}\n\n`).join("") + "data: [DONE]\n\n", { headers: { "content-type": "text/event-stream" } });
const result = await stream(model, { messages: [{ role: "user", content: "hi", timestamp: 0 }] }, { apiKey: "synthetic", fetch }).result();
process.stdout.write(JSON.stringify(result));
