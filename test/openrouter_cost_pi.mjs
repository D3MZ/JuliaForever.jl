import { pathToFileURL } from "node:url";
import { join } from "node:path";

const source = process.argv[2];
const { applyOpenRouterReportedCost } = await import(pathToFileURL(join(source, "packages/ai/src/utils/openrouter-cost.ts")));
const cases = [
    { cost: 0.012, is_byok: false },
    { cost: 0.012, is_byok: true, cost_details: null },
    { cost: 0.012, is_byok: true, cost_details: { upstream_inference_cost: null, upstream_inference_prompt_cost: 0.001, upstream_inference_completions_cost: 0.002 } },
    { cost: -1, is_byok: false },
    { cost: 0.012 },
];
console.log(JSON.stringify(cases.map(value => {
    const usage = { cost: { total: 0.00061, totalFromProvider: false } };
    applyOpenRouterReportedCost(usage, value);
    return usage.cost;
})));
