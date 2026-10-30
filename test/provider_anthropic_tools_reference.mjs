import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
const source = process.argv[2];
const data = JSON.parse(await readFile(join(source, 'node_modules/@earendil-works/pi-ai/dist/providers/data/anthropic.json')));
const base = data['anthropic-messages']['chat:claude-sonnet-4-5'];
const { stream } = await import(pathToFileURL(join(source, 'packages/ai/src/api/anthropic-messages.ts')));
const tool = { name: 'read', description: 'Read a file', parameters: { type: 'object', properties: { path: { type: 'string' } } } };
const output = [];
for (const [compat, tools] of [[undefined, [tool]], [{ supportsEagerToolInputStreaming: false }, [tool]], [{ supportsEagerToolInputStreaming: false }, []]]) {
  let request;
  const fetch = async (url, init) => {
    request = { body: JSON.parse(init.body), beta: new Headers(init.headers).get('anthropic-beta') };
    return new Response('event: message_start\ndata: {"type":"message_start","message":{"usage":{}}}\n\nevent: message_stop\ndata: {"type":"message_stop"}\n\n', { headers: { 'content-type': 'text/event-stream' } });
  };
  await stream({ ...base, compat: { ...base.compat, ...compat } }, { messages: [...(tools.length ? [{ role: 'system', content: '', toolsAdded: tools, timestamp: 0 }] : []), { role: 'user', content: 'hi', timestamp: 1 }] }, { apiKey: 'synthetic', fetch, cacheRetention: 'none' }).result();
  output.push(request);
}
process.stdout.write(JSON.stringify(output));
