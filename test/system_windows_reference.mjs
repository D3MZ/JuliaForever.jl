import { mkdtemp, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { pathToFileURL } from "node:url";

const source = process.argv[2];
const { createPowerShellToolDefinition } = await import(pathToFileURL(join(source, "packages/coding-agent/src/core/tools/powershell.ts")));
const { createBashToolDefinition } = await import(pathToFileURL(join(source, "packages/coding-agent/src/core/tools/bash.ts")));
const results = [];
const tools = process.argv[3] === "bash" ? ["powershell", "bash"] : ["powershell"];
for (const tool of tools) for (const stage of ["normal", "timeout", "cancel"]) {
    const dir = await mkdtemp(join(tmpdir(), "jf-powershell-reference-"));
    const controller = new AbortController();
    try {
        const command = tool === "powershell"
            ? (stage === "normal" ? "[Console]::Write('complete')" : "[Console]::Write('before'); [Console]::Out.Flush(); [IO.File]::WriteAllText('ready','ready'); Start-Sleep -Seconds 30")
            : (stage === "normal" ? "printf complete" : "printf before; printf ready > ready; sleep 30");
        const args = stage === "timeout" ? { command, timeout: 4 } : { command };
        const definition = tool === "powershell" ? createPowerShellToolDefinition(dir) : createBashToolDefinition(dir);
        const promise = definition.execute("fixture", args, controller.signal).then(
            value => ({ text: value.content.find(block => block.type === "text").text, iserror: value.isError === true }),
            exception => ({ text: exception.message, iserror: true }),
        );
        if (stage === "cancel") {
            const deadline = Date.now() + 15000;
            while (Date.now() < deadline && !(await stat(join(dir, "ready")).then(() => true, () => false))) await delay(20);
            if (Date.now() >= deadline) throw new Error(`${tool} did not start`);
            controller.abort();
        }
        results.push(await promise);
    } finally {
        controller.abort();
        await rm(dir, { recursive: true, force: true });
    }
}

if (tools.includes("bash")) {
    const dir = await mkdtemp(join(tmpdir(), "jf-bash-trace-"));
    const saved = Object.fromEntries(["SHELLOPTS", "BASHOPTS", "BASH_ENV", "BASH_XTRACEFD", "PS4"].map(name => [name, process.env[name]]));
    try {
        process.env.PS4 = "+ ";
        delete process.env.BASH_ENV;
        delete process.env.BASH_XTRACEFD;
        delete process.env.BASHOPTS;
        const cases = [];
        for (const options of ["xtrace", "verbose", "verbose:xtrace", "posix", "noexec", "posix:verbose:xtrace", "noexec:verbose:xtrace", "posix:noexec:verbose:xtrace", "allexport:noclobber", "privileged:xtrace"]) {
            process.env.SHELLOPTS = options;
            const result = await createBashToolDefinition(dir).execute("trace", { command: "printf complete >&2", timeout: 30 }, new AbortController().signal);
            cases.push({ text: result.content.find(block => block.type === "text").text, iserror: result.isError === true });
        }
        delete process.env.SHELLOPTS;
        const bashcases = [];
        for (const [shell, options] of [[null, "extdebug"], [null, "expand_aliases"], [null, "failglob"], [null, "extdebug:expand_aliases"], ["posix:xtrace", "extdebug:expand_aliases"]]) {
            if (shell === null) delete process.env.SHELLOPTS;
            else process.env.SHELLOPTS = shell;
            process.env.BASHOPTS = options;
            const result = await createBashToolDefinition(dir).execute("options", { command: "printf complete >&2", timeout: 30 }, new AbortController().signal);
            bashcases.push({ text: result.content.find(block => block.type === "text").text, iserror: result.isError === true });
        }
        results.push({ cases, bashcases });
    } finally {
        for (const [name, value] of Object.entries(saved)) value === undefined ? delete process.env[name] : process.env[name] = value;
        await rm(dir, { recursive: true, force: true });
    }
} else results.push(null);

{
    const dir = await mkdtemp(join(tmpdir(), "jf-powershell-parse-"));
    try {
        const command = "[IO.File]::WriteAllText('unreachable','bad'); if (";
        const result = await createPowerShellToolDefinition(dir).execute("parse", { command, timeout: 30 }, new AbortController().signal);
        results.push({ text: result.content.find(block => block.type === "text").text, iserror: result.isError === true });
    } finally {
        await rm(dir, { recursive: true, force: true });
    }
}

// The child has a bounded lifetime and exits after the release file appears.
{
    const { writeFile } = await import("node:fs/promises");
    const dir = await mkdtemp(join(tmpdir(), "jf-pi-background-"));
    const quote = value => "'" + value.replaceAll("'", "''") + "'";
    const child = join(dir, "child.ps1");
    const ready = join(dir, "ready");
    const release = join(dir, "release");
    const late = join(dir, "late");
    await writeFile(child, `$end = (Get-Date).AddSeconds(30); [IO.File]::WriteAllText(${quote(ready)}, 'ready'); while (!(Test-Path -LiteralPath ${quote(release)}) -and (Get-Date) -lt $end) { Start-Sleep -Milliseconds 50 }; if (Test-Path -LiteralPath ${quote(release)}) { [IO.File]::WriteAllText(${quote(late)}, 'late') }`);
    const command = `$exe = (Get-Process -Id $PID).Path; Start-Process -FilePath $exe -ArgumentList ('-NoProfile -NonInteractive -File "' + ${quote(child)} + '"') | Out-Null; while (!(Test-Path -LiteralPath ${quote(ready)})) { Start-Sleep -Milliseconds 50 }; [Console]::Write('complete')`;
    const controller = new AbortController();
    try {
        const result = await createPowerShellToolDefinition(dir).execute("background", { command, timeout: 20 }, controller.signal);
        await writeFile(release, "release");
        const deadline = Date.now() + 10000;
        while (Date.now() < deadline && !(await stat(late).then(() => true, () => false))) await delay(50);
        results.push({ background: await stat(late).then(() => true, () => false), text: result.content.find(block => block.type === "text").text });
    } finally {
        controller.abort();
        await writeFile(release, "release");
        await delay(500);
        await rm(dir, { recursive: true, force: true });
    }
}

process.stdout.write(JSON.stringify(results));
