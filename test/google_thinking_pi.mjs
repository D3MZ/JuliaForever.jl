import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { readFile } from 'node:fs/promises';
const [source, id, level] = process.argv.slice(2);
const data = JSON.parse(await readFile(join(source, 'node_modules/@earendil-works/pi-ai/dist/providers/data/google.json')));
const model = Object.values(data['google-generative-ai']).find(m => m.id === id);
const { clampThinkingLevel } = await import(pathToFileURL(join(source, 'packages/ai/src/models.ts')));
const { streamSimple } = await import(pathToFileURL(join(source, 'packages/ai/src/api/google-generative-ai.ts')));
let payload;
globalThis.fetch = async (_url, init) => { payload = JSON.parse(init.body); return new Response('data: {"candidates":[{"content":{"parts":[{"text":"ok"}]},"finishReason":"STOP"}]}\n\n', { headers: { "content-type": "text/event-stream" } }); };
const response = streamSimple(model, { messages: [{ role: 'user', content: 'hello', timestamp: 0 }] }, {
  apiKey: 'synthetic', reasoning: clampThinkingLevel(model, level),
});
await response.result();
process.stdout.write(JSON.stringify(payload));
