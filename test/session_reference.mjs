import { copyFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";

const [source, mode, file] = process.argv.slice(2);
const { SessionManager } = await import(pathToFileURL(join(source, "packages/coding-agent/src/core/session-manager.ts")));

function view(session) {
    const entries = session.getEntries();
    const ids = new Map(entries.map((entry, index) => [entry.id, index + 1]));
    const rows = entries.map(entry => {
        const row = { ...entry, id: ids.get(entry.id), parentId: entry.parentId === null ? null : ids.get(entry.parentId) };
        delete row.timestamp;
        return row;
    });
    return { rows, active: session.getBranch().map(entry => ids.get(entry.id)), leaf: ids.get(session.getLeafId()) ?? null };
}

if (mode === "read") {
    process.stdout.write(JSON.stringify(view(SessionManager.open(file))));
} else {
    const session = SessionManager.create(dirname(file), dirname(file));
    const setup = session.appendModelChange("example", "model");
    session.appendMessage({ role: "system", content: "instructions", timestamp: 1 });
    const before = existsSync(session.getSessionFile());
    const question = session.appendMessage({ role: "user", content: "question", timestamp: 2 });
    const after = existsSync(session.getSessionFile());
    const answer = session.appendMessage({ role: "assistant", content: "answer", timestamp: 3 });
    const abandoned = session.appendMessage({ role: "user", content: "abandoned", timestamp: 4 });
    session.branch(question);
    session.appendMessage({ role: "assistant", content: "alternative", timestamp: 5 });
    session.appendCustomEntry("state", { count: 1 });
    const active = session.getBranch().map(entry => entry.id);
    const old = session.getBranch(abandoned).map(entry => entry.id);
    const children = session.getChildren(question).map(entry => entry.id);
    session.resetLeaf();
    session.appendMessage({ role: "user", content: "new root", timestamp: 6 });
    session.branch(answer);
    const reopened = SessionManager.open(session.getSessionFile());
    const branchOnlyReopened = reopened.getLeafId();
    session.appendMessage({ role: "user", content: "continued", timestamp: 7 });
    const final = SessionManager.open(session.getSessionFile());
    const ids = new Map(final.getEntries().map((entry, index) => [entry.id, index + 1]));
    const result = { ...view(final), before, after, activeBefore: active.map(id => ids.get(id)), old: old.map(id => ids.get(id)), children: children.map(id => ids.get(id)), branchOnlyReopened: ids.get(branchOnlyReopened), setup: ids.get(setup) };
    copyFileSync(session.getSessionFile(), file);
    process.stdout.write(JSON.stringify(result));
}
