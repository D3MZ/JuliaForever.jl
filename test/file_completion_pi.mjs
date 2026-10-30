import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const [source, input] = process.argv.slice(2);
const { cwd, fd, cases } = JSON.parse(readFileSync(input, "utf8"));
const { CombinedAutocompleteProvider } = await import(pathToFileURL(`${source}/packages/tui/src/autocomplete.ts`));
const provider = new CombinedAutocompleteProvider([], cwd, fd || null);
const results = [];
for (const { before, after, force } of cases) {
    const text = before + after;
    const found = await provider.getSuggestions([text], 0, before.length, { signal: new AbortController().signal, force });
    if (!found) {
        results.push(null);
        continue;
    }
    const items = found.items.map(item => ({ value: item.value, label: item.label, description: item.description ?? "" }));
    const applied = provider.applyCompletion([text], 0, before.length, found.items[0], found.prefix);
    results.push({ prefix: found.prefix, items, text: applied.lines[0], cursor: applied.cursorCol });
}
process.stdout.write(JSON.stringify(results));
