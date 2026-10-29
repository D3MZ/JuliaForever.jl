import { mkdtemp, mkdir, readFile, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";

const [source, input] = process.argv.slice(2);
const modules = await Promise.all(["read", "write", "edit"].map(name => import(pathToFileURL(join(source, `packages/coding-agent/src/core/tools/${name}.ts`)))));
const create = { read: modules[0].createReadToolDefinition, write: modules[1].createWriteToolDefinition, edit: modules[2].createEditToolDefinition };
const cases = JSON.parse(await readFile(input, "utf8"));
const results = [];
for (const item of cases) {
    const workspace = await mkdtemp(join(tmpdir(), "jf-reference-"));
    const file = join(workspace, item.args.path);
    if (item.initial !== null) {
        await mkdir(dirname(file), { recursive: true });
        await writeFile(file, item.initial);
    }
    let text = "";
    let iserror = false;
    try {
        const result = await create[item.tool](workspace).execute("fixture", item.args);
        text = result.content.find(block => block.type === "text").text;
    } catch {
        iserror = true;
    }
    let contents = null;
    try { contents = await readFile(file, "utf8"); } catch {}
    results.push({ text, iserror, file: contents });
    await rm(workspace, { recursive: true, force: true });
}
process.stdout.write(JSON.stringify(results));
