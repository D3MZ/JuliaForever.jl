import { pathToFileURL } from "node:url";

const { McpClient, StreamableHttpTransport } = await import(pathToFileURL(`${process.env.PI_SOURCE}/packages/mcp/src/index.ts`).href);
const client = new McpClient({ name: "JuliaForever", version: "0.1.0", requestTimeoutMs: 1200 });
client.onError(() => {});
await client.connect(new StreamableHttpTransport({ url: process.env.JF_HTTP_URL, openGetStream: false }));
const outcomes = {};
for (const method of process.argv.slice(2)) {
  try {
    outcomes[method] = method === "concurrent"
      ? { results: await Promise.all([client.request("first", {}), client.request("multiple", {})]) }
      : { result: await client.request(method, {}) };
  } catch (error) {
    outcomes[method] = { error: error.name, message: error.message };
  }
}
await client.close();
process.stdout.write(JSON.stringify(outcomes));
