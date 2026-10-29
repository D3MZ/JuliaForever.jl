import { access, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [source] = process.argv.slice(2);
const { createEditToolDefinition } = await import(pathToFileURL(join(source, "packages/coding-agent/src/core/tools/edit.ts")));
const { createWriteToolDefinition } = await import(pathToFileURL(join(source, "packages/coding-agent/src/core/tools/write.ts")));

function deferred() {
    let release;
    const promise = new Promise(resolve => { release = resolve; });
    return { promise, release };
}

const results = [];
for (const kind of ["edit", "write"]) {
    const dir = await mkdtemp(join(tmpdir(), "jf-mutation-reference-"));
    try {
        const path = join(dir, "target.txt");
        await writeFile(path, "alpha\nbeta\n");
        const started = deferred();
        const resume = deferred();
        const editor = createEditToolDefinition(dir, { operations: {
            access,
            readFile: async path => {
                const content = await readFile(path);
                started.release();
                await resume.promise;
                return content;
            },
            writeFile: (path, content) => writeFile(path, content),
        }});
        const writer = createWriteToolDefinition(dir);
        const first = editor.execute("first", { path: "target.txt", edits: [{ oldText: "alpha", newText: "ALPHA" }] });
        await started.promise;
        const second = kind === "edit"
            ? createEditToolDefinition(dir).execute("second", { path: "target.txt", edits: [{ oldText: "beta", newText: "BETA" }] })
            : writer.execute("second", { path: "target.txt", content: "replacement\n" });
        await writer.execute("other", { path: "other.txt", content: "independent\n" });
        resume.release();
        await Promise.all([first, second]);
        results.push({ file: await readFile(path, "utf8"), other: await readFile(join(dir, "other.txt"), "utf8") });
    } finally {
        await rm(dir, { recursive: true, force: true });
    }
}
process.stdout.write(JSON.stringify(results));
