import { register, createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import { join } from 'node:path';
register('./tool_options_loader.mjs', import.meta.url);
const root = process.argv[2];
const scenario = process.argv[3] ?? 'text';
const { agentLoop } = await import(pathToFileURL(join(root, 'packages/agent/src/agent-loop.ts')));
const { createAssistantMessageEventStream } = await import(pathToFileURL(join(root, 'packages/ai/src/utils/event-stream.ts')));
const { toJsonEvent } = await import(pathToFileURL(join(root, 'packages/coding-agent/src/modes/json-event.ts')));
const require = createRequire(join(root, 'package.json'));
const Type = await import(pathToFileURL(require.resolve('typebox')));
const usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: {input:0, output:0, cacheRead:0, cacheWrite:0, total:0} };
const model = {id:'fixture', name:'fixture', api:'openai-completions', provider:'openai', baseUrl:'', reasoning:false, input:['text'], cost:{input:0,output:0,cacheRead:0,cacheWrite:0}, contextWindow:8192,maxTokens:1024};
const message = (content, stopReason) => ({role:'assistant', content, api:model.api, provider:model.provider, model:model.id, usage, stopReason, timestamp:1});
const partial = content => message(content, 'pending');
let turn = 0;
const streamFn = () => {
    const stream = createAssistantMessageEventStream();
    const tool = scenario === 'tool' && turn++ === 0;
    const text = tool ? 'Before ' : scenario === 'tool' ? 'after' : 'reply:hello';
    const block = {type:'text', text};
    queueMicrotask(() => {
        stream.push({type:'start', partial:partial([])});
        stream.push({type:'text_start', contentIndex:0, partial:partial([{type:'text',text:''}])});
        stream.push({type:'text_delta', contentIndex:0, delta:text, partial:partial([block])});
        stream.push({type:'text_end', contentIndex:0, content:text, partial:partial([block])});
        if (tool) {
            const call = {type:'toolCall', id:'call-1', name:'read', arguments:{path:'sample.txt'}};
            stream.push({type:'toolcall_start', contentIndex:1, partial:partial([block, call])});
            stream.push({type:'toolcall_delta', contentIndex:1, delta:'{"path":', partial:partial([block, call])});
            stream.push({type:'toolcall_delta', contentIndex:1, delta:'"sample.txt"}', partial:partial([block, call])});
            stream.push({type:'toolcall_end', contentIndex:1, toolCall:call, partial:partial([block, call])});
            stream.push({type:'done', reason:'toolUse', message:message([block, call], 'toolUse')});
        } else {
            stream.push({type:'done', reason:'stop', message:message([block], 'stop')});
        }
    });
    return stream;
};
const tools = scenario === 'tool' ? [{name:'read',label:'Read',description:'Read a file',parameters:Type.Object({path:Type.String()}), execute:async () => ({content:[{type:'text',text:'file content'}],details:{}})}] : [];
const events = [];
const declarations = tools.map(({name,description,parameters}) => ({name,description,parameters}));
const initial = declarations.length ? [{role:'system',content:'',toolsAdded:declarations,timestamp:1}] : [];
const stream = agentLoop([{role:'user',content:'hello',timestamp:1}], {messages:initial,tools}, {model,convertToLlm:messages=>messages}, undefined, streamFn);
for await (const event of stream) events.push(toJsonEvent(event));
events.push({type:'agent_settled',aborted:false});
process.stdout.write(JSON.stringify(events));
