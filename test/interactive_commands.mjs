import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const source = process.argv[2];
const path = join(source, 'packages/coding-agent/src/core/slash-commands.ts');
const { BUILTIN_SLASH_COMMANDS } = await import(pathToFileURL(path).href);
console.log(JSON.stringify(BUILTIN_SLASH_COMMANDS));
