# Providers

The runtime uses native Julia HTTP and JSON. `OpenAI` speaks the OpenAI-compatible Chat Completions API, including OpenRouter. `OpenAIResponses` uses the OpenAI Responses API. Supply a model ID and an API key; request parameters may be passed to `stream` or `respond!` via `parameters`.

For OpenAI, set `OPENAI_MODEL` and `OPENAI_API_KEY`; `OPENAI_BASE_URL` optionally overrides `https://api.openai.com/v1`. Set `JF_PROVIDER=openai-responses` to use Responses instead of the default Chat Completions provider. Tool calling with GPT-6 Astra and GPT-6.1 Sol requires Responses. An API key is separate from a ChatGPT subscription. OpenAI documents [a separate sign-in flow for eligible ChatGPT plan usage](https://developers.openai.com/siwc/token-sharing-open-source), but this project does not implement it yet; see the [design and remaining work](chatgpt-auth.md). See also [OpenAI's model guidance](https://developers.openai.com/api/docs/guides/latest-model).

Responses converts conversation history and local tool definitions to native input items. It keeps output items, including encrypted reasoning, for replay with `function_call_output` items and sends `store=false` by default. `parameters` can override `store` and add options such as `reasoning`; `reasoning.encrypted_content` is included for replay. The implementation does not provide `previous_response_id` or Conversations API state management; use its manually replayed history for multi-turn calls. See the [Responses migration guide](https://developers.openai.com/api/docs/guides/migrate-to-responses) and [function calling guide](https://developers.openai.com/api/docs/guides/function-calling).

For OpenRouter, set `JF_PROVIDER=openrouter`, `OPENROUTER_MODEL`, and `OPENROUTER_API_KEY`. `OPENROUTER_BASE_URL` optionally overrides `https://openrouter.ai/api/v1`. Alternatively, set `OPENROUTER_MODEL` and run:

```sh
julia --project=. -m JuliaForever --login-openrouter 'Your prompt'
```

Open the printed URL, authorize the application, and paste the displayed code. This uses OpenRouter's headless PKCE flow. When the browser and Julia run on the same machine, use `--login-openrouter-callback` instead to receive the code automatically on a temporary loopback listener. The listener uses a random callback path, validates the returned state, accepts one result and times out after five minutes. Both flows keep the resulting API key in memory for that process and do not save a credential. Omit the prompt to start an interactive session after login. Real login has not been tested; synthetic local exchanges are covered by tests. See the [OpenRouter OAuth guide](https://openrouter.ai/docs/guides/overview/auth/oauth) and [OpenAI API authentication](https://developers.openai.com/api/reference/overview).

Streaming can be used directly or through the agent:

```julia
using JuliaForever

agent = Agent(provider(), [Read(pwd()), Write(pwd()), Edit(pwd())])
answer = respond!(agent, "Summarize this project"; on_event=event -> begin
    event.type == :text && print(event.text)
end)
```

Callbacks receive raw `:provider` events and `:text`, `:thinking`, `:tool_call`, `:usage`, `:finish`, and final `:done` or `:incomplete` events. The agent executes completed function calls through its normal tool loop. An interrupted, failed, or incomplete response returns a `Completion` instead of a final answer and does not execute its calls. Chat Completions streaming requires a recognized finish reason and the `[DONE]` marker; Responses streaming requires a completed terminal event and completed, consistent function-call items. HTTP failures propagate from HTTP.jl. `usage` is `nothing` when unreported; otherwise, input excludes reported cache reads and writes and output includes reasoning tokens. Cost is reported only when supplied by a compatible Chat Completions provider.

Malformed JSON returns an incomplete `Completion` whose `error` is an `InvalidResponse` value; the raw malformed payload is not included. This applies to streamed and nonstreamed completions. A malformed OpenRouter authorization exchange returns `InvalidResponse` directly. Other parsing exceptions and HTTP failures propagate. Once a stream encounters malformed JSON, later events in that stream are ignored.

A `Read` image result retains its text and attachment in typed conversation observations and recorded history. Chat Completions sends the text as a tool message and follows consecutive tool results with a user message containing the image; Responses uses `input_text` and `input_image` in `function_call_output`. Both send the original bytes as data URLs, including on replay. Custom providers receive an `image` field on the tool message and must handle it explicitly. A compatible, image-capable model is required; provider/model capability detection is not implemented. Histories, logs, and subsequent requests contain the image data.

This is a subset of Pi's providers. Only the first Chat Completions choice is processed. Responses handles text, refusal, reasoning and function-call items, with local function results. Other image input paths, image generation, built-in hosted tools, audio, ChatGPT authentication, cross-provider/model reasoning handoff, and Pi's complete model catalog, provider options, and event format are not implemented. Image request shapes and Responses behavior have been tested with synthetic loopback fixtures, not a live model.
