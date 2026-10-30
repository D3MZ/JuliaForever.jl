import { pathToFileURL } from "node:url";
import { join } from "node:path";

const [source, path] = process.argv.slice(2);
const { SessionManager } = await import(pathToFileURL(join(source, "packages/coding-agent/src/core/session-manager.ts")));
const session = SessionManager.open(path);
const branch = session.getBranch();
const context = session.buildSessionContext();
console.log(JSON.stringify({
  types: branch.map(entry => entry.type),
  roles: context.messages.map(message => message.role),
  contents: context.messages.map(message => message.content),
}));
