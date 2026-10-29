import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [source, root, input] = process.argv.slice(2);
const find = await import(pathToFileURL(join(source, "packages/coding-agent/src/core/tools/find.ts")));
const grep = await import(pathToFileURL(join(source, "packages/coding-agent/src/core/tools/grep.ts")));
const tools = { find: find.createFindToolDefinition(root), grep: grep.createGrepToolDefinition(root) };
const cases = JSON.parse(await readFile(input, "utf8"));
const results = [];
for (const item of cases) {
    try {
        const result = await tools[item.tool].execute("fixture", item.args);
        results.push({ text: result.content.find(block => block.type === "text").text.replaceAll(root, "<cwd>"), iserror: result.isError === true });
    } catch (err) {
        results.push({ text: err.message.replaceAll(root, "<cwd>"), iserror: true });
    }
}
process.stdout.write(JSON.stringify(results));
