import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const [source, file] = process.argv.slice(2);
const cases = JSON.parse(readFileSync(file, "utf8"));
const { Markdown } = await import(pathToFileURL(`${source}/packages/tui/src/components/markdown.ts`));
const { setCapabilities } = await import(pathToFileURL(`${source}/packages/tui/src/terminal-image.ts`));
setCapabilities({ images: null, trueColor: false, hyperlinks: false });
const identity = text => text;
const theme = Object.fromEntries(["heading", "link", "linkUrl", "code", "codeBlock", "codeBlockBorder", "quote", "quoteBorder", "hr", "listBullet", "bold", "italic", "strikethrough", "underline"].map(name => [name, identity]));
const rendered = cases.map(({ text, width }) => new Markdown(text, 0, 0, theme).render(width).map(line => line.trimEnd()));
process.stdout.write(JSON.stringify(rendered));
