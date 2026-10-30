import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";

const source = (path) => pathToFileURL(join(process.env.PI_SOURCE, "packages/durable/src", path)).href;
const { defineDoc } = await import(source("documents.ts"));
const { createSession } = await import(source("session/session.ts"));
const { MemoryStorage } = await import(source("storage/memory.ts"));

const notes = defineDoc({
  kind: "test.notes", version: 1, scope: "conversation", history: "rewindable", fork: "asOf",
  initial: () => ({ text: "initial" }), checkpointWhen: () => false,
});
const session = createSession(new MemoryStorage());
const chat = await session.commit((tx) => tx.createConversation({ ownership: { kind: "ownerless" } }), context);
const other = await session.commit((tx) => tx.createConversation({ ownership: { kind: "ownerless" } }), context);
const before = await session.commit((tx) => tx.appendEntry(chat.id, { kind: "before" }), context);
const first = await session.commit(async (tx) => {
  const entry = await tx.appendEntry(chat.id, { kind: "first" });
  (await tx.doc(notes, chat.id)).text = "first";
  return entry;
}, context);
const unchanged = await session.commit((tx) => tx.appendEntry(chat.id, { kind: "unchanged" }), context);
const second = await session.commit(async (tx) => {
  (await tx.doc(notes, chat.id)).text = "second";
  return tx.appendEntry(chat.id, { kind: "second" });
}, context);
await session.commit(async (tx) => { (await tx.doc(notes, chat.id)).text = "latest"; }, context);
const foreign = await session.commit((tx) => tx.appendEntry(other.id, { kind: "foreign" }), context);
const asOf = async (entry) => (await session.snapshotAsOf(notes, chat.id, entry.id, context)) ?? null;
let foreignRejected = false;
try { await asOf(foreign); } catch { foreignRejected = true; }
const result = {
  before: await asOf(before), first: await asOf(first), unchanged: await asOf(unchanged),
  second: await asOf(second), latest: await session.snapshot(notes, chat.id, context), foreignRejected,
};
await session.close(context);
process.stdout.write(JSON.stringify(result));
