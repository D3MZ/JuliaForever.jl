import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [source, input] = process.argv.slice(2);
const names = ["bash", "ls", "powershell"];
const modules = await Promise.all(names.map(name => import(pathToFileURL(join(source, `packages/coding-agent/src/core/tools/${name}.ts`)))));
const create = { bash: modules[0].createBashToolDefinition, ls: modules[1].createLsToolDefinition, powershell: modules[2].createPowerShellToolDefinition };
const cases = JSON.parse(await (await import("node:fs/promises")).readFile(input, "utf8"));
const results = [];
for (const item of cases) {
    const workspace = await mkdtemp(join(tmpdir(), "jf-system-reference-"));
    await mkdir(join(workspace, "alpha"));
    await writeFile(join(workspace, ".hidden"), "h");
    await writeFile(join(workspace, "beta.txt"), "b");
    let text, iserror;
    try {
        const result = await create[item.tool](workspace).execute("fixture", item.args);
        text = result.content.find(block => block.type === "text").text;
        iserror = result.isError === true;
    } catch (err) {
        text = err.message;
        iserror = true;
    }
    const output = text.match(/Full output: ([^\]]+)\]$/);
    let full = null;
    if (output) {
        full = await (await import("node:fs/promises")).readFile(output[1], "utf8");
        await rm(output[1], { force: true });
        text = text.replace(output[1], "<output>");
    }
    results.push({ text: text.replaceAll(workspace, "<cwd>"), iserror, full });
    await rm(workspace, { recursive: true, force: true });
}
process.stdout.write(JSON.stringify(results));
