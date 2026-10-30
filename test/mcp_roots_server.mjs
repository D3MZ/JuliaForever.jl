import { createInterface } from "node:readline";
import { createServer } from "node:http";

if (process.argv.includes("--http")) {
  let capabilities = {};
  let next = 0;
  const pending = new Map();
  const server = createServer(async (request, response) => {
    if (request.method === "DELETE") return response.writeHead(204).end();
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const message = JSON.parse(Buffer.concat(chunks));
    const json = (id, result) => response.writeHead(200, { "Content-Type": "application/json" }).end(JSON.stringify({ jsonrpc: "2.0", id, result }));
    if (message.method === "initialize") {
      capabilities = message.params.capabilities;
      json(message.id, { protocolVersion: "2025-11-25", capabilities: {}, serverInfo: { name: "roots-fixture", version: "1" } });
    } else if (message.method === "fixture/check") {
      const id = `roots-${++next}`;
      pending.set(id, { response, requestId: message.id, capabilities });
      response.writeHead(200, { "Content-Type": "text/event-stream" });
      response.write(`data: ${JSON.stringify({ jsonrpc: "2.0", id, method: "roots/list" })}\n\n`);
    } else if (message.method === "fixture/pulse") {
      json(message.id, { pulse: true });
    } else {
      response.writeHead(202).end();
      const waiting = pending.get(message.id);
      if (waiting) {
        pending.delete(message.id);
        const reply = message.error ? { errorCode: message.error.code } : { result: message.result };
        const result = { capabilities: waiting.capabilities, response: reply };
        waiting.response.end(`data: ${JSON.stringify({ jsonrpc: "2.0", id: waiting.requestId, result })}\n\n`);
      }
    }
  });
  server.listen(0, "127.0.0.1", () => console.log(server.address().port));
  process.stdin.resume();
  process.stdin.on("end", () => server.close());
} else {
  let capabilities = {};
  let next = 0;
  const pending = new Map();
  const send = (message) => process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", ...message })}\n`);
  const reply = (id, result) => send({ id, result });

  for await (const line of createInterface({ input: process.stdin })) {
    const message = JSON.parse(line);
    if (message.method === "initialize") {
      capabilities = message.params.capabilities;
      reply(message.id, { protocolVersion: "2025-11-25", capabilities: {}, serverInfo: { name: "roots-fixture", version: "1" } });
    } else if (message.method === "fixture/check") {
      const id = `roots-${++next}`;
      pending.set(id, message.id);
      send({ id, method: "roots/list" });
    } else if (message.method === "fixture/pulse") {
      reply(message.id, { pulse: true });
    } else if (pending.has(message.id)) {
      const id = pending.get(message.id);
      pending.delete(message.id);
      const response = message.error ? { errorCode: message.error.code } : { result: message.result };
      reply(id, { capabilities, response });
    }
  }
}
