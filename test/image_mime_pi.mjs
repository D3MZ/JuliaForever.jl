import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const [source, fixtures] = process.argv.slice(2);
const { normalizeToolResultImages } = await import(pathToFileURL(`${source}/packages/coding-agent/src/utils/tool-result-images.ts`));
const cases = [
    ["static.gif", "IMAGE/GIF"],
    ["static.gif", " image/gif; name=static.gif "],
    ["static.webp", "IMAGE/WEBP; name=inline.webp"],
    ["pixel.png", "IMAGE/PNG; name=pixel.png"],
    ["pixel.jpg", "image/JPG"],
    ["pixel.jpg", "image/JPEG; name=pixel.jpg"],
];
const results = [];
for (const [file, mimeType] of cases) {
    const data = (await readFile(`${fixtures}/${file}`)).toString("base64");
    const content = await normalizeToolResultImages([{ type: "image", mimeType, data }]);
    results.push({ mime: content[0].mimeType, unchanged: content[0].data === data });
}
process.stdout.write(JSON.stringify(results));
