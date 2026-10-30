import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [source, input] = process.argv.slice(2);
const { cwd, agentDir } = JSON.parse(await readFile(input, "utf8"));
const { DefaultResourceLoader } = await import(pathToFileURL(join(source, "packages/coding-agent/src/core/resource-loader.ts")));
const { buildSystemPromptSections } = await import(pathToFileURL(join(source, "packages/coding-agent/src/core/system-prompt.ts")));
const loader = new DefaultResourceLoader({ cwd, agentDir });
await loader.reload();
const { skills } = loader.getSkills();
const metadata = skills.map(({ name, description, filePath, baseDir, disableModelInvocation }) => ({ name, description, filePath, baseDir, disableModelInvocation }));
const sections = buildSystemPromptSections({ cwd, skills });
process.stdout.write(JSON.stringify({ metadata, section: sections.skills ?? null }));
