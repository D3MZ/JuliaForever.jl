import { join } from "node:path";
import { pathToFileURL } from "node:url";
const root = join(process.argv[2], "packages/coding-agent/src/core");
const { createExtensionRuntime, loadExtensionFromFactory } = await import(pathToFileURL(join(root, "extensions/loader.ts")));
const { ExtensionRunner } = await import(pathToFileURL(join(root, "extensions/runner.ts")));
const { createEventBus } = await import(pathToFileURL(join(root, "event-bus.ts")));
const output = {};
for (const mode of ["transform", "block", "error"]) {
  const runtime = createExtensionRuntime(), bus = createEventBus(), seen = [];
  const a = await loadExtensionFromFactory(pi => pi.on("tool_call", e => { seen.push(e.input.value); e.input.value = "changed"; if (mode === "error") throw Error("broken"); if (mode === "block") return { block: true, reason: "denied" }; }), process.cwd(), bus, runtime, "one");
  const b = await loadExtensionFromFactory(pi => pi.on("tool_call", e => { seen.push(e.input.value); }), process.cwd(), bus, runtime, "two");
  const runner = new ExtensionRunner([a, b], runtime, process.cwd(), {}, {});
  const event = { type: "tool_call", toolCallId: "1", toolName: "echo", input: { value: "original" } };
  try { const result = await runner.emitToolCall(event); output[mode] = { seen, value: event.input.value, reason: result?.reason ?? null }; }
  catch (e) { output[mode] = { seen, value: event.input.value, reason: e.message }; }
}
process.stdout.write(JSON.stringify(output));
