import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { readFile } from 'node:fs/promises';
const [source, id, level, maximum, replay] = process.argv.slice(2);
const data = JSON.parse(await readFile(join(source, 'node_modules/@earendil-works/pi-ai/dist/providers/data/anthropic.json')));
const model = data['anthropic-messages'][`chat:${id}`];
const { streamSimple } = await import(pathToFileURL(join(source, 'packages/ai/src/api/anthropic-messages.ts')));
let body, headers;
const messages = [{ role: 'user', content: 'hello', timestamp: 0 }];
if (replay) messages.push({ role: 'assistant', api: 'anthropic-messages', provider: 'anthropic', model: id, content: [{ type: 'thinking', thinking: 'thought', thinkingSignature: 'signed' }, { type: 'text', text: 'answer' }], usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: 'stop', timestamp: 1 }, { role: 'user', content: 'second', timestamp: 2 });
const response = streamSimple(model, { messages }, {
  apiKey: 'synthetic', maxTokens: maximum ? Number(maximum) : undefined, reasoning: level === 'off' ? undefined : level, cacheRetention: 'none',
  fetch: async (url, init) => { body = JSON.parse(init.body); headers = Object.fromEntries(new Headers(init.headers)); return new Response('event: message_start\ndata: {"type":"message_start","message":{"usage":{}}}\n\nevent: message_stop\ndata: {"type":"message_stop"}\n\n', { headers: { 'content-type': 'text/event-stream' } }); },
});
await response.result();
process.stdout.write(JSON.stringify({body, headers}));
