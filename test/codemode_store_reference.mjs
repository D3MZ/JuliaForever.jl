import { join } from "node:path";
import { pathToFileURL } from "node:url";

const source = process.argv[2];
const { InlineCodemodeSandbox, loadQuickJSWasm } = await import(pathToFileURL(join(source, "packages/codemode/src/index.ts")));
const sandbox = new InlineCodemodeSandbox({ wasm: loadQuickJSWasm(), timeoutMs: 10000 });
const cases = [
  [{ old: 5, keep: true, "π😀": 9 }, 'store("old", undefined); store("π😀", undefined); store("null", null); store("absent", undefined); return [load("old"), load("null"), load("keep")];'],
  [{ replaced: 1 }, 'store("discarded", 9); store("discarded", undefined); store("replaced", undefined); store("replaced", 2); return [load("discarded"), load("replaced")];'],
  [{ old: 5 }, 'store("old", undefined); store("new", 1); throw new Error("bad");'],
];
try {
  const results = [];
  for (const [store, code] of cases) {
    const result = await sandbox.execute(code, { store });
    results.push(result.ok ? { ok: true, value: result.value, writes: result.storeWrites.set, deletes: result.storeWrites.delete } : { ok: false, writes: {}, deletes: [] });
  }
  process.stdout.write(JSON.stringify(results));
} finally {
  await sandbox.close();
}
