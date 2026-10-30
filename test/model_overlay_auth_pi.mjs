import { pathToFileURL } from 'node:url';
import { join } from 'node:path';

const [source, path, mode, provider = 'fixture', id = 'alpha'] = process.argv.slice(2);
const { AuthStorage } = await import(pathToFileURL(join(source, 'packages/coding-agent/src/core/auth-storage.ts')));
const { createModelRegistry } = await import(pathToFileURL(join(source, 'packages/coding-agent/test/model-runtime-test-utils.ts')));
const credentials = AuthStorage.inMemory();
if (mode === 'stored') await credentials.modify('fixture', async () => ({ type: 'api_key', key: 'stored-key' }));
const registry = await createModelRegistry(credentials, path);
const model = registry.find(provider, id);
const auth = await registry.getApiKeyAndHeaders(model);
console.log(JSON.stringify({ id: model.id, base: model.baseUrl, auth }));
