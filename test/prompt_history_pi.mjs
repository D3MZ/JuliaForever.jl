import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const [source, file] = process.argv.slice(2);
const { Editor } = await import(pathToFileURL(`${source}/packages/tui/src/components/editor.ts`));
const { SessionManager } = await import(pathToFileURL(`${source}/packages/coding-agent/src/core/session-manager.ts`));
const cases = JSON.parse(readFileSync(file, "utf8"));
const results = [];
for (const { messages, count } of cases) {
    const session = SessionManager.inMemory();
    for (const message of messages) session.appendMessage(message);
    const editor = new Editor({ requestRender() {} }, { borderColor: text => text, selectList: {} });
    for (const { message } of session.buildContextEntries().filter(entry => entry.type === "message")) {
        if (message.role !== "user") continue;
        const text = typeof message.content === "string" ? message.content : message.content.filter(block => block.type === "text").map(block => block.text).join("");
        if (text) editor.addToHistory(text);
    }
    const values = [];
    for (let index = 0; index < count; index++) {
        editor.handleInput("\x1b[A");
        values.push(editor.getText());
    }
    results.push(values);
}
process.stdout.write(JSON.stringify(results));
