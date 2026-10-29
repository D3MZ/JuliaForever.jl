import { createHash } from "node:crypto";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [source] = process.argv.slice(2);
const { openRouterOAuth } = await import(pathToFileURL(join(source, "packages/ai/src/auth/oauth/openrouter.ts")));
let authorization, exchange;
globalThis.fetch = async (url, options) => {
    exchange = { url, body: JSON.parse(options.body) };
    return new Response(JSON.stringify({ key: "synthetic-key" }), { status: 200, headers: { "content-type": "application/json" } });
};
const controller = new AbortController();
const credential = await openRouterOAuth.login({
    signal: controller.signal,
    notify(event) { if (event.type === "auth_url") authorization = new URL(event.url); },
    prompt: async () => "synthetic-code",
});
const body = exchange.body;
process.stdout.write(JSON.stringify({
    callback_host: new URL(authorization.searchParams.get("callback_url")).hostname,
    challenge_matches: createHash("sha256").update(body.code_verifier).digest("base64url") === authorization.searchParams.get("code_challenge"),
    challenge_method: authorization.searchParams.get("code_challenge_method"),
    exchange_url: exchange.url,
    exchange_method: body.code_challenge_method,
    code: body.code,
    key: credential.access,
}));
