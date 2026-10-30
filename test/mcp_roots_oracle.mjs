import { pathToFileURL } from "node:url";

const { McpClient, StdioTransport, StreamableHttpTransport } = await import(pathToFileURL(`${process.env.PI_SOURCE}/packages/mcp/src/index.ts`).href);
const fixture = `${process.env.JF_PROJECT}/test/mcp_roots_server.mjs`;

async function connect(roots) {
  const options = { name: "JuliaForever", version: "0.1.0" };
  if (roots !== undefined) options.roots = roots;
  const client = new McpClient(options);
  const transport = process.env.JF_ROOTS_HTTP_URL
    ? new StreamableHttpTransport({ url: process.env.JF_ROOTS_HTTP_URL, openGetStream: false })
    : new StdioTransport({ command: process.execPath, args: [fixture] });
  await client.connect(transport);
  return client;
}

async function check(client) {
  return client.request("fixture/check", {});
}

async function once(roots) {
  const client = await connect(roots);
  try { return await check(client); } finally { await client.close(); }
}

const absent = await once(undefined);
const empty = await once([]);
const fixed = await once([{ uri: "file:///workspace", name: "workspace" }, { uri: "file:///other" }]);
let current = [{ uri: "file:///first", name: "first" }];
let dynamic;
dynamic = await connect(async () => {
  const reply = await dynamic.request("fixture/pulse", {});
  if (!reply.pulse) throw new Error("missing pulse");
  return current;
});
try {
  const first = await check(dynamic);
  current = [{ uri: "file:///second", name: "second" }];
  const second = await check(dynamic);
  const failed = await once(() => { throw new Error("root lookup failed"); });
  console.log(JSON.stringify({ absent, empty, fixed, first, second, failed }));
} finally {
  await dynamic.close();
}
