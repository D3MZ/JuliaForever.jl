import { access, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const [source, julia, project, holdfile, readyfile, stopfile, timeout] = process.argv.slice(2);
const { McpClient, StdioTransport } = await import(pathToFileURL(join(source, "packages/mcp/src/index.ts")));
const server = fileURLToPath(new URL("./mcp_write_race_server.jl", import.meta.url));
const transport = new StdioTransport({ command: julia, args: ["--startup-file=no", `--project=${project}`, server, holdfile, readyfile, stopfile], stderr: "inherit" });
const client = new McpClient({ name: "race", version: "1" });
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function waitForFile(path) {
  for (let i = 0; i < 1500; i++) {
    try { await access(path); return; } catch { await delay(10); }
  }
  throw new Error("Timed out waiting for synthetic MCP server");
}
try {
  await client.connect(transport);
  const options = { timeoutMs: timeout === "inf" ? Infinity : 0 };
  const hold = client.request("hold", {}, options).then(result => ({ result }), () => ({ failed: true }));
  await waitForFile(holdfile);
  const pending = client.request("hold", {}, options).then(result => ({ result }), () => ({ failed: true }));
  await client.notify("release");
  await waitForFile(readyfile);
  const probe = client.request("probe", {}, options).then(() => "success", () => "failed");
  const outcome = await Promise.race([probe, delay(3000).then(() => "timeout")]);
  const buffered = await Promise.race([hold, delay(3000).then(() => "timeout")]);
  const waiting = await Promise.race([pending, delay(100).then(() => "pending")]);
  await writeFile(stopfile, "stop");
  const closed = await Promise.race([pending, delay(3000).then(() => "timeout")]);
  process.stdout.write(JSON.stringify({ outcome, buffered, waiting, closed }));
} finally {
  await writeFile(stopfile, "stop");
  await client.close();
}
