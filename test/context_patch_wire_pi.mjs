import { pathToFileURL } from "node:url";
const [source, base] = process.argv.slice(2);
const { ExtensionRunner } = await import(pathToFileURL(`${source}/packages/coding-agent/src/core/extensions/runner.ts`));
const { stream } = await import(pathToFileURL(`${source}/packages/ai/src/api/openai-completions.ts`));
const tool = name => ({ name, description: name, parameters: { type: "object", properties: {} } });
const handlers = new Map([["context_with_system", [e => {
  e.messages[0].sections = { zebra: "first", apple: "old" };
  e.messages[0].toolsAdded = [tool("alpha")];
  e.messages.push({ role: "system", content: "extra", sections: { apple: "new", zebra: null, banana: "last" }, toolsRemoved: [{ name: "alpha" }], toolsAdded: [tool("beta")], timestamp: 1 });
}]]]);
const runner = new ExtensionRunner([{ path: "fixture", handlers }], {}, "", {}, {});
const messages = await runner.emitContext([{ role: "system", content: "base", timestamp: 0 }, { role: "user", content: "hello", timestamp: 0 }]);
const model = { id: "fixture", name: "Fixture", api: "openai-completions", provider: "openai", baseUrl: `${base}/v1`, reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 1000, maxTokens: 100 };
await stream(model, { messages }, { apiKey: "synthetic" }).result();
