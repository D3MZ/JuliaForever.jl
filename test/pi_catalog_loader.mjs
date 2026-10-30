import { registerHooks } from "node:module";
import { basename, join } from "node:path";
import { pathToFileURL } from "node:url";

// The pinned source checkout omits generated model data. CI installs the
// corresponding Pi package alongside it; load only that data from the package.
registerHooks({
    resolve(specifier, context, nextResolve) {
        if (specifier.startsWith("./data/") && context.parentURL?.includes("/packages/ai/src/providers/")) {
            const file = join(process.env.PI_SOURCE, "node_modules/@earendil-works/pi-ai/dist/providers/data", basename(specifier));
            return { url: pathToFileURL(file).href, shortCircuit: true };
        }
        return nextResolve(specifier, context);
    },
});
