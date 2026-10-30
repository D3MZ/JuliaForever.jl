import { join } from "node:path";
import { pathToFileURL } from "node:url";

const source = process.argv[2];
const { runAgentLoop } = await import(pathToFileURL(join(source, "packages/agent/src/agent-loop.ts")));
const { createAssistantMessageEventStream } = await import(pathToFileURL(join(source, "packages/ai/src/utils/event-stream.ts")));
const model = { id: "fixture", name: "fixture", api: "openai-responses", provider: "openai", baseUrl: "https://example.invalid", reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 1000, maxTokens: 100 };
const usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
const assistant = (content, stopReason) => ({ role: "assistant", content, stopReason, api: "openai-responses", provider: "openai", model: "fixture", usage, timestamp: 0 });
const replies = [
    assistant([{ type: "text", text: "partial" }, { type: "toolCall", id: "one", name: "write", arguments: { path: "unsafe.txt", content: "partial" } }], "length"),
    assistant([{ type: "text", text: "recovered" }], "stop"),
];
let executions = 0;
let requests = 0;
const tool = { name: "write", label: "Write", description: "Write file", parameters: { type: "object", properties: {} }, execute: async () => { executions++; return { content: [{ type: "text", text: "written" }], details: {} }; } };
const stream = () => {
    requests++;
    const message = replies.shift();
    const output = createAssistantMessageEventStream();
    queueMicrotask(() => output.push({ type: "done", reason: message.stopReason, message }));
    return output;
};
const config = { model, convertToLlm: messages => messages, toolExecution: "sequential" };
const messages = await runAgentLoop([{ role: "user", content: "start", timestamp: 0 }], { messages: [], tools: [tool] }, config, () => {}, undefined, stream);
const toolResult = messages.find(message => message.role === "toolResult");
const final = messages.at(-1);
process.stdout.write(JSON.stringify({ executions, requests, output: final.content.find(content => content.type === "text").text, toolError: toolResult.isError, limitMessage: toolResult.content.some(content => content.text?.includes("output token limit")) }));
