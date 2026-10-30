import { mkdtemp, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { pathToFileURL } from "node:url";

const source = process.argv[2];
const { createPowerShellToolDefinition } = await import(pathToFileURL(join(source, "packages/coding-agent/src/core/tools/powershell.ts")));
const { createBashToolDefinition } = await import(pathToFileURL(join(source, "packages/coding-agent/src/core/tools/bash.ts")));
const results = [];
const tools = process.argv[3] === "bash" ? ["powershell", "bash"] : ["powershell"];
for (const tool of tools) for (const stage of ["normal", "timeout", "cancel"]) {
    const dir = await mkdtemp(join(tmpdir(), "jf-powershell-reference-"));
    const controller = new AbortController();
    try {
        const command = tool === "powershell"
            ? (stage === "normal" ? "[Console]::Write('complete')" : "[Console]::Write('before'); [Console]::Out.Flush(); [IO.File]::WriteAllText('ready','ready'); Start-Sleep -Seconds 30")
            : (stage === "normal" ? "printf complete" : "printf before; printf ready > ready; sleep 30");
        const args = stage === "timeout" ? { command, timeout: 4 } : { command };
        const definition = tool === "powershell" ? createPowerShellToolDefinition(dir) : createBashToolDefinition(dir);
        const promise = definition.execute("fixture", args, controller.signal).then(
            value => ({ text: value.content.find(block => block.type === "text").text, iserror: value.isError === true }),
            exception => ({ text: exception.message, iserror: true }),
        );
        if (stage === "cancel") {
            const deadline = Date.now() + 15000;
            while (Date.now() < deadline && !(await stat(join(dir, "ready")).then(() => true, () => false))) await delay(20);
            if (Date.now() >= deadline) throw new Error(`${tool} did not start`);
            controller.abort();
        }
        results.push(await promise);
    } finally {
        controller.abort();
        await rm(dir, { recursive: true, force: true });
    }
}
process.stdout.write(JSON.stringify(results));
