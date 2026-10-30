import { createInterface } from "node:readline";

const valid = (id, value) => JSON.stringify({ jsonrpc: "2.0", id, result: { scenario: value } });
const malformed = (method, id) => ({
  trailing: `${valid(id, "wrong")} garbage`,
  malformed: "{synthetic-secret",
  control: `{"jsonrpc":"2.0","id":${id},"result":"bad\tvalue"}`,
  leading_zero: `{"jsonrpc":"2.0","id":${id},"result":01}`,
  bad_error: JSON.stringify({ jsonrpc: "2.0", id, error: { code: true, message: "invalid" } }),
  null_error: JSON.stringify({ jsonrpc: "2.0", id, error: null }),
  bad_version: JSON.stringify({ jsonrpc: "1.0", id, result: "wrong" }),
  ambiguous: JSON.stringify({ jsonrpc: "2.0", id, result: "wrong", error: null }),
  nonobject: "[]",
  blank: "  \t  ",
  deep_guard: `{"jsonrpc":"2.0","id":${id},"result":${"[".repeat(20000)}0${"]".repeat(20000)}}`,
  foreign_id: valid(id + 1000, "wrong"),
  valid: "",
})[method];

createInterface({ input: process.stdin }).on("line", line => {
  const request = JSON.parse(line);
  const { id, method } = request;
  if (method === "initialize") {
    process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result: { protocolVersion: "2025-06-18", capabilities: {}, serverInfo: { name: "fixture", version: "1" } } }) + "\n");
  } else if (method === "valid_error") {
    process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, error: { code: -32001, message: "request failed" } }) + "\n");
  } else if (typeof id === "number") {
    const first = malformed(method, id);
    if (first) process.stdout.write(first + "\n");
    process.stdout.write(valid(id, method) + "\n");
  }
});
