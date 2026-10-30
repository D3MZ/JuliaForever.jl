import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [source, toolExecution, imageMode, queueMode = "all"] = process.argv.slice(2);
const { Agent } = await import(pathToFileURL(join(source, "packages/agent/src/agent.ts")));
const agent = new Agent({ streamFn() {} });
const { runAgentLoop } = await import(pathToFileURL(join(source, "packages/agent/src/agent-loop.ts")));
const { createAssistantMessageEventStream } = await import(pathToFileURL(join(source, "packages/ai/src/utils/event-stream.ts")));
const model = { id: "fixture", name: "fixture", api: "openai-responses", provider: "openai", baseUrl: "https://example.invalid", reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 1000, maxTokens: 100 };
const usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
const user = content => ({ role: "user", content, timestamp: 0 });
const queued = text => user(imageMode ? [{ type: "text", text }, { type: "image", mimeType: "image/png", data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/aX0AAAAASUVORK5CYII=" }] : text);
const assistant = (content, stopReason) => ({ role: "assistant", content, stopReason, api: "openai-responses", provider: "openai", model: "fixture", usage, timestamp: 0 });
const responses = [
    assistant([{ type: "toolCall", id: "one", name: "write", arguments: { path: "a.txt", content: "first" } }, { type: "toolCall", id: "two", name: "write", arguments: { path: "b.txt", content: "second" } }], "toolUse"),
    assistant([{ type: "text", text: "steered" }], "stop"),
    assistant([{ type: "text", text: "followed" }], "stop"),
    assistant([{ type: "text", text: "followed" }], "stop"),
    assistant([{ type: "text", text: "followed" }], "stop"),
];
let release = () => {};
let gate = Promise.resolve();
let announce = () => {};
let started = Promise.resolve();
let timer;
let timedOut = false;
if (toolExecution === "parallel") {
    const timeout = new Promise((_, reject) => { timer = setTimeout(() => { timedOut = true; reject(new Error("parallel tool gate timed out")); }, 30000); });
    gate = Promise.race([new Promise(resolve => { release = resolve; }), timeout]);
    started = Promise.race([new Promise(resolve => { announce = resolve; }), timeout]);
}
const tool = { name: "write", label: "Write", description: "Write file", parameters: { type: "object", properties: { path: { type: "string" }, content: { type: "string" } }, required: ["path", "content"] }, execute: async (id, args) => { if (id === "one") { announce(); await gate; } else { await started; } return { content: [{ type: "text", text: `Successfully wrote to ${args.path}` }], details: {} }; } };

const events = [];
const requests = [];
const config = { model, convertToLlm: messages => messages, toolExecution, getSteeringMessages: () => agent.steeringQueue.drain(), getFollowUpMessages: () => agent.followUpQueue.drain() };
const emit = event => {
    if (event.type === "tool_execution_end" && event.toolCallId === (toolExecution === "parallel" ? "two" : "one")) {
        agent.steer(queued("steer one")); agent.steer(user("steer two"));
        agent.followUp(queued("follow one")); agent.followUp(user("follow two"));
        agent.steeringMode = queueMode; agent.followUpMode = queueMode;
        release();
    }
    if (event.message?.role === "system") return;
    const item = { type: event.type };
    if (event.message) item.role = event.message.role === "toolResult" ? "tool" : event.message.role;
    if (event.toolCallId) item.id = event.toolCallId;
    events.push(item);
};
const stream = (_model, context) => {
    const visible = context.messages.filter(message => message.role !== "system");
    requests.push(visible.map(message => {
        if (message.role === "user") {
            if (Array.isArray(message.content)) return { role: "user", content: message.content[0].text, images: message.content.slice(1).map(image => ({ mime: image.mimeType, data: image.data })) };
            return { role: "user", content: message.content };
        }
        if (message.role === "toolResult") return { role: "tool", id: message.toolCallId, content: message.content.map(item => item.text).join(""), is_error: message.isError };
        const text = message.content.filter(item => item.type === "text").map(item => item.text);
        const calls = message.content.filter(item => item.type === "toolCall").map(item => ({ id: item.id, name: item.name, arguments: item.arguments }));
        return { role: "assistant", content: text.length ? text.join("") : null, calls };
    }));
    const result = responses.shift();
    const output = createAssistantMessageEventStream();
    queueMicrotask(() => output.push({ type: "done", reason: result.stopReason, message: result }));
    return output;
};
let messages;
try {
    messages = await runAgentLoop([user("start")], { messages: [], tools: [tool] }, config, emit, undefined, stream);
} finally {
    clearTimeout(timer);
}
if (timedOut) throw new Error("parallel tool gate timed out");
process.stdout.write(JSON.stringify({ events, requests, roles: messages.filter(message => message.role !== "system").map(message => message.role === "toolResult" ? "tool" : message.role) }));
