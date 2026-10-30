import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [source, workspace, ...files] = process.argv.slice(2);
const { processImage } = await import(pathToFileURL(join(source, "packages/coding-agent/src/utils/image-process.ts")));
const maximum = 3 * ((9 * 1024 * 1024 / 8) - 1);
const results = [];
for (const file of files) {
    const original = await readFile(join(workspace, file));
    const mime = file.endsWith(".gif") ? "image/gif" : "image/webp";
    for (const size of [maximum, maximum + 1]) {
        const bytes = Buffer.alloc(size);
        original.copy(bytes);
        const value = await processImage(bytes, mime);
        results.push({ ok: value.ok, mime: value.mimeType, unchanged: value.ok && value.data === bytes.toString("base64") });
    }
}
process.stdout.write(JSON.stringify(results));
