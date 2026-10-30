import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const [source, input] = process.argv.slice(2);
const { models, queries } = JSON.parse(readFileSync(input, "utf8"));
const { fuzzyFilter } = await import(pathToFileURL(`${source}/packages/tui/src/fuzzy.ts`));
const { getModelSearchText } = await import(pathToFileURL(`${source}/packages/coding-agent/src/modes/interactive/model-search.ts`));
const result = queries.map(query => fuzzyFilter(models, query, getModelSearchText).map(model => `${model.provider}/${model.id}`));
process.stdout.write(JSON.stringify(result));
