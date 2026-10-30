import { join } from "node:path";
import { pathToFileURL } from "node:url";
const { shouldCompact, calculateContextTokens } = await import(pathToFileURL(join(process.argv[2], "packages/coding-agent/src/core/compaction/compaction.ts")));
const cases = [[80, true], [81, true], [81, false]];
const decisions = cases.map(([tokens, enabled]) => shouldCompact(tokens, 100, { enabled, reserveTokens: 20 }));
const tokens = calculateContextTokens({ totalTokens: 0, input: 1, output: 2, cacheRead: 3, cacheWrite: 4 });
process.stdout.write(JSON.stringify({ decisions, tokens }));
