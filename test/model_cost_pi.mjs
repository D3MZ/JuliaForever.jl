import { pathToFileURL } from "node:url";
import { join } from "node:path";
import { readFileSync } from "node:fs";

const source = process.argv[2];
const { calculateCost } = await import(pathToFileURL(join(source, "packages/ai/src/models.ts")));
const rates = { input: 2, output: 4, cacheRead: 0.5, cacheWrite: 1, tiers: [{ inputTokensAbove: 130, input: 4, output: 8, cacheRead: 1, cacheWrite: 2 }] };
function price(input, output, cacheRead, cacheWrite, cacheWrite1h = 0) {
    const usage = { input, output, cacheRead, cacheWrite, cacheWrite1h, totalTokens: input + output + cacheRead + cacheWrite, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
    return calculateCost({ cost: rates }, usage);
}
const data = JSON.parse(readFileSync(join(source, "node_modules/@earendil-works/pi-ai/dist/providers/data/openai.json"), "utf8"));
const builtin = { input: 100, output: 20, cacheRead: 30, cacheWrite: 10, totalTokens: 160, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
calculateCost(data["openai-responses"]["chat:gpt-5.4"], builtin);
console.log(JSON.stringify([price(100, 20, 30, 10), price(50, 10, 5, 0), price(100, 20, 30, 10, 4), builtin.cost]));
