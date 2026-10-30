import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { readFile } from 'node:fs/promises';
const source = process.argv[2];
const data = JSON.parse(await readFile(join(source, 'node_modules/@earendil-works/pi-ai/dist/providers/data/anthropic.json')));
const { streamSimple } = await import(pathToFileURL(join(source, 'packages/ai/src/api/anthropic-messages.ts')));
const tool = { name: 'read', description: 'Read a file', parameters: { type: 'object', properties: { path: { type: 'string' } } } };
const output = [];
for (const eager of [true, false]) for (const level of ['off', 'high']) for (const exposed of [true, false]) {
  const base = data['anthropic-messages']['chat:claude-sonnet-4-5'];
  const model = { ...base, compat: { ...base.compat, supportsEagerToolInputStreaming: eager } };
  const messages = [...(exposed ? [{ role: 'system', content: '', toolsAdded: [tool], timestamp: 0 }] : []), { role: 'user', content: 'hello', timestamp: 1 }];
  let wire;
  await streamSimple(model, { messages }, {
    apiKey: 'synthetic', reasoning: level === 'off' ? undefined : level, cacheRetention: 'none',
    fetch: async (url, init) => { wire = { body: JSON.parse(init.body), beta: new Headers(init.headers).get('anthropic-beta') }; return new Response('event: message_start\ndata: {"type":"message_start","message":{"usage":{}}}\n\nevent: message_stop\ndata: {"type":"message_stop"}\n\n', { headers: { 'content-type': 'text/event-stream' } }); },
  }).result();
  output.push({ eager, level, exposed, ...wire });
}
process.stdout.write(JSON.stringify(output));
