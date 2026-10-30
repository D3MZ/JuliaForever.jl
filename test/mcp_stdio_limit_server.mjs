import { createInterface } from "node:readline";

const limit = 16 * 1024 * 1024;
const message = (id, result) => JSON.stringify({ jsonrpc: "2.0", id, result });
const exactly = (id, size) => {
  const overhead = Buffer.byteLength(message(id, ""));
  return message(id, "é" + "x".repeat(size - overhead - Buffer.byteLength("é")));
};

createInterface({ input: process.stdin }).on("line", line => {
  const { method, id } = JSON.parse(line);
  if (method === "initialize") {
    process.stdout.write(message(id, { protocolVersion: "2025-06-18", capabilities: {}, serverInfo: { name: "fixture", version: "1" } }) + "\n");
  } else if (method === "fragmented") {
    const value = message(id, { scenario: method });
    process.stdout.write(value.slice(0, 10), () => setTimeout(() => process.stdout.write(value.slice(10) + "\r\n"), 20));
  } else if (method === "at_limit") {
    process.stdout.write(exactly(id, limit) + "\n");
  } else if (method === "over_limit") {
    process.stdout.write(exactly(id, limit + 1) + "\n" + message(id, { scenario: method }) + "\n");
  } else if (method === "reset_tail") {
    process.stdout.write("x".repeat(limit + 1), () => setTimeout(() => process.stdout.write(message(id, { scenario: method }) + "\n"), 500));
  } else if (typeof id === "number") {
    process.stdout.write(message(id, { scenario: method }) + "\n");
  }
});
