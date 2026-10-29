# Providers

The runtime uses native Julia HTTP and JSON. `OpenAI` speaks the OpenAI-compatible Chat Completions API, including OpenRouter. Supply a model ID and an API key; arbitrary provider-specific request parameters may be passed to `stream` or `respond!` via `parameters`.

For OpenAI, set `OPENAI_MODEL` and `OPENAI_API_KEY`; `OPENAI_BASE_URL` optionally overrides `https://api.openai.com/v1`. An API key is separate from a ChatGPT subscription. ChatGPT subscription login and the OpenAI Responses API are not implemented.

For OpenRouter, set `JF_PROVIDER=openrouter`, `OPENROUTER_MODEL`, and `OPENROUTER_API_KEY`. `OPENROUTER_BASE_URL` optionally overrides `https://openrouter.ai/api/v1`. Alternatively, set `OPENROUTER_MODEL` and run:

```sh
julia --project=. -m JuliaForever --login-openrouter 'Your prompt'
```

Open the printed URL, authorize the application, and paste the displayed code. This uses OpenRouter's headless PKCE flow and keeps the resulting API key in memory for that process; it does not save a credential. Omit the prompt to start an interactive session after login. A real login has not been tested; synthetic local exchanges are covered by tests. See the [OpenRouter OAuth guide](https://openrouter.ai/docs/guides/overview/auth/oauth) and [OpenAI API authentication](https://developers.openai.com/api/reference/overview).

Streaming can be used directly or through the agent:

```julia
using JuliaForever

agent = Agent(provider(), [Read(pwd()), Write(pwd()), Edit(pwd())])
answer = respond!(agent, "Summarize this project"; on_event=event -> begin
    event.type == :text && print(event.text)
end)
```

Callbacks receive raw `:provider` chunks and `:text`, `:thinking`, `:tool_call`, `:usage`, `:finish`, and final `:done` or `:incomplete` events. Text and function-call fragments are assembled into the assistant message, and function calls run through the normal agent loop. An incomplete stream returns a `Completion` instead of a final answer; `done` requires a recognized finish reason and the `[DONE]` marker. `usage` is `nothing` if the provider does not report it. Otherwise, input excludes reported cache reads and writes, output includes reported reasoning tokens, and cost is taken from reported OpenRouter usage, including reported upstream cost for BYOK. HTTP failures propagate from HTTP.jl.

This is a subset of Pi's providers. Only the first choice is processed. OpenAI Responses, ChatGPT authentication, images, structured reasoning replay, and Pi's complete model catalog, provider options, and event format are not implemented.
