const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");
const { pathToFileURL } = require("node:url");
const { chromium } = require("playwright");

(async () => {
    const profile = await fs.mkdtemp(path.join(os.tmpdir(), "jf-export-browser-"));
    let context;
    try {
        context = await chromium.launchPersistentContext(profile, { executablePath: process.argv[3], headless: true });
        const page = await context.newPage();
        page.setDefaultTimeout(3000);
        await page.goto(pathToFileURL(process.argv[2]).href);
        const articles = page.locator("article:visible");
        assert.equal(await articles.count(), 4);
        assert.equal(await page.evaluate(() => globalThis.injected), undefined);

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
        process.stdout.write("Export search and controls passed.\n");
    } finally {
        if (context) await context.close();
        await fs.rm(profile, { recursive: true, force: true });
    }
})().catch(error => { console.error(error); process.exitCode = 1; });
