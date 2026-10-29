import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [source, path] = process.argv.slice(2);
const { stream } = await import(pathToFileURL(join(source, "packages/ai/src/api/anthropic-messages.ts")));
const events = JSON.parse(await readFile(path, "utf8"));
const model = { id: "claude-fixture", name: "Fixture", api: "anthropic-messages", provider: "anthropic", baseUrl: "https://api.anthropic.com", reasoning: true, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 1000, maxTokens: 90 };
let payload;
const fetch = async (url, init) => {
  payload = JSON.parse(init.body);
  return new Response(events.map(event => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`).join(""), { headers: { "content-type": "text/event-stream" } });
};
const result = await stream(model, { messages: [{ role: "user", content: "hi", timestamp: 0 }] }, { apiKey: "synthetic", fetch, cacheRetention: "none" }).result();
process.stdout.write(JSON.stringify({ result, payload }));
