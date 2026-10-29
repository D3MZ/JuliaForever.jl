import { mkdtemp, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { pathToFileURL } from "node:url";

const source = process.argv[2];
const { createBashToolDefinition } = await import(pathToFileURL(join(source, "packages/coding-agent/src/core/tools/bash.ts")));
const results = [];
for (const stage of ["before", "running"]) {
    const dir = await mkdtemp(join(tmpdir(), "jf-shell-cancel-reference-"));
    const controller = new AbortController();
    try {
        if (stage === "before") controller.abort();
        const command = stage === "before" ? "touch unexpected" : "printf before; printf ready > ready; sleep 30; touch late";
        const result = createBashToolDefinition(dir).execute("fixture", { command }, controller.signal).then(
            value => ({ text: value.content.find(block => block.type === "text").text, iserror: value.isError === true }),
            exception => ({ text: exception.message, iserror: true }),
        );
        if (stage === "running") {
            const deadline = Date.now() + 10000;
            while (Date.now() < deadline && !(await stat(join(dir, "ready")).then(() => true, () => false))) await delay(5);
            if (Date.now() >= deadline) throw new Error("Shell did not start");
            controller.abort();
        }
        results.push(await result);
    } finally {
        controller.abort();
        await rm(dir, { recursive: true, force: true });
    }
}
process.stdout.write(JSON.stringify(results));
