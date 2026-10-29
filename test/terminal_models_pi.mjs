import { join } from "node:path";
import { pathToFileURL } from "node:url";

const source = process.argv[2];
const { parseArgs } = await import(pathToFileURL(join(source, "packages/coding-agent/src/cli/args.ts")));
const cases = [
    ["--provider", "openai", "--model", "chat-cli", "hello"],
    ["--model", "vendor/cli", "--provider", "openrouter", "hello"],
    ["--provider", "openai", "--provider", "openrouter", "--model", "first", "--model", "last", "hello"],
];
console.log(JSON.stringify(cases.map(args => parseArgs(args))));
