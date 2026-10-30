import { pathToFileURL } from 'node:url';
import { join } from 'node:path';

const [source, path, provider, id] = process.argv.slice(2);
const { ModelConfig } = await import(pathToFileURL(join(source, 'packages/coding-agent/src/core/model-config.ts')));
const config = await ModelConfig.load(path);
if (config.getError()) {
  console.log(JSON.stringify({ valid: false }));
} else {
  const { AuthStorage } = await import(pathToFileURL(join(source, 'packages/coding-agent/src/core/auth-storage.ts')));
  const { createModelRegistry, getModelRuntime } = await import(pathToFileURL(join(source, 'packages/coding-agent/test/model-runtime-test-utils.ts')));
  const { resolveCliModel } = await import(pathToFileURL(join(source, 'packages/coding-agent/src/core/model-resolver.ts')));
  const registry = await createModelRegistry(AuthStorage.inMemory(), path);
  const result = resolveCliModel({ cliProvider: provider, cliModel: id, modelRuntime: getModelRuntime(registry) });
  console.log(JSON.stringify({ valid: !registry.getError(), api: result.model?.api ?? null, reasoning: result.model?.reasoning ?? null, id: result.model?.id ?? null }));
}
