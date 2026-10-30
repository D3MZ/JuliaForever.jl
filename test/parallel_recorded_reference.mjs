import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
const source = process.argv[2];
const { runAgentLoop } = await import(pathToFileURL(join(source, 'packages/agent/src/agent-loop.ts')));
const { createAssistantMessageEventStream } = await import(pathToFileURL(join(source, 'packages/ai/src/utils/event-stream.ts')));
const model = { id: 'fixture', name: 'fixture', api: 'openai-responses', provider: 'openai', baseUrl: 'https://example.invalid', reasoning: false, input: ['text'], cost: {input: 0, output: 0, cacheRead: 0, cacheWrite: 0}, contextWindow: 1000, maxTokens: 100 };
const usage = {input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: {input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0}};
const assistant = (content, stopReason) => ({role: 'assistant', content, stopReason, api: 'openai-responses', provider: 'openai', model: 'fixture', usage, timestamp: 0});
const replies = [assistant([{type:'toolCall', id:'one', name:'ordered', arguments:{value:'one'}}, {type:'toolCall', id:'two', name:'ordered', arguments:{value:'two'}}], 'toolUse'), assistant([{type:'text', text:'done'}], 'stop')];
let release;
const gate = new Promise(resolve => { release = resolve; });
const trace = [];
const tool = {name:'ordered', label:'Ordered', description:'Fixture', parameters:{type:'object', properties:{value:{type:'string'}}, required:['value']}, execute: async (id, args) => { if (id === 'one') await gate; return {content:[{type:'text', text:args.value}], details:{}}; }};
const config = {model, convertToLlm: messages => messages, beforeToolCall: async ({toolCall}) => { trace.push(`before:${toolCall.id}`); }};
const emit = event => {
    if (event.type === 'tool_execution_start') trace.push(`start:${event.toolCallId}`);
    if (event.type === 'tool_execution_end') { trace.push(`end:${event.toolCallId}`); if (event.toolCallId === 'two') release(); }
    if (event.type === 'message_end' && event.message?.role === 'toolResult') trace.push(`message:${event.message.toolCallId}`);
};
const stream = () => { const reply = replies.shift(); const output = createAssistantMessageEventStream(); queueMicrotask(() => output.push({type:'done', reason:reply.stopReason, message:reply})); return output; };
await runAgentLoop([{role:'user', content:'start', timestamp:0}], {messages:[], tools:[tool]}, config, emit, undefined, stream);
process.stdout.write(JSON.stringify(trace));
