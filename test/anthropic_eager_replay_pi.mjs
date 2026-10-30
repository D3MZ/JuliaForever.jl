import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { readFile } from 'node:fs/promises';
const source = process.argv[2];
const data = JSON.parse(await readFile(join(source, 'node_modules/@earendil-works/pi-ai/dist/providers/data/anthropic.json')));
const { streamSimple } = await import(pathToFileURL(join(source, 'packages/ai/src/api/anthropic-messages.ts')));
const tool = { name: 'read', description: 'Read a file', parameters: { type: 'object', properties: { path: { type: 'string' } } } };
const output = {};
for (const [label, target] of [['same', 'claude-sonnet-4-5'], ['switched', 'claude-haiku-4-5']]) {
  const model = data['anthropic-messages'][`chat:${target}`];
  const messages = [
    { role: 'system', content: '', toolsAdded: [tool], timestamp: 0 },
    { role: 'user', content: 'hello', timestamp: 1 },
    { role: 'assistant', api: 'anthropic-messages', provider: 'anthropic', model: 'claude-sonnet-4-5', content: [{ type: 'thinking', thinking: 'thought', thinkingSignature: 'signed' }, { type: 'text', text: 'answer' }], usage: { input: 190000, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 190000, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: 'stop', timestamp: 2 },
    { role: 'user', content: 'next', timestamp: 3 },
  ];
  let body;
  await streamSimple(model, { messages }, { apiKey: 'synthetic', reasoning: 'high', cacheRetention: 'none', fetch: async (url, init) => { body = JSON.parse(init.body); return new Response('event: message_start\ndata: {"type":"message_start","message":{"usage":{}}}\n\nevent: message_stop\ndata: {"type":"message_stop"}\n\n', { headers: { 'content-type': 'text/event-stream' } }); } }).result();
  output[label] = { max_tokens: body.max_tokens, thinking: body.thinking, assistant: body.messages[1].content, eager: body.tools[0].eager_input_streaming };
}
const custom = { ...data['anthropic-messages']['chat:claude-sonnet-4-5'], provider: 'fixture', id: 'custom-model', baseUrl: 'https://fixture.invalid', compat: {} };
await streamSimple(custom, { messages: [{ role: 'system', content: '', toolsAdded: [tool], timestamp: 0 }, { role: 'user', content: 'hello', timestamp: 1 }] }, { apiKey: 'synthetic', cacheRetention: 'none', fetch: async (url, init) => { output.custom = JSON.parse(init.body).tools[0].eager_input_streaming; return new Response('event: message_start\ndata: {"type":"message_start","message":{"usage":{}}}\n\nevent: message_stop\ndata: {"type":"message_stop"}\n\n', { headers: { 'content-type': 'text/event-stream' } }); } }).result();
const overridden = { ...custom, compat: { supportsEagerToolInputStreaming: false }, headers: { 'AnThRoPiC-BeTa': 'custom-beta' } };
await streamSimple(overridden, { messages: [{ role: 'system', content: '', toolsAdded: [tool], timestamp: 0 }, { role: 'user', content: 'hello', timestamp: 1 }] }, { apiKey: 'synthetic', cacheRetention: 'none', fetch: async (url, init) => { output.custombeta = new Headers(init.headers).get('anthropic-beta'); return new Response('event: message_start\ndata: {"type":"message_start","message":{"usage":{}}}\n\nevent: message_stop\ndata: {"type":"message_stop"}\n\n', { headers: { 'content-type': 'text/event-stream' } }); } }).result();
process.stdout.write(JSON.stringify(output));
