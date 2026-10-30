import { pathToFileURL } from "node:url";
import { join } from "node:path";

const [source, path, ...models] = process.argv.slice(2);
const { AuthStorage } = await import(pathToFileURL(join(source, "packages/coding-agent/src/core/auth-storage.ts")));
const { createModelRegistry, getModelRuntime } = await import(pathToFileURL(join(source, "packages/coding-agent/test/model-runtime-test-utils.ts")));
const { resolveCliModel } = await import(pathToFileURL(join(source, "packages/coding-agent/src/core/model-resolver.ts")));
const auth = AuthStorage.inMemory();
await auth.modify("openrouter", async () => ({ type: "api_key", key: "fixture-router-key" }));
const registry = await createModelRegistry(auth, path);
console.log(JSON.stringify(models.map(cliModel => {
    const result = resolveCliModel({ cliModel, modelRuntime: getModelRuntime(registry) });
    return { provider: result.model?.provider, id: result.model?.id };
})));
