import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [source, workspace, ...files] = process.argv.slice(2);
const { createReadToolDefinition } = await import(pathToFileURL(join(source, "packages/coding-agent/src/core/tools/read.ts")));
const { normalizeToolResultImages } = await import(pathToFileURL(join(source, "packages/coding-agent/src/utils/tool-result-images.ts")));
const tool = createReadToolDefinition(workspace);
const results = [];
for (const file of files) {
    const bytes = await readFile(join(workspace, file));
    const mimeType = file.endsWith(".gif") ? "image/gif" : "image/webp";
    const read = await tool.execute("fixture", { path: file });
    const content = await normalizeToolResultImages([{ type: "image", mimeType, data: bytes.toString("base64") }]);
    results.push({ read: read.content, content });
}
process.stdout.write(JSON.stringify(results));
