import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [source, input] = process.argv.slice(2);
const { estimateMessageTokens, estimateContextTokens } = await import(pathToFileURL(join(source, "packages/ai/src/utils/estimate.ts")));
const cases = JSON.parse(await readFile(input, "utf8"));
process.stdout.write(JSON.stringify(cases.map(messages => ({ messages: messages.map(estimateMessageTokens), context: estimateContextTokens(messages) }))));
