import { pathToFileURL } from "node:url";
const [source, base] = process.argv.slice(2);
const { stream } = await import(pathToFileURL(`${source}/packages/ai/src/api/openai-completions.ts`));
const model = { id: "fixture", name: "Fixture", api: "openai-completions", provider: "openai", baseUrl: `${base}/v1`, reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 1000, maxTokens: 100 };
const messages = [{ role: "system", content: "base", sections: { rules: "new rules" }, timestamp: 0 }, { role: "user", content: "hello", timestamp: 0 }];
await stream(model, { messages }, { apiKey: "synthetic" }).result();
