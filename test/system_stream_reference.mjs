import { mkdtemp, rm, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { pathToFileURL } from "node:url";

const source = process.argv[2];
const { createBashToolDefinition } = await import(pathToFileURL(join(source, "packages/coding-agent/src/core/tools/bash.ts")));
const dir = await promisify(mkdtemp)(join(tmpdir(), "jf-shell-stream-reference-"));
const updates = [];
try {
    const command = "printf 'first\\n'; while [ ! -f release ]; do sleep .02; done; printf 'second\\n' >&2";
    const result = await createBashToolDefinition(dir).execute("fixture", { command, timeout: 5 }, undefined, update => {
        const text = update.content.find(block => block.type === "text")?.text ?? "";
        updates.push(text);
        if (text === "first\n") writeFileSync(join(dir, "release"), "");
    });
    process.stdout.write(JSON.stringify({ updates, result: result.content[0].text }));
} finally {
    await promisify(rm)(dir, { recursive: true, force: true });
}
