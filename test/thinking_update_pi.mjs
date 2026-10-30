import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { readFile } from 'node:fs/promises';

const [source, scenario] = process.argv.slice(2);
const steps = JSON.parse(scenario);
const models = JSON.parse(await readFile(join(source, 'node_modules/@earendil-works/pi-ai/dist/providers/data/openai.json')))["openai-responses"];
const { streamSimple } = await import(pathToFileURL(join(source, 'packages/ai/src/api/openai-responses.ts')));
const history = [];
const results = [];
for (const [index, step] of steps.entries()) {
    if (step.toolResult) {
        history.push({ role: 'toolResult', toolCallId: 'call_1|fc_1', toolName: 'write', content: [{ type: 'text', text: 'written' }], isError: false, timestamp: 0 });
    } else {
        history.push({ role: 'user', content: `turn ${index}`, timestamp: 0 });
    }
    const item = step.tool ? { type: 'function_call', id: 'fc_1', call_id: 'call_1', name: 'write', arguments: '{}', status: 'completed' } : { type: 'message', id: `msg_${index}`, role: 'assistant', status: 'completed', content: [{ type: 'output_text', text: 'fixture', annotations: [] }] };
    const events = [{ type: 'response.created', response: { id: `resp_${index}` } }, { type: 'response.output_item.added', output_index: 0, item }, { type: 'response.output_item.done', output_index: 0, item }, { type: 'response.completed', response: { id: `resp_${index}`, status: 'completed' } }];
    let payload;
    const response = streamSimple(models[`chat:${step.model}`], { messages: history }, {
        apiKey: 'sk-synthetic', reasoning: step.level, onPayload: value => { payload = value; },
        fetch: async () => new Response(events.map(event => `data: ${JSON.stringify(event)}\n\n`).join(''), { headers: { 'content-type': 'text/event-stream' } }),
    });
    const message = await response.result();
    results.push({ reasoning: payload.reasoning, updates: payload.input.filter(item => item.type === 'configuration_update'), recorded: message.providerThinkingLevel ?? null });
    history.push(message);
}
process.stdout.write(JSON.stringify(results));
