import { readFile } from "node:fs/promises";
import { registerHooks } from "node:module";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [source, fixture] = process.argv.slice(2);
const { resolveModelReference } = await import(pathToFileURL(join(source, "packages/coding-agent/src/core/model-resolver.ts")));
const { models, cases, listing } = JSON.parse(await readFile(fixture, "utf8"));
if (listing !== undefined) {
    const hooks = registerHooks({
        resolve(specifier, context, next) {
            if (specifier === "@earendil-works/pi-tui") {
                return { url: pathToFileURL(join(source, "packages/tui/src/fuzzy.ts")).href, shortCircuit: true };
            }
            return next(specifier, context);
        },
    });
    const { listModels } = await import(pathToFileURL(join(source, "packages/coding-agent/src/cli/list-models.ts")));
    hooks.deregister();
    const output = [];
    const log = console.log;
    console.log = line => output.push(line);
    await listModels({ getError: () => undefined, getAvailable: async () => models }, listing);
    console.log = log;
    console.log(JSON.stringify(output.join("\n") + "\n"));
    process.exit(0);
}
const results = cases.map(({ text, provider, usable }) => {
    const result = resolveModelReference({ text, provider, fuzzy: true, thinkingSuffix: "strict" }, models, id => usable.includes(id));
    if (result.status === "resolved") return { status: "resolved", provider: result.model.provider, id: result.model.id, thinking: result.thinkingLevel ?? null };
    if (result.status === "ambiguous") return { status: "ambiguous", candidates: result.candidates.map(m => `${m.provider}/${m.id}`).sort(), usable: result.usableCount, thinking: result.thinkingLevel ?? null };
    return { status: "not-found", target: result.target ? { provider: result.target.provider, id: result.target.modelId, thinking: result.target.thinkingLevel ?? null } : null };
});
console.log(JSON.stringify(results));
