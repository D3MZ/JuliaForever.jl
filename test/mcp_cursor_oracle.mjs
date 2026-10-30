import { pathToFileURL } from "node:url";
const { consumeSseStream } = await import(pathToFileURL(`${process.env.PI_SOURCE}/packages/mcp/src/transports/streamable-http.ts`).href);
const chunks = [];
for await (const chunk of process.stdin) chunks.push(chunk);
const bytes = Buffer.concat(chunks);
const stream = new ReadableStream({ start(controller) { controller.enqueue(bytes); controller.close(); } });
let id = null, retry = null;
await consumeSseStream(stream, { onEvent() {}, onId(value) { id = value; }, onRetry(value) { retry = value / 1000; } });
console.log(JSON.stringify({ id, retry }));
