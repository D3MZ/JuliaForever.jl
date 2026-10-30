import { pathToFileURL } from "node:url";

const { StdioTransport } = await import(pathToFileURL(`${process.env.PI_SOURCE}/packages/mcp/src/index.ts`).href);
const transport = new StdioTransport({ command: process.execPath, args: [process.env.JF_STDIO_SERVER] });
const pending = new Map();
const errors = [];
transport.onMessage(message => pending.get(message.id)?.(message));
transport.onError(error => errors.push(error.message));
await transport.start();
const results = {};
for (const [index, method] of process.argv.slice(2).entries()) {
  const id = index + 1, before = errors.length;
  let timer;
  const response = new Promise(resolve => { pending.set(id, resolve); timer = setTimeout(() => resolve(null), 15000); });
  await transport.send({ jsonrpc: "2.0", id, method, params: {} });
  const value = await response;
  clearTimeout(timer);
  pending.delete(id);
  results[method] = { length: typeof value?.result === "string" ? value.result.length : null, result: typeof value?.result === "string" ? null : value?.result ?? null, errors: errors.length - before };
}
await transport.close();
process.stdout.write(JSON.stringify(results));
