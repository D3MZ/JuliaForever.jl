const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");
const { pathToFileURL } = require("node:url");
const { execFileSync } = require("node:child_process");
const { chromium } = require("playwright");

async function piExport(root, source) {
    const revision = execFileSync("git", ["-C", source, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
    assert.equal(revision, "e7a0df27c09d11bf4161d3605246cbf57a129cb2");
    const timestamp = "2026-10-30T00:00:00.000Z";
    const text = "**violet** answer using `notes.txt`.\n\n1. first\n2. second\n\n```julia\nx < 2\n```\n\n| name | value |\n| --- | --- |\n| red | 3 |\n\n> quoted text";
    const rows = [
        { type: "session", version: 3, id: "11111111-1111-4111-8111-111111111111", timestamp, cwd: root },
        { type: "message", id: "u1", parentId: null, timestamp, message: { role: "user", content: [{ type: "text", text: "hello" }], timestamp: 0 } },
        { type: "message", id: "a1", parentId: "u1", timestamp, message: { role: "assistant", content: [{ type: "text", text }], api: "openai-completions", provider: "openai", model: "fixture", usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: "stop", timestamp: 0 } },
    ];
    const session = path.join(root, "pi-session.jsonl");
    const html = path.join(root, "pi-export.html");
    await fs.writeFile(session, rows.map(JSON.stringify).join("\n") + "\n");
    const exporter = pathToFileURL(path.join(source, "packages/coding-agent/src/core/export-html/index.ts")).href;
    const script = `import {exportFromFile} from ${JSON.stringify(exporter)}; await exportFromFile(process.argv[1], process.argv[2]);`;
    execFileSync(process.execPath, ["--conditions=source", "--experimental-strip-types", "--input-type=module", "-e", script, session, html]);
    return html;
}

(async () => {
    const profile = await fs.mkdtemp(path.join(os.tmpdir(), "jf-export-browser-"));
    let context;
    try {
        context = await chromium.launchPersistentContext(profile, { executablePath: process.argv[3], headless: true });
        const external = [];
        await context.route(/^https?:\/\//, route => { external.push(route.request().url()); return route.abort(); });
        const page = await context.newPage();
        page.setDefaultTimeout(3000);
        await page.goto(pathToFileURL(process.argv[2]).href);
        const articles = page.locator("article:visible");
        assert.equal(await articles.count(), 4);
        assert.equal(await page.evaluate(() => globalThis.injected), undefined);
        const assistant = page.locator('article[data-role="assistant"]');
        assert.equal(await assistant.locator("strong").textContent(), "violet");
        assert.equal(await assistant.locator("p code").textContent(), "notes.txt");
        assert.equal(await assistant.locator("ol li").count(), 2);
        assert.equal(await assistant.locator("pre code").textContent(), "x < 2");
        assert.equal(await assistant.locator("table tbody td").count(), 2);
        assert.equal((await assistant.locator("blockquote").textContent()).trim(), "quoted text");
        assert.equal(await assistant.getByRole("link", { name: "safe", exact: true }).getAttribute("href"), "https://example.test");
        assert.equal(await assistant.locator('a[href^="javascript:"]').count(), 0);
        assert.equal(await assistant.locator("img").count(), 0);
        assert.deepEqual(external, []);

        const search = page.getByRole("searchbox", { name: "Search conversation" });
        await search.fill("violet");
        assert.equal(await articles.count(), 2);
        assert.equal(await page.getByRole("status").textContent(), "1 of 2 matches");
        await page.getByRole("button", { name: "Next match" }).click();
        assert.equal(await page.getByRole("status").textContent(), "2 of 2 matches");
        await search.fill("no such text");
        assert.equal(await articles.count(), 0);
        assert.equal(await page.getByRole("status").textContent(), "No matches");

        await search.clear();
        await page.getByRole("checkbox", { name: "Show tool results" }).uncheck();
        assert.equal(await articles.count(), 3);
        await page.getByRole("button", { name: "Expand tool calls" }).click();
        assert.equal(await page.locator("details[open]").count(), 1);
        await page.getByRole("button", { name: "Collapse tool calls" }).click();
        assert.equal(await page.locator("details[open]").count(), 0);
        if (process.env.PI_SOURCE) {
            const pi = await piExport(profile, process.env.PI_SOURCE);
            await page.goto(pathToFileURL(pi).href);
            await page.locator("strong").first().waitFor();
            assert.equal(await page.locator("strong").first().textContent(), "violet");
            assert.equal(await page.locator("p code").first().textContent(), "notes.txt");
            assert.equal(await page.locator("ol li").count(), 2);
            assert.equal(await page.locator("pre code").first().textContent(), "x < 2");
            assert.equal(await page.locator("table tbody td").count(), 2);
            assert.equal((await page.locator("blockquote").first().textContent()).trim(), "quoted text");
            process.stdout.write("Pinned Pi Markdown comparison passed.\n");
        }
        process.stdout.write("Export search and controls passed.\n");
    } finally {
        if (context) await context.close();
        await fs.rm(profile, { recursive: true, force: true });
    }
})().catch(error => { console.error(error); process.exitCode = 1; });
