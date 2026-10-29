import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [source, input] = process.argv.slice(2);
const { loadProjectContextFiles } = await import(pathToFileURL(join(source, "packages/coding-agent/src/core/resource-loader.ts")));
const { buildSystemPromptSections } = await import(pathToFileURL(join(source, "packages/coding-agent/src/core/system-prompt.ts")));
const cases = JSON.parse(await readFile(input, "utf8"));
process.stdout.write(JSON.stringify(cases.map(item => {
    const files = loadProjectContextFiles(item);
    const sections = buildSystemPromptSections({ cwd: item.cwd, contextFiles: files });
    return { files, context: sections.project_context ?? null };
})));
