# Context estimates

`ContextEstimates` estimates the size of native `Conversation.Message` values. It is an approximation, not a tokenizer, billing calculation, context-window guarantee, or automatic compaction policy. Text is measured as UTF-16 code units at 3.5 units per estimated token. Each image in user, assistant, or tool-result content is assigned 4,800 units; images in system content are ignored. Text, thinking, tool calls, tool results, system content, and selected tool declarations contribute to the estimate. Thinking uses the first nonempty string among `reasoning_content`, `reasoning`, and `reasoning_text`, matching the provider's alias precedence.

```julia
using JuliaForever

agent = Agent(nothing, [Read(pwd())])
c = JuliaForever.Conversation
messages = c.Message[c.User("first question"), c.Assistant("answer", c.ToolCall[], "stop", true), c.User("follow-up")]
estimate = ContextEstimates.estimate(messages; tools=agent.tools)
estimate.total

# Supply a provider Usage only when it is known to describe the prefix ending at
# this assistant message. Julia indexes messages starting at 1.
usage = Usage(70, 20, 8, 2, 0, 100, nothing)
estimate = ContextEstimates.estimate(messages, 2 => usage; tools=agent.tools)
```

The second call is illustrative: the caller must know that the measurement applies to the second message and its prefix. `Estimate.total` is the reported prefix plus the estimated trailing messages; `reported`, `trailing`, and `index` expose those components. `index` is one-based; Pi's comparison output uses zero-based indexes. With no supplied measurement, or a measurement whose total and components are zero, all messages are estimated and `index` is `nothing`. When reported `total` is zero, input, output, cache-read, and cache-write values are summed. The `tools` argument accepts a collection or dictionary of native tools. It is included in a wholly estimated context; a positive reported prefix is assumed already to include its tools. The caller must account separately for tool changes after that prefix.

Native conversation snapshots do not currently retain the per-message usage and timestamps needed to choose a trustworthy measurement or detect stale usage automatically. The API does not infer an anchor from message metadata. A caller must discard an anchor after an edit, compaction, model or tool change that makes it inapplicable. The estimator counts only the top-level reasoning aliases described above; it does not count reasoning summaries or encrypted content inside Responses `response_output` items. OpenAI-compatible streamed reasoning is currently emitted to callbacks without being retained in the final message. The estimate is not connected to the CLI, output-token limits, or compaction.

The native tool-call representation retains its argument JSON as a string; the estimate counts that original string, including whitespace and numeric spelling. Pi's estimator reserializes an argument object. The differential fixtures demonstrate differences for whitespace, negative zero, some large integers, and `1e-6`; these are intentional representation differences, not matching cases. Malformed partial tool-call arguments are also counted as supplied. Tool declarations are serialized with JSON3, which can likewise format some numbers differently from JavaScript. System messages may supply `sections`, `toolsAdded`, or `toolsRemoved`; do not also pass the same declarations through `tools`, or they will be counted twice. Raw messages support `system`, `user`, `assistant`, and `tool` roles with text or image content blocks; other raw roles or content blocks are not supported by this estimator. Text inputs are expected to be valid Unicode.

The pinned Pi `packages/ai/src/utils/estimate.ts` supplies the comparison for this API. Tests compare selected system, Unicode, image, tool, and caller-selected usage cases. Pi's separate coding-agent compaction estimator, projection and automatic stale-measurement detection are outside this API. OpenAI's [token-counting documentation](https://developers.openai.com/api/docs/guides/token-counting) describes the provider endpoint for request-specific counts including message framing, tools, images, and files. This local estimate performs no network request and makes no model-vocabulary claim. Tests for this feature have run on macOS; other platforms are unverified.
