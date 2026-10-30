import { pathToFileURL } from "node:url";

const { TuiAltScreen } = await import(pathToFileURL(`${process.env.PI_SOURCE}/packages/tui/src/tui-alt-screen.ts`).href);
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
screen.start();
screen.renderNow();
screen.stop();
console.log(JSON.stringify({ enter: terminal.output.includes("\x1b[?1049h"), exit: terminal.output.includes("\x1b[?1049l") }));
