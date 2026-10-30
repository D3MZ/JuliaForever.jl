import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const [source, input] = process.argv.slice(2);
const { commands, queries } = JSON.parse(readFileSync(input, "utf8"));
const { CombinedAutocompleteProvider } = await import(pathToFileURL(`${source}/packages/tui/src/autocomplete.ts`));
const provider = new CombinedAutocompleteProvider(commands, process.cwd());
const results = [];
for (const query of queries) {
    const text = `/${query}`;
    const found = await provider.getSuggestions([text], 0, text.length, { signal: new AbortController().signal });
    results.push(found ? found.items.map(item => item.value) : []);
}
process.stdout.write(JSON.stringify(results));
