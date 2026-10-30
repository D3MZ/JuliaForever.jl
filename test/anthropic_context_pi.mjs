import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const source = process.argv[2];
const id = "claude-sonnet-4-5";
const data = JSON.parse(await readFile(`${source}/node_modules/@earendil-works/pi-ai/dist/providers/data/anthropic.json`));
const { streamSimple } = await import(pathToFileURL(`${source}/packages/ai/src/api/anthropic-messages.ts`));

async function request(thought, tokens, target = id, reasoning = "high") {
    const model = data["anthropic-messages"][`chat:${target}`];
    const messages = [
        { role: "user", content: "hi", timestamp: 1 },
        { role: "assistant", api: "anthropic-messages", provider: "anthropic", model: id, content: [{ type: "thinking", thinking: thought, thinkingSignature: "signed" }, { type: "text", text: "answer" }], usage: { input: tokens, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: tokens, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: "stop", timestamp: 2 },
        { role: "user", content: "next", timestamp: 3 },
    ];
    let body;
    const stream = streamSimple(model, { messages }, {
        apiKey: "synthetic", reasoning, cacheRetention: "none",
        fetch: async (url, init) => {
            body = JSON.parse(init.body);
            return new Response('event: message_start\ndata: {"type":"message_start","message":{"usage":{}}}\n\nevent: message_stop\ndata: {"type":"message_stop"}\n\n', { headers: { "content-type": "text/event-stream" } });
        },
    });
    await stream.result();
    return { max_tokens: body.max_tokens, thinking: body.thinking, assistant: body.messages[1].content };
}
process.stdout.write(JSON.stringify({ measured: await request("thought", 190000), estimated: await request("x".repeat(500000), 0), switched: await request("thought", 190000, "claude-haiku-4-5"), off: await request("thought", 190000, id, null) }));
