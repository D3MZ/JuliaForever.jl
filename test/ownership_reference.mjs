import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { register } from "node:module";
import { pathToFileURL } from "node:url";
register("./scheduler_loader.mjs", import.meta.url);
const load = p => import(pathToFileURL(join(process.env.PI_SOURCE, p)).href);
const { BACKGROUND_CONTEXT: ctx } = await load("packages/chord/src/context/index.ts");
const { createModels } = await load("packages/ai/src/models.ts");
const { Harness } = await load("packages/durable/src/harness/harness.ts");
const { createRegistry } = await load("packages/durable/src/harness/registry.ts");
const { defineExtension } = await load("packages/durable/src/harness/define.ts");
const { defineTask } = await load("packages/durable/src/tasks.ts");
const { openNodeSqliteStorage } = await load("packages/durable/src/storage/sqlite/node.ts");
const Hold = defineTask({ name: "test.hold", version: 1, initial: () => ({ phase: "work" }), phases: { work: async (_t, r, c) => r.sleepUntil(9999999999999, { phase: "work" }, c) }, abort: async (_t, r, c) => r.commit(() => ({ status: "terminal", outcome: { status: "aborted" } }), c) });
const registry = createRegistry(); registry.install(defineExtension({ name: "test", tasks: [Hold] }));
const dir = await mkdtemp(join(tmpdir(), "pi-owner-"));
try {
 const h = await Harness.open(await openNodeSqliteStorage(join(dir, "db")), { models: createModels(), registry, onWake: () => {} }, ctx);
 const root = await h.root(ctx);
 const [parent, child, grandchild, independent] = await root.commit(async tx => {
  const p = await tx.createTask(Hold, null, { ownership: { kind: "conversation" } });
  const c = await tx.createTask(Hold, null, { ownership: { kind: "task", taskId: p } });
  const g = await tx.createTask(Hold, null, { ownership: { kind: "task", taskId: c } });
  const i = await tx.createTask(Hold, null, { ownership: { kind: "conversation" } });
  return [p,c,g,i];
 }, ctx);
 await h.abortTask(parent, ctx); h.resume();
 const statuses = [];
 for (const id of [parent, child, grandchild]) statuses.push((await h.waitForTask(id, ctx)).state.outcome.status);
 const other = (await h.getTask(independent, ctx)).abortRequested;
 console.log(JSON.stringify({ statuses, other }));
 await h.close(ctx);
} finally { await rm(dir, { recursive: true, force: true }); }
