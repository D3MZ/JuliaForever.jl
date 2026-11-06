---
name: image
description: Generate images with the Codex subscription.
metadata:
  display-name: Image generation
  order: "2"
  expected-tools: '{"generate_image":["prompt","path","host_model"],"describe_image":["path","question"]}'
---

Image generation and image description through the ChatGPT/Codex subscription, exposed as exactly
two agent tools.

tool_schemas() must return these two function schemas, with "strict" => true,
"additionalProperties" => false, and required parameters in this order:
1. generate_image: prompt (string), path (string, new .png output path relative to session.cwd or
   absolute), host_model (["string", "null"], null means gpt-6.1-sol).
2. describe_image: path (string), question (["string", "null"]).
Describe in each description that the image goes to the subscription and that session history is not
modified. run_tool routes by name; any other name returns "Error: Unknown live tool ...".

Credentials: generate_image prefers a Codex credential from joinpath(homedir(), ".codex",
"auth.json"): its tokens.access_token when it is a printable header value, plus tokens.account_id when
present. Otherwise use App.ChatGPTAuth.access_token() with no account header. describe_image uses
App.ChatGPTAuth.access_token() only, because the Codex token is rejected by api.openai.com. Never
print, log or return tokens or account ids, and sanitize provider error text: remove bearer values,
token-like words, account ids, UUIDs, data URLs and long base64 runs, cap the detail length, and never
surface an HTTP exception message because it can contain request headers. Report your own short
message instead.

generate_image:
- Require a path ending in .png, an existing parent directory, and nothing already at the path (file
  or symlink); otherwise return "Error: ...".
- POST to "https://chatgpt.com/backend-api/codex/responses" as an SSE stream with headers
  Authorization Bearer, "originator" => "JuliaForever", "OpenAI-Beta" => "responses=experimental",
  Content-Type application/json, Accept text/event-stream, User-Agent "juliaforever-image/1.0",
  plus ChatGPT-Account-ID when the credential has an account.
- Body: model is host_model when it is non-empty text else "gpt-6.1-sol"; store false; stream true;
  instructions "Generate the requested image. Do not add extra prose."; one user message whose
  content is one input_text item; tools containing {"type":"image_generation",
  "model":"gpt-image-2","size":"1024x1024"}; tool_choice {"type":"image_generation"}.
- Events: response.output_item.done may carry an item whose type is "image_generation_call" with a
  base64 result; response.completed may repeat those items in response.output; response.failed,
  response.incomplete and error report failure. Ignore event.data "[DONE]" and treat malformed JSON
  as a failure. Require a completed stream, a non-empty result, at most 24 MiB of base64, valid
  base64, and a complete PNG (signature plus IEND trailer).
- Publish through a private temporary file in the destination directory and a hard link so an
  existing file is never overwritten, removing the temporary file in all cases.
- Success returns "Saved PNG: " * path. Use connect_timeout 15, request_timeout 300,
  read_idle_timeout 180, max_sse_line_bytes 33554432 and max_sse_event_bytes 67108864.

describe_image:
- Read at most 20 MiB and require a PNG, JPEG, GIF or WebP signature.
- POST to "https://api.openai.com/v1/responses" with App.ChatGPTAuth.access_token() in Authorization
  Bearer, "originator" => "JuliaForever", "OpenAI-Beta" => "responses=experimental", Content-Type
  application/json, Accept text/event-stream, and no ChatGPT-Account-ID. Body: model = session.model,
  store false, stream true, instructions "Answer the user's question about the image.", and one user
  message with an input_text item (the question, or "Describe this image clearly and concisely."
  when it is null or blank) and an input_image item whose image_url is a data URL built from the
  detected MIME type and the base64 bytes.
- Accumulate response.output_text.delta text. If the stream completes with no deltas, take the
  output_text parts from response.output instead. Return the description text. Use connect_timeout
  15, request_timeout 240 and read_idle_timeout 120.

on_key!, on_frame!, footer, on_reload! and shutdown! must be defined no-ops returning false, nothing,
"", nothing and nothing: this feature has no keyboard or footer behavior.
