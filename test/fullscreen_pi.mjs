import { pathToFileURL } from "node:url";

const { TuiAltScreen } = await import(pathToFileURL(`${process.env.PI_SOURCE}/packages/tui/src/tui-alt-screen.ts`).href);
const { Text } = await import(pathToFileURL(`${process.env.PI_SOURCE}/packages/tui/src/components/text.ts`).href);
class Terminal {
  columns = 80;
  rows = 24;
  output = "";
  start() {} stop() {} async drainInput() {} write(data) { this.output += data; }
  get kittyProtocolActive() { return false; }
  moveBy() {} hideCursor() {} showCursor() {} clearLine() {} clearFromCursor() {} clearScreen() {} setTitle() {} setProgress() {} setProgramStatus() {}
}
const terminal = new Terminal();
const screen = new TuiAltScreen(terminal, false, process.env.TMPDIR || "/tmp", { mouse: false });
screen.addChild(new Text(Array.from({ length: 40 }, (_, i) => `marker-${String(i).padStart(2, "0")}`).join("\n"), 0, 0));
screen.start();
screen.renderNow();
screen.scrollToTop();
screen.renderNow();
const top = screen.getScreenLines().join("\n");
screen.scrollToBottom();
screen.renderNow();
const bottom = screen.getScreenLines().join("\n");
screen.stop();
console.log(JSON.stringify({ enter: terminal.output.includes("\x1b[?1049h"), exit: terminal.output.includes("\x1b[?1049l"), top: top.includes("marker-00") && !top.includes("marker-39"), bottom: bottom.includes("marker-39") }));
