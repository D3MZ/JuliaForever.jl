import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { register } from "node:module";
import { pathToFileURL } from "node:url";

register("./scheduler_loader.mjs", import.meta.url);
const source = process.env.PI_SOURCE;
const load = (path) => import(pathToFileURL(join(source, path)).href);
const { BACKGROUND_CONTEXT: context } = await load("packages/chord/src/context/index.ts");
const { createModels } = await load("packages/ai/src/models.ts");
const { Harness } = await load("packages/durable/src/harness/harness.ts");
const { createRegistry } = await load("packages/durable/src/harness/registry.ts");
const { defineExtension } = await load("packages/durable/src/harness/define.ts");
const { defineTask } = await load("packages/durable/src/tasks.ts");
const { openNodeSqliteStorage } = await load("packages/durable/src/storage/sqlite/node.ts");

let clock = 1000;
let runs = 0;
const Nap = defineTask({
  name: "test.nap",
  version: 1,
  initial: () => ({ phase: "start" }),
  phases: {
    start: async (_task, runtime, ctx) => runtime.sleepUntil(2000, { phase: "after", value: 2 }, ctx),
    after: async (_task, runtime, ctx) => {
      runs++;
      await runtime.commit(() => ({ status: "terminal", outcome: { status: "completed", result: "ok" } }), ctx);
    },
  },
  abort: async (_task, runtime, ctx) => runtime.commit(() => ({ status: "terminal", outcome: { status: "aborted" } }), ctx),
});
const registry = createRegistry();
registry.install(defineExtension({ name: "test", tasks: [Nap] }));
const directory = await mkdtemp(join(tmpdir(), "pi-scheduler-"));
const path = join(directory, "session.sqlite");
const open = async () => Harness.open(await openNodeSqliteStorage(path), { models: createModels(), registry, now: () => clock, onWake: () => {} }, context);
const state = async (harness, id) => (await harness.getTask(id, context)).state;
const flush = () => new Promise((resolve) => setImmediate(resolve));
const sleeping = async (harness, id) => {
  for (let i = 0; i < 1000; i++) {
    const current = await state(harness, id);
    if (current.status === "sleeping") return current;
    await flush();
  }
  throw new Error("Pi task did not sleep");
};
const view = (value) => ({ status: value.status, until: value.until, phase: value.checkpoint.phase, value: value.checkpoint.value });

try {
  let harness = await open();
  const root = await harness.root(context);
  const id = await root.commit((tx) => tx.createTask(Nap, null, { ownership: { kind: "conversation" } }), context);
  harness.resume();
  const first = view(await sleeping(harness, id));
  await harness.close(context);

  harness = await open();
  const reopened = view(await state(harness, id));
  clock = 1999;
  harness.resume();
  for (let i = 0; i < 10; i++) await flush();
  const early = { ...view(await state(harness, id)), runs };
  clock = 2000;
  harness.resume();
  const done = await harness.waitForTask(id, context);
  const due = { status: done.state.outcome.status, result: done.state.outcome.result, runs };
  await harness.close(context);
  console.log(JSON.stringify({ first, reopened, early, due }));
} finally {
  await rm(directory, { recursive: true, force: true });
}
