import { createInterface } from "node:readline";

createInterface({ input: process.stdin }).on("line", line => {
  const { id, method } = JSON.parse(line);
  if (method === "initialize") {
    process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result: { protocolVersion: "2025-06-18", capabilities: {}, serverInfo: { name: "fixture", version: "1" } } }) + "\n");
  } else if (id !== undefined) {
    process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, error: { code: -32001.5, message: "fractional", data: { detail: "fixture" } } }) + "\n");
  }
});
