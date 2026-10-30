import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [source, ...args] = process.argv.slice(2);
const cli = join(source, "packages/coding-agent/src/cli.ts");
process.argv = [process.execPath, cli, ...args];
await import(pathToFileURL(join(source, "packages/coding-agent/src/experimental/source-resolver.ts")).href);
await import(new URL("./pi_catalog_loader.mjs", import.meta.url));
await import(pathToFileURL(cli).href);
