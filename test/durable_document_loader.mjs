import { join } from "node:path";
import { pathToFileURL } from "node:url";

const chord = {
  "@earendil-works/chord": "packages/chord/src/index.ts",
  "@earendil-works/chord/context": "packages/chord/src/context/index.ts",
  "@earendil-works/chord/delta": "packages/chord/src/delta/index.ts",
  "@earendil-works/pi-telemetry": "packages/telemetry/src/index.ts",
};

export function resolve(specifier, context, nextResolve) {
  const source = chord[specifier];
  if (source) return { url: pathToFileURL(join(process.env.PI_SOURCE, source)).href, shortCircuit: true };
  return nextResolve(specifier, context);
}
