import { pathToFileURL } from "node:url";

const { StreamableHttpTransport, StdioTransport } = await import(pathToFileURL(`${process.env.PI_SOURCE}/packages/mcp/src/index.ts`).href);
const deadline = setTimeout(() => process.exit(2), 15000);
const mode = process.env.JF_WIRE_MODE;
const transport = mode === "http" ? new StreamableHttpTransport({ url: process.env.JF_HTTP_URL, openGetStream: false }) : new StdioTransport({ command: process.execPath, args: [process.env.JF_STDIO_SERVER] });
const pending = new Map();
const errors = [];
transport.onMessage(message => pending.get(message.id)?.(message));
transport.onError(error => errors.push(error.name));
await transport.start();
const outcomes = {};
for (const [index, method] of process.argv.slice(2).entries()) {
  const id = index + 1;
  const prior = errors.length;
  let timer;
  const response = new Promise(resolve => { pending.set(id, resolve); timer = setTimeout(() => resolve(null), 8000); });
  let failed = false;
  try { await transport.send({ jsonrpc: "2.0", id, method, params: {} }); }
  catch { failed = true; }
  const message = failed ? null : await response;
  clearTimeout(timer);
  pending.delete(id);
  outcomes[method] = { failed, result: message?.result ?? null, error: message?.error ?? null, errors: errors.length - prior };
}
await transport.close();
clearTimeout(deadline);
process.stdout.write(JSON.stringify(outcomes));
