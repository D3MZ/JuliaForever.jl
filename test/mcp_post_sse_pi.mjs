import { pathToFileURL } from "node:url";

const { StreamableHttpTransport } = await import(pathToFileURL(`${process.env.PI_SOURCE}/packages/mcp/src/index.ts`).href);
const deadline = setTimeout(() => process.exit(2), 15000);
const getStream = process.env.JF_GET_STREAM === "1";
const transport = new StreamableHttpTransport({ url: process.env.JF_HTTP_URL, openGetStream: getStream, reconnect: { maxRetries: 0 } });
const pending = new Map();
const errors = [];
transport.onMessage(message => pending.get(message.id)?.(message));
transport.onError(error => errors.push(error.name));
await transport.start();
if (getStream) await transport.send({ jsonrpc: "2.0", method: "notifications/initialized" });
const outcomes = {};
for (const [index, method] of process.argv.slice(2).entries()) {
  const id = index + 1;
  const prior = errors.length;
  let timer;
  const response = new Promise(resolve => {
    pending.set(id, resolve);
    timer = setTimeout(() => resolve(null), 10000);
  });
  await transport.send({ jsonrpc: "2.0", id, method, params: {} });
  const message = await response;
  clearTimeout(timer);
  pending.delete(id);
  outcomes[method] = { result: message?.result ?? null, error: message?.error ?? null, errors: errors.length - prior };
  if (getStream) await fetch(`${process.env.JF_HTTP_URL}/release`, { method: "POST" });
}
await transport.close();
clearTimeout(deadline);
process.stdout.write(JSON.stringify(outcomes));
