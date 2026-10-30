import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [source, workspace] = process.argv.slice(2);
const { createReadToolDefinition } = await import(pathToFileURL(join(source, "packages/coding-agent/src/core/tools/read.ts")));
const tool = createReadToolDefinition(workspace, { autoResizeImages: false });
const results = [];
for (const args of [{ path: "pixels.txt", offset: 9, limit: 1 }, { path: "photo.bin" }]) {
    const result = await tool.execute("fixture", args);
    results.push(result.content);
}
process.stdout.write(JSON.stringify(results));
