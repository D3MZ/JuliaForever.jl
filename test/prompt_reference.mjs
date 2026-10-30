import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [source, input] = process.argv.slice(2);
const { loadPromptTemplates, expandPromptTemplate } = await import(pathToFileURL(join(source, "packages/coding-agent/src/core/prompt-templates.ts")));
const { cwd, agentDir, prompts } = JSON.parse(await readFile(input, "utf8"));
const { templates, diagnostics } = loadPromptTemplates({ cwd, agentDir, promptPaths: [], includeDefaults: true });
process.stdout.write(JSON.stringify({ expanded: prompts.map(prompt => expandPromptTemplate(prompt, templates)), diagnostics: diagnostics.map(diagnostic => diagnostic.path) }));
