# Model catalog

`jf --list-models [search]` lists chat models for providers with available credentials, showing context and output limits, reasoning, and image-input metadata. Search accepts space- or slash-separated fuzzy terms. Listing does not contact a provider.

`--model` resolves a case-insensitive model ID, provider-prefixed ID, or ID/name substring. When several providers offer the same ID, configured credentials can select a single provider; otherwise use `--provider` or a `provider/model` reference. Exact catalog IDs containing slashes or colons remain valid. Unknown IDs continue to work with the selected or default provider, except that recognized thinking suffixes are rejected as described below. Recognized OpenAI catalog models use the Responses adapter; explicitly selecting `openai-responses` has the same effect. Environment model variables still select literal IDs using their configured adapter.

The bundled snapshot contains 457 chat models: OpenAI Responses, Anthropic Messages, Google Generative AI, and OpenRouter Chat Completions. It was generated on 2026-10-30 using Pi revision `e7a0df27c09d11bf4161d3605246cbf57a129cb2` and that generator's live upstream sources. The snapshot can become stale and does not guarantee current availability, limits, or pricing. OpenRouter models whose Pi catalog entry uses its Anthropic API are omitted; this harness does not yet implement that transport. Image and reasoning columns describe the catalog, not a promise that every request path supports all capabilities.

The CLI reads `models.json` from `PI_CODING_AGENT_DIR` (default `~/.pi/agent`). Its `providers` entries can add models or override built-in providers and models. Supported APIs are `openai-completions`, `openai-responses`, `anthropic-messages`, and `google-generative-ai`. Provider `baseUrl`, `apiKey`, `headers`, and `authHeader`, model `baseUrl` and `headers`, and the catalog fields `id`, `name`, `api`, `reasoning`, `input`, `contextWindow`, and `maxTokens` are applied. Model definitions replace matching built-in models; `modelOverrides` updates matching model metadata and headers. A model's URL takes precedence over its provider URL. Selecting another configured model reloads its URL and headers from the startup configuration; switching between API types is unavailable.

For example, with `LOCAL_API_KEY` set, this adds a model selected by `jf --model local/example`:

```json
{
  "providers": {
    "local": {
      "baseUrl": "http://127.0.0.1:8080/v1",
      "api": "openai-completions",
      "apiKey": "$LOCAL_API_KEY",
      "models": [{ "id": "example" }]
    }
  }
}
```

Keys and headers support literals and `$NAME` or `${NAME}` environment references. A stored `auth.json` API key for the provider takes precedence; unsupported stored credential types do not fall back to the configured key. Missing references and unsupported APIs fail before a request. Secret-bearing configuration is redacted from model-registry displays and malformed JSON diagnostics. Julia Forever requires a nonempty API key, uses strict JSON with integer token limits, and does not execute `!command` values. Pi also supports keyless providers, comments, fractional token limits, credential commands, and OAuth. Configured compatibility, sampling, thinking maps, prompt cache, input limits, and OAuth fields are rejected for requests; pricing metadata is not used. The configuration is read at startup, not refreshed while a session runs. OpenRouter's interactive login currently bypasses these request overrides.

The library exposes `JuliaForever.Models.catalog()`, `JuliaForever.Models.catalog(path)`, and `JuliaForever.Models.resolve(text, models, usable; provider=nothing)`. A malformed configuration yields `Models.InvalidConfig`; the CLI reports an error without including its contents. Resolution returns typed `Resolved`, `Ambiguous`, or `Unmatched` values and identifies Pi thinking suffixes. The CLI rejects recognized thinking suffixes because it does not yet configure their provider-specific reasoning behavior. The full-screen picker lists models for the current provider. Online refresh, the complete provider catalog, model cycling, picker provider switching, and scoped-model settings remain unsupported.

To refresh the snapshot, run the pinned Pi checkout's `packages/ai/catalog/generate.ts --strict --json-only --json-output CATALOG_DIRECTORY`, then run `julia --project=. scripts/model_catalog.jl CATALOG_DIRECTORY data/models.json`. The Pi generator fetches external catalogs, so regeneration on a different date may produce different values. Review the generated diff and repeat the differential tests before committing it.
