import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const [source, fixture] = process.argv.slice(2);
const scenarios = JSON.parse(await readFile(fixture, 'utf8'));
const { stream } = await import(pathToFileURL(join(source, 'packages/ai/src/api/anthropic-messages.ts')));
const { convertMessages } = await import(pathToFileURL(join(source, 'packages/ai/src/api/google-shared.ts')));
const usage = {input:0, output:0, cacheRead:0, cacheWrite:0, totalTokens:0, cost:{input:0, output:0, cacheRead:0, cacheWrite:0, total:0}};
const model = (id, api, provider) => ({id, name:id, api, provider, baseUrl:'https://example.invalid', reasoning:false, input:['text','image'], cost:{input:0,output:0,cacheRead:0,cacheWrite:0}, contextWindow:4096, maxTokens:1024});
function messages(raw, selected) {
  const names = new Map();
  return raw.map(item => {
    if (item.role === 'user') return {role:'user',content:item.content,timestamp:0};
    if (item.role === 'assistant') {
      const content = item.tool_calls.map(call => {
        names.set(call.id, call.function.name);
        return {type:'toolCall',id:call.id,name:call.function.name,arguments:JSON.parse(call.function.arguments)};
      });
      return {role:'assistant',content,api:selected.api,provider:selected.provider,model:selected.id,usage,stopReason:'toolUse',timestamp:0};
    }
    const content = [{type:'text',text:item.content}];
    if (item.image) content.push({type:'image',mimeType:item.image.mime,data:item.image.data});
    return {role:'toolResult',toolCallId:item.tool_call_id,toolName:names.get(item.tool_call_id),content,isError:item.is_error ?? false,timestamp:0};
  });
}
const result = [];
for (const raw of scenarios) {
  const anth = model('claude-fixture', 'anthropic-messages', 'anthropic');
  let payload;
  const fetch = async (_url, init) => {
    payload = JSON.parse(init.body);
    const events = [{type:'message_start',message:{id:'id',type:'message',role:'assistant',model:anth.id,content:[],stop_reason:null,usage:{input_tokens:1,output_tokens:0}}},{type:'message_delta',delta:{stop_reason:'end_turn'},usage:{output_tokens:1}},{type:'message_stop'}];
    return new Response(events.map(e => `event: ${e.type}\ndata: ${JSON.stringify(e)}\n\n`).join(''), {headers:{'content-type':'text/event-stream'}});
  };
  await stream(anth, {messages:messages(raw, anth)}, {apiKey:'synthetic',fetch,cacheRetention:'none'}).result();
  const google = {};
  for (const id of ['gemini-2-fixture', 'gemini-3-fixture', 'custom-model']) {
    const selected = model(id, 'google-generative-ai', 'google');
    google[id] = convertMessages(selected, {messages:messages(raw, selected)});
  }
  result.push({anthropic:payload.messages,google});
}
process.stdout.write(JSON.stringify(result));
