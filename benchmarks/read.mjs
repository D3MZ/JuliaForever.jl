import { performance } from "node:perf_hooks";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [source, directory, count] = process.argv.slice(2);
const { createReadToolDefinition } = await import(pathToFileURL(join(source, "packages/coding-agent/src/core/tools/read.ts")));
const tool = createReadToolDefinition(directory);
const args = { path: "sample.txt" };
for (let i = 0; i < 20; i++) await tool.execute("warmup", args);
const start = performance.now();
let result;
for (let i = 0; i < Number(count); i++) result = await tool.execute("benchmark", args);
process.stdout.write(JSON.stringify({ seconds: (performance.now() - start) / 1000, text: result.content[0].text, node: process.version }));
