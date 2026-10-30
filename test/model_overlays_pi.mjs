import { pathToFileURL } from 'node:url';
import { join } from 'node:path';
const [source, path] = process.argv.slice(2);
const { AuthStorage } = await import(pathToFileURL(join(source, 'packages/coding-agent/src/core/auth-storage.ts')));
const { createModelRegistry } = await import(pathToFileURL(join(source, 'packages/coding-agent/test/model-runtime-test-utils.ts')));
const registry = await createModelRegistry(AuthStorage.inMemory(), path);
if (registry.getError()) { console.log(JSON.stringify({error: registry.getError()})); process.exit(0); }
const models = registry.getAll().filter(m => m.provider === 'fixture' || (m.provider === 'anthropic' && m.id === 'claude-sonnet-4-20250514')).map(m => ({provider: m.provider, id: m.id, name: m.name, api: m.api, context: m.contextWindow, maxoutput: m.maxTokens, reasoning: m.reasoning, images: m.input.includes('image')}));
console.log(JSON.stringify(models));
