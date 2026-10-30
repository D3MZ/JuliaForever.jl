import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";
import { registerHooks } from "node:module";

const source = process.argv[2];
const chord = JSON.parse(readFileSync(join(source, "packages/chord/package.json"), "utf8"));
registerHooks({
    resolve(specifier, context, nextResolve) {
        const name = "@earendil-works/chord";
        const key = specifier === name ? "." : specifier.startsWith(`${name}/`) ? `.${specifier.slice(name.length)}` : undefined;
        const file = key && chord.exports[key]?.source;
        return file ? { url: pathToFileURL(join(source, "packages/chord", file)).href, shortCircuit: true } : nextResolve(specifier, context);
    },
});
const load = path => import(pathToFileURL(join(source, path)));
const [{ createSession }, { MemoryStorage }, { BACKGROUND_CONTEXT }] = await Promise.all([
    load("packages/durable/src/session/session.ts"),
    load("packages/durable/src/storage/memory.ts"),
    load("packages/chord/src/context/index.ts"),
]);
const session = createSession(new MemoryStorage());
const context = BACKGROUND_CONTEXT;
const ownership = { kind: "ownerless" };
const commit = callback => session.commit(callback, context);
const root = await commit(tx => tx.createConversation({ ownership }));
const [first, cutoff, excluded] = await commit(async tx => [
    await tx.appendEntry(root.id, { kind: "note", data: "first" }),
    await tx.appendEntry(root.id, { kind: "note", data: "cutoff" }),
    await tx.appendEntry(root.id, { kind: "note", data: "same-batch-excluded" }),
]);
const child = await commit(tx => tx.forkConversation(root.id, cutoff.id, { ownership }));
const [childfirst, childhidden] = await commit(async tx => [
    await tx.appendEntry(child.id, { kind: "note", data: "child" }),
    await tx.appendEntry(child.id, { kind: "note", data: "later-child" }),
]);
await commit(tx => tx.appendEntry(root.id, { kind: "note", data: "later-root" }));
const grandchild = await commit(tx => tx.forkConversation(child.id, childfirst.id, { ownership }));
const inherited = await commit(tx => tx.forkConversation(child.id, first.id, { ownership }));
await commit(tx => tx.appendEntry(grandchild.id, { kind: "note", data: "grandchild" }));
const view = async conversation => (await commit(tx => tx.scanEntries({ conversationId: conversation.id, order: "ascending" }, 100))).items.map(entry => entry.data);
const result = { root: await view(root), child: await view(child), grandchild: await view(grandchild), inherited: await view(inherited) };
try {
    await commit(tx => tx.forkConversation(child.id, excluded.id, { ownership }));
    result.hiddenRejected = false;
} catch {
    result.hiddenRejected = true;
}
try {
    await commit(async tx => {
        const staged = await tx.appendEntry(root.id, { kind: "note", data: "uncommitted" });
        await tx.forkConversation(root.id, staged.id, { ownership });
    });
    result.stagedRejected = false;
} catch {
    result.stagedRejected = true;
}
await session.close(context);
process.stdout.write(JSON.stringify(result));
