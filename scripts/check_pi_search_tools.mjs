import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const home = mkdtempSync(join(tmpdir(), "pi-search-check-"));
try {
    process.env.HOME = home;
    process.env.USERPROFILE = home;
    process.env.PI_CODING_AGENT_DIR = join(home, "agent");
    process.env.PI_OFFLINE = "1";
    const { ensureTool } = await import(pathToFileURL(join(process.env.PI_SOURCE, "packages/coding-agent/src/utils/tools-manager.ts")));
    for (const [tool, expected] of [["fd", "fd 10.2.0"], ["rg", "ripgrep 15.2.0"]]) {
        const path = await ensureTool(tool);
        if (!path) throw new Error(`Pi cannot find ${tool} with isolated HOME and PI_OFFLINE=1`);
        const result = spawnSync(path, ["--version"], { encoding: "utf8" });
        const version = result.stdout?.split(/\r?\n/, 1)[0];
        if (result.error || result.status !== 0 || !(version === expected || version?.startsWith(`${expected} (`))) {
            throw new Error(`Pi ${tool} at ${path}: expected ${expected}; got ${version || result.error || result.stderr}`);
        }
        console.log(`Pi ${tool}: ${path}, ${version}`);
    }
} finally {
    rmSync(home, { recursive: true, force: true });
}
