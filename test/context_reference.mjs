import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [source, input] = process.argv.slice(2);
const { buildSystemPromptSections } = await import(pathToFileURL(join(source, "packages/coding-agent/src/core/system-prompt.ts")));
const cases = JSON.parse(await readFile(input, "utf8"));
process.stdout.write(JSON.stringify(cases.map(buildSystemPromptSections)));
