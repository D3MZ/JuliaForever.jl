import { join } from "node:path";
import { pathToFileURL } from "node:url";
const root = join(process.argv[2], "packages/coding-agent/src/core");
const { createExtensionRuntime, loadExtensionFromFactory } = await import(pathToFileURL(join(root, "extensions/loader.ts")));
const { ExtensionRunner } = await import(pathToFileURL(join(root, "extensions/runner.ts")));
const { createEventBus } = await import(pathToFileURL(join(root, "event-bus.ts")));
const runtime = createExtensionRuntime(), bus = createEventBus(), seen = [], errors = [];
const first = await loadExtensionFromFactory(pi => {
  pi.on("tool_result", event => { seen.push(event.content[0].text); return { content: [{ type: "text", text: "first" }] }; });
  pi.on("tool_result", () => { throw Error("broken"); });
}, process.cwd(), bus, runtime, "one");
const second = await loadExtensionFromFactory(pi => pi.on("tool_result", event => { seen.push(event.content[0].text); return { content: [{ type: "text", text: "last" }], isError: true }; }), process.cwd(), bus, runtime, "two");
const runner = new ExtensionRunner([first, second], runtime, process.cwd(), {}, {});
runner.onError(error => errors.push(error.error));
const result = await runner.emitToolResult({ type: "tool_result", toolCallId: "one", toolName: "intercept", input: {}, content: [{ type: "text", text: "original" }], details: {}, isError: false });
seen.push(result.content[0].text);
process.stdout.write(JSON.stringify({ seen, iserror: result.isError, errors }));
