import { pathToFileURL } from 'node:url';
const { ExtensionRunner } = await import(pathToFileURL(`${process.argv[2]}/packages/coding-agent/src/core/extensions/runner.ts`));
const seen = [];
const handlers = new Map([
  ['context', [e => { seen.push(structuredClone(e.messages)); e.messages.push({role:'user', content:'injected'}); }, e => { e.messages[0].content = 'edited'; throw Error('broken'); }, e => { seen.push(structuredClone(e.messages)); }]],
  ['context_with_system', [e => { seen.push(structuredClone(e.messages)); }]],
]);
const runner = new ExtensionRunner([{path:'fixture', handlers}], {}, '', {}, {});
const errors = [];
runner.onError(e => errors.push(e.event));
const original = [{role:'system',content:'prompt',timestamp:1}, {role:'user',content:'hello'}, {role:'system',content:'extra',timestamp:2}, {role:'assistant',content:'answer'}];
const result = await runner.emitContext(original);
console.log(JSON.stringify({seen, result, original, errors}));
