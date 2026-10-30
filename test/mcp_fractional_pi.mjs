import { pathToFileURL } from "node:url";

const { StreamableHttpTransport, StdioTransport } = await import(pathToFileURL(`${process.env.PI_SOURCE}/packages/mcp/src/index.ts`).href);
const deadline = setTimeout(() => process.exit(2), 15000);
const mode = process.env.JF_WIRE_MODE;
const transport = mode === "stdio" ? new StdioTransport({ command: process.execPath, args: [process.env.JF_STDIO_SERVER] }) : new StreamableHttpTransport({ url: process.env.JF_HTTP_URL, openGetStream: false });
const outcomes = {};
let resolve;
transport.onMessage(message => { if (message.id !== undefined) resolve?.(message.error); });
transport.onError(() => {});
await transport.start();
for (const [index, method] of (mode === "stdio" ? ["probe"] : ["json", "sse"]).entries()) {
  const response = new Promise(r => { resolve = r; });
  await transport.send({ jsonrpc: "2.0", id: index + 1, method, params: {} });
  outcomes[method] = await response;
}
await transport.close();
clearTimeout(deadline);
process.stdout.write(JSON.stringify(outcomes));
