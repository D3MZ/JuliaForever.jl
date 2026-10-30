import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";

const source = path => pathToFileURL(join(process.env.PI_SOURCE, "packages/durable/src", path)).href;
const { defineDoc, defineDocFamily } = await import(source("documents.ts"));
const { createSession } = await import(source("session/session.ts"));
const { MemoryStorage } = await import(source("storage/memory.ts"));
const doc = (kind, history, fork) => defineDoc({ kind, version: 1, scope: "conversation", history, fork, initial: () => ({ value: "initial" }), checkpointWhen: () => false });
const family = (kind, history, fork) => defineDocFamily({ kind, version: 1, family: true, scope: "conversation", history, fork, initial: () => ({ value: "initial" }), checkpointWhen: () => false });
const asof = doc("asof", "rewindable", "asOf");
const current = doc("current", "latest", "current");
const initial = doc("initial", "latest", "initial");
const late = doc("late", "rewindable", "asOf");
const keyed = family("family", "rewindable", "asOf");
const session = createSession(new MemoryStorage());
const commit = f => session.commit(f, context);
const ownership = { kind: "ownerless" };
const root = await commit(tx => tx.createConversation({ ownership }));
const other = await commit(tx => tx.createConversation({ ownership }));
const before = await commit(tx => tx.appendEntry(root.id, { kind: "before", data: "before" }));
const [point, hidden] = await commit(async tx => {
  const point = await tx.appendEntry(root.id, { kind: "point", data: "point" });
  (await tx.doc(asof, root.id)).value = "root-at-point";
  (await tx.doc(current, root.id)).value = "current-at-point";
  (await tx.doc(initial, root.id)).value = "parent-only";
  (await tx.doc(keyed, root.id, "", "unused")).value = "empty-key";
  (await tx.doc(keyed, root.id, "a", "unused")).value = "key-a";
  const hidden = await tx.appendEntry(root.id, { kind: "hidden", data: "hidden" });
  return [point, hidden];
});
await commit(async tx => {
  (await tx.doc(asof, root.id)).value = "root-after";
  (await tx.doc(current, root.id)).value = "current-after";
  (await tx.doc(late, root.id)).value = "late";
});
const child = await commit(tx => tx.forkConversation(root.id, point.id, { ownership }));
const early = await commit(tx => tx.forkConversation(root.id, before.id, { ownership }));
const [childPoint, childHidden] = await commit(async tx => {
  const entry = await tx.appendEntry(child.id, { kind: "child", data: "child" });
  (await tx.doc(asof, child.id)).value = "child-at-point";
  (await tx.doc(current, child.id)).value = "child-current";
  const hidden = await tx.appendEntry(child.id, { kind: "child-hidden", data: "child-hidden" });
  return [entry, hidden];
});
await commit(async tx => { (await tx.doc(current, root.id)).value = "root-newer"; });
const inherited = await commit(tx => tx.forkConversation(child.id, point.id, { ownership }));
const nested = await commit(tx => tx.forkConversation(child.id, childPoint.id, { ownership }));
const snapshot = async (token, conversation, key) => {
  const result = key === undefined ? await session.snapshot(token, conversation.id, context) : await session.snapshot(token, conversation.id, key, context);
  return result?.value ?? null;
};
const values = async conversation => ({
  asof: await snapshot(asof, conversation), current: await snapshot(current, conversation),
  initial: await snapshot(initial, conversation), late: await snapshot(late, conversation),
  empty: await snapshot(keyed, conversation, ""), keyed: await snapshot(keyed, conversation, "a"),
});
const entries = async conversation => (await commit(tx => tx.scanEntries({ conversationId: conversation.id, order: "ascending" }, 100))).items.map(entry => entry.data);
let hiddenRejected = false;
try { await commit(tx => tx.forkConversation(child.id, hidden.id, { ownership })); } catch { hiddenRejected = true; }
let stagedRejected = false;
try { await commit(async tx => { const entry = await tx.appendEntry(root.id, { kind: "staged" }); await tx.forkConversation(root.id, entry.id, { ownership }); }); } catch { stagedRejected = true; }
const collisionAsOf = doc("collision", "rewindable", "asOf");
const collisionCurrent = doc("collision", "latest", "current");
const collisionRoot = await commit(tx => tx.createConversation({ ownership }));
const collisionPoint = await commit(async tx => {
  const entry = await tx.appendEntry(collisionRoot.id, { kind: "point" });
  await tx.doc(collisionAsOf, collisionRoot.id);
  return entry;
});
const collisionParent = await commit(tx => tx.forkConversation(collisionRoot.id, collisionPoint.id, { ownership }));
await commit(tx => tx.retireDoc(collisionAsOf, collisionParent.id));
await commit(tx => tx.doc(collisionCurrent, collisionParent.id).then(() => undefined));
let collisionRejected = false;
try { await commit(tx => tx.forkConversation(collisionParent.id, collisionPoint.id, { ownership })); } catch { collisionRejected = true; }
const result = { collisionRejected, child: await values(child), early: await values(early), inherited: await values(inherited), nested: await values(nested), inheritedEntries: await entries(inherited), nestedEntries: await entries(nested), hiddenRejected, stagedRejected };
await session.close(context);
process.stdout.write(JSON.stringify(result));
