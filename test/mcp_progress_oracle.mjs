import { pathToFileURL } from "node:url";

const { McpClient, StdioTransport } = await import(pathToFileURL(`${process.env.PI_SOURCE}/packages/mcp/src/index.ts`).href);
const client = new McpClient({ name: "JuliaForever", version: "0.1.0" });
const transport = new StdioTransport({ command: process.execPath, args: [`${process.env.JF_PROJECT}/test/mcp_progress_server.mjs`] });
const seenErrors = [];
client.onError((error) => seenErrors.push(error.message));
try {
  await client.connect(transport);
  const probeEvents = [];
  const probe = await client.request("probe", { _meta: { preserved: "yes", progressToken: "replace" } }, { onProgress: (event) => probeEvents.push(event) });
  const plain = await client.request("plain", { value: 1 });
  const pairedEvents = [[], []];
  const pair = await Promise.all([1, 2].map((label, index) => client.request("pair", { label }, { onProgress: (event) => pairedEvents[index].push(event) })));
  const slowEvents = [];
  const slow = await client.request("slow", {}, { timeoutMs: 1000, onProgress: (event) => slowEvents.push(event) });
  const throwEvents = [];
  const thrown = await client.request("throw", {}, { onProgress: (event) => { throwEvents.push(event); if (event.progress === 1) throw new Error("callback failed"); } });
  const rpcEvents = [];
  let rpcCode;
  try { await client.request("rpc", {}, { onProgress: (event) => rpcEvents.push(event) }); } catch (error) { rpcCode = error.code; }
  await client.request("barrier", {});
  const timeoutEvents = [];
  let timeoutName;
  try { await client.request("timeout", {}, { timeoutMs: 350, onProgress: (event) => timeoutEvents.push(event) }); } catch (error) { timeoutName = error.name; }
  await client.request("barrier", {});
  const noTimeout = [];
  for (const timeoutMs of [0, -1, Infinity]) noTimeout.push(await client.request("no-timeout", {}, { timeoutMs }));
  const metadata = [];
  for (const params of [undefined, { _meta: "invalid" }, { _meta: { keep: "yes" } }]) metadata.push(await client.request("metadata", params, { onProgress: () => {} }));
  console.log(JSON.stringify({ probe, probeEvents, plain, pair, pairedEvents, slow, slowEvents, thrown, throwEvents, seenErrors, rpcCode, rpcEvents, timeoutName, timeoutEvents, noTimeout, metadata }));
} finally {
  await client.close();
}
