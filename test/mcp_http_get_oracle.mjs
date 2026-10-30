import { pathToFileURL } from "node:url";
const { McpClient, StreamableHttpTransport } = await import(pathToFileURL(`${process.env.PI_SOURCE}/packages/mcp/src/index.ts`).href);
const client = new McpClient({ name: "JuliaForever", version: "0.1.0", roots: [{ uri: "file:///workspace" }] });
client.onError(() => {});
await client.connect(new StreamableHttpTransport({ url: process.env.JF_HTTP_URL, headers: { Authorization: "Bearer secret" }, reconnect: { maxRetries: 0 } }));
await new Promise(resolve => setTimeout(resolve, 1500));
await client.close();
