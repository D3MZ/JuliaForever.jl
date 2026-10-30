import { pathToFileURL } from "node:url";

const source = process.argv[2];
const { Editor } = await import(pathToFileURL(`${source}/packages/tui/src/components/editor.ts`));
const editor = new Editor({ requestRender() {} }, { borderColor: text => text, selectList: {} });
const submitted = [];
editor.onSubmit = text => {
    submitted.push(text);
    editor.addToHistory(text);
};

const inputs = [
    ["  hello", "\n", "world  ", "\r"],
    ["one\\", "\r", "two", "\r"],
    ["\x1b[200~paste\tA\r\nline 2\x1b[201~", "\r"],
    ["cat💙dog", "\x1b[D", "\x1b[D", "\x1b[D", "\x7f", "\r"],
    ["\x1b[A", "\r"],
    ["draft", "\x1b[A", "\x1b[A", "\x1b[B", "!", "\r"],
    ["top", "\x1b[13;2~", "bottom", "\r"],
    ["\x1b[200~alpha\x1b[106;5ubeta\x1b[201~", "\r"],
    ["aéb", "\x1b[D", "\x7f", "\r"],
    ["👩🏽‍💻x", "\x1b[D", "\x1b[D", "\x1b[C", "!", "\r"],
    ["a👩‍💻b", "\x1b[D", "\x1b[D", "\x04", "\r"],
    ["\x1b[A", "!", "\x1b[A", "\x1b[A", "\x1b[B", "?", "\r"],
    ["abcd", "\x7f", "\x1f", "\r"],
    ["first", "\n", "second", "\x1b[H", "!", "\r"],
    ["first", "\n", "second", "\x1b[H", "\x1b[F", "!", "\r"],
    ["abc", "\x14", "\x10", "\x0c", "\x0e", "\r"],
    ["abc", "\x1b[1;2D", "\x7f", "\r"],
];
for (const input of inputs) for (const key of input) editor.handleInput(key);
process.stdout.write(JSON.stringify({ inputs, submitted }));
