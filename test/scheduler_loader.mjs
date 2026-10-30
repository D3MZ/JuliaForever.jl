import { existsSync, readFileSync } from "node:fs";
import { join, resolve as pathResolve } from "node:path";
import { pathToFileURL } from "node:url";

const root = process.env.PI_SOURCE;
const packages = {
  chord: "chord",
  "pi-ai": "ai",
  "pi-codemode": "codemode",
  "pi-durable": "durable",
  "pi-telemetry": "telemetry",
};

export async function resolve(specifier, context, nextResolve) {
  const match = /^@earendil-works\/([^/]+)(.*)$/.exec(specifier);
  if (match && packages[match[1]]) {
    const directory = join(root, "packages", packages[match[1]]);
    const manifest = JSON.parse(readFileSync(join(directory, "package.json"), "utf8"));
    const entry = manifest.exports[match[2] ? `.${match[2]}` : "."];
    let source = typeof entry === "string" ? entry : entry?.source;
    if (!source) {
      const stem = join(directory, "src", match[2] || "index");
      source = [stem + ".ts", join(stem, "index.ts")].find(existsSync);
    }
    if (source) return nextResolve(pathToFileURL(pathResolve(directory, source)).href, context);
  }
  return nextResolve(specifier, context);
}
