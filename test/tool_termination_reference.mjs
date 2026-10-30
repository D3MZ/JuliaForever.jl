import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
const root = process.argv[2];
const { runAgentLoop } = await import(pathToFileURL(join(root, 'packages/agent/src/agent-loop.ts')));
const { createAssistantMessageEventStream } = await import(pathToFileURL(join(root, 'packages/ai/src/utils/event-stream.ts')));
const model = { id:'fixture', name:'fixture', api:'openai-responses', provider:'openai', baseUrl:'https://example.invalid', reasoning:false, input:['text'], cost:{input:0,output:0,cacheRead:0,cacheWrite:0}, contextWindow:1000, maxTokens:100 };
const usage = {input:0,output:0,cacheRead:0,cacheWrite:0,totalTokens:0,cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0}};
const assistant = (content, stopReason) => ({role:'assistant',content,stopReason,api:'openai-responses',provider:'openai',model:'fixture',usage,timestamp:0});
const output = {};
for (const mode of ['sequential', 'parallel']) for (const scenario of ['all', 'mixed', 'result']) {
  let requests = 0; const seen = [], messages = [];
  const calls = ['one','two'].map(id => ({type:'toolCall',id,name:'echo',arguments:{}}));
  const replies = [assistant(calls,'toolUse'),assistant([{type:'text',text:'done'}],'stop')];
  const tool = {name:'echo',label:'echo',description:'echo',parameters:{type:'object'},execute:async () => ({content:[{type:'text',text:'executed'}],details:{}})};
  const config = {model,toolExecution:mode,convertToLlm: m => m,beforeToolCall:({toolCall}) => toolCall.id === 'one' || scenario === 'all' ? {block:true,reason:'denied',terminate:true} : undefined,afterToolCall:({toolCall}) => {seen.push(toolCall.id); return scenario === 'result' ? {content:[{type:'text',text:'changed'}],terminate:true} : undefined;}};
  const stream = () => { requests++; const reply = replies.shift(), out = createAssistantMessageEventStream(); queueMicrotask(() => out.push({type:'done',reason:reply.stopReason,message:reply})); return out; };
  await runAgentLoop([{role:'user',content:'go',timestamp:0}],{messages:[],tools:[tool]},config,e => {if(e.type === 'message_end' && e.message.role === 'toolResult') messages.push(e.message.content[0].text);},undefined,stream);
  output[`${mode}:${scenario}`] = {requests,seen,messages};
}
process.stdout.write(JSON.stringify(output));
