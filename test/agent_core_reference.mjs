import { join } from "node:path";
import { pathToFileURL } from "node:url";

const source = process.argv[2];
const { runAgentLoop } = await import(pathToFileURL(join(source, "packages/agent/src/agent-loop.ts")));
const { createAssistantMessageEventStream } = await import(pathToFileURL(join(source, "packages/ai/src/utils/event-stream.ts")));
const model = { id: "fixture", name: "fixture", api: "openai-responses", provider: "openai", baseUrl: "https://example.invalid", reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 1000, maxTokens: 100 };
const usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
const user = content => ({ role: "user", content, timestamp: 0 });
const assistant = (content, stopReason) => ({ role: "assistant", content, stopReason, api: "openai-responses", provider: "openai", model: "fixture", usage, timestamp: 0 });
const responses = [
    assistant([{ type: "toolCall", id: "one", name: "write", arguments: { path: "a.txt", content: "first" } }, { type: "toolCall", id: "two", name: "write", arguments: { path: "b.txt", content: "second" } }], "toolUse"),
    assistant([{ type: "text", text: "steered one" }], "stop"),
    assistant([{ type: "text", text: "steered two" }], "stop"),
    assistant([{ type: "text", text: "followed" }], "stop"),
];
const tool = { name: "write", label: "Write", description: "Write file", parameters: { type: "object", properties: { path: { type: "string" }, content: { type: "string" } }, required: ["path", "content"] }, execute: async (_id, args) => ({ content: [{ type: "text", text: `Successfully wrote to ${args.path}` }], details: {} }) };
const steering = [];
const followups = [];
const events = [];
const requests = [];
const config = { model, convertToLlm: messages => messages, toolExecution: "sequential", getSteeringMessages: () => steering.splice(0, 1), getFollowUpMessages: () => followups.splice(0, 1) };
const emit = event => {
    if (event.type === "tool_execution_start" && event.toolCallId === "one") {
        steering.push(user("steer one"), user("steer two"));
        followups.push(user("follow up"));
    }
    if (event.message?.role === "system") return;
    const item = { type: event.type };
    if (event.message) item.role = event.message.role === "toolResult" ? "tool" : event.message.role;
    if (event.toolCallId) item.id = event.toolCallId;
    events.push(item);
};
const stream = (_model, context) => {
    requests.push({ users: context.messages.filter(message => message.role === "user").map(message => message.content), tools: context.messages.filter(message => message.role === "toolResult").map(message => message.toolCallId) });
    const result = responses.shift();
    const output = createAssistantMessageEventStream();
    queueMicrotask(() => output.push({ type: "done", reason: result.stopReason, message: result }));
    return output;
};
const messages = await runAgentLoop([user("start")], { messages: [], tools: [tool] }, config, emit, undefined, stream);
process.stdout.write(JSON.stringify({ events, requests, roles: messages.filter(message => message.role !== "system").map(message => message.role === "toolResult" ? "tool" : message.role) }));
