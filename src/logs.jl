module Logs

using JSON3, Markdown
import ..Kernel
import ..Conversation

record(value) = value
record(value::Kernel.Call) = (; type="call", value.name, input=record(value.input))
record(value::Kernel.Return) = (; type="return", value=record(value.value))
record(value::Kernel.Fail) = (; type="fail", value=record(value.value))
record(value::Kernel.Plan) = (; type="plan", value.revision, value.id, effect=record(value.effect))
record(value::Kernel.Observe) = (; type="observe", value.revision, value.id, observation=record(value.observation))
record(value::Kernel.Finish) = (; type="finish", value.revision)
record(value::Kernel.Pending) = (; type="pending", value.id, effect=record(value.effect))
record(value::Kernel.Observed) = (; type="observed", value.id, observation=record(value.observation))
record(value::Kernel.State) = (; type="state", value.id, value.revision, pending=map(record, value.pending), observations=map(record, value.observations), value.closed)
record(value::Kernel.Applied) = (; type="applied", state=record(value.state), effects=map(record, value.effects))
record(value::Kernel.Duplicate) = (; type="duplicate", state=record(value.state))
record(value::Kernel.Rejected) = (; type="rejected", state=record(value.state), reason=String(value.reason))
record(value::Conversation.User) = (; type="user", value.content)
record(value::Conversation.SkillContext) = (; type="skill_context", value.content)
record(value::Conversation.RawMessage) = (; type="raw_message", value.value)
record(value::Conversation.BashMessage) = (; type="bash_message", message=convert(Dict{String, Any}, value))
record(value::Conversation.ToolCall) = (; type="tool_call", value.id, value.name, value.arguments, value.metadata)
record(value::Conversation.Assistant) = (; type="assistant", value.content, calls=map(record, value.calls), value.finish, value.done, value.metadata)
record(value::Conversation.ToolMessage) = record(value, value.image)
record(value::Conversation.ToolMessage, ::Nothing) = (; type="tool_message", value.id, value.content, value.iserror)
record(value::Conversation.ToolMessage, image::Conversation.Image) = (; type="tool_message", value.id, value.content, value.iserror, image=(; image.mime, image.data))
record(value::Conversation.ModelRequest) = (; type="model_request", messages=map(record, value.messages))
record(value::Conversation.ToolRequest) = (; type="tool_request", call=record(value.call))
record(value::Conversation.SkipRequest) = (; type="skip_request", call=record(value.call))
record(value::Conversation.ModelReply) = (; type="model_reply", message=record(value.message))
record(value::Conversation.ToolReply) = record(value, value.image)
record(value::Conversation.ToolReply, ::Nothing) = (; type="tool_reply", value.text, value.iserror)
record(value::Conversation.ToolReply, image::Conversation.Image) = (; type="tool_reply", value.text, value.iserror, image=(; image.mime, image.data))
record(value::Conversation.ModelFailure) = (; type="model_failure", value.reason)
record(value::Conversation.Abandoned) = (; type="abandoned", value.reason)
record(value::Conversation.Input) = (; type="input", value.revision, value.text)
record(value::Conversation.Steer) = (; type="steer", value.revision, value.text)
record(value::Conversation.Followup) = (; type="followup", value.revision, value.text)
record(value::Conversation.ImageSteer) = (; type="steer_images", value.revision, value.text, images=value.images)
record(value::Conversation.ImageFollowup) = (; type="followup_images", value.revision, value.text, images=value.images)
record(value::Conversation.ImageUser) = (; type="user_images", value.content, images=value.images)
record(value::Conversation.SteeringMode) = (; type="steering_mode", value.revision, mode=Conversation.queuecode(value.mode))
record(value::Conversation.FollowupMode) = (; type="followup_mode", value.revision, mode=Conversation.queuecode(value.mode))
record(value::Conversation.Dequeue) = (; type="dequeue", value.revision)
record(value::Conversation.SessionName) = (; type="session_name", value.revision, value.name)
record(value::Conversation.BashOutput) = (; type="bash_output", value.revision, message=record(value.message))
record(value::Conversation.ModelEntry) = (; type="model_change", value.provider, modelId=value.model)
record(value::Conversation.ThinkingEntry) = (; type="thinking_level_change", thinkingLevel=value.level)
record(value::Conversation.MessageEntry) = (; type="message", value.message)
record(value::Conversation.NameEntry) = (; type="session_info", value.name)
record(value::Conversation.SessionRecord) = (; type="session_record", value.revision, value.id, value.parent, value.timestamp, entry=record(value.entry))
record(value::Conversation.Advance) = (; type="advance", value.revision)
record(value::Conversation.Cancel) = (; type="cancel", value.revision)
record(value::Conversation.History) = (; type="history", value.revision, messages=map(record, value.messages))
record(value::Conversation.Interrupt) = (; type="interrupt", value.revision, value.reason)
record(value::Conversation.State) = (; type="conversation", kernel=record(value.kernel), value.revision, messages=map(record, value.messages), phase=string(value.phase), value.order, calls=map(record, value.calls), steering=map(record, value.steering), followups=map(record, value.followups), steeringmode=Conversation.queuecode(value.steeringmode), followupmode=Conversation.queuecode(value.followupmode), value.automatic, value.cancelled, value.flushed)

"""
    json([io,] history; project=record)

Write a finite history as a JSON array, or return the JSON as a string when `io` is omitted. The history is traversed once, in order. `project` maps each record to a JSON3-compatible value and defaults to `record`, which can be extended for native record types.
"""
function json(io::IO, history; project=record)
    print(io, '[')
    jsonitems!(io, history, project, iterate(history))
    print(io, ']')
    nothing
end

jsonitems!(io, history, project, ::Nothing) = nothing
function jsonitems!(io, history, project, first::Tuple)
    item, state = first
    JSON3.write(io, project(item))
    for item in Iterators.rest(history, state)
        print(io, ',')
        JSON3.write(io, project(item))
    end
    nothing
end

json(history; project=record) = sprint(io -> json(io, history; project))

escape(text::AbstractString) = replace(text, '&' => "&amp;", '<' => "&lt;", '>' => "&gt;", '"' => "&quot;", '\'' => "&#39;")
include("logs_markdown.jl")

"""
    html([io,] history; project=record, title="Julia Forever history")

Write a self-contained HTML view of a finite history, or return it as a string when `io` is omitted. Each projected record is displayed as escaped, formatted JSON. The history is traversed once, in order.
"""
function html(io::IO, history; project=record, title="Julia Forever history")
    heading = escape(title)
    print(io, "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>", heading, "</title><style>body{font:16px system-ui,sans-serif;line-height:1.5;max-width:70rem;margin:2rem auto;padding:0 1rem}li{margin:1rem 0}pre{background:#f5f5f5;border-radius:.4rem;padding:1rem;white-space:pre-wrap;overflow-wrap:anywhere}</style></head><body><main><h1>", heading, "</h1>\n<ol>\n")
    first = iterate(history)
    htmlitems!(io, history, project, first)
    print(io, "</ol>\n")
    htmlnotice!(io, first)
    print(io, "</main></body></html>\n")
    nothing
end

htmlitems!(io, history, project, ::Nothing) = nothing
function htmlitems!(io, history, project, first::Tuple)
    item, state = first
    htmlitem!(io, project(item))
    for item in Iterators.rest(history, state)
        htmlitem!(io, project(item))
    end
    nothing
end
function htmlitem!(io, item)
    data = JSON3.write(item)
    formatted = sprint(output -> JSON3.pretty(output, data))
    print(io, "<li><pre>", escape(formatted), "</pre></li>\n")
end
htmlnotice!(io, ::Nothing) = print(io, "<p>No events.</p>\n")
htmlnotice!(io, ::Tuple) = nothing

html(history; project=record, title="Julia Forever history") = sprint(io -> html(io, history; project, title))

const conversationstyle = raw"""
body{font:16px system-ui,sans-serif;line-height:1.55;max-width:72rem;margin:2rem auto;padding:0 1rem;color:#1b1b1b}
nav{display:flex;flex-wrap:wrap;align-items:center;gap:.6rem;margin:1rem 0}input[type=search]{flex:1 1 14rem;padding:.45rem}
button{padding:.4rem .65rem;cursor:pointer}button:disabled{cursor:default}article{border-top:1px solid #ddd;padding:1rem 0}
article.current{border-left:3px solid #5079df;padding-left:.75rem}h2{font-size:1rem;margin:0 0 .5rem}
pre{white-space:pre-wrap;overflow-wrap:anywhere;margin:0;font:inherit}details{margin:.5rem 0;padding:.6rem;background:#f4f4f4}
summary{cursor:pointer;font-weight:600}[hidden]{display:none!important}output{min-width:8rem}output:empty{display:none}
.markdown p{margin:.5rem 0}.markdown code{font-family:ui-monospace,monospace}.markdown pre{background:#f4f4f4;padding:.75rem;overflow:auto}
.markdown table{border-collapse:collapse}.markdown th,.markdown td{border:1px solid #ddd;padding:.35rem .6rem;text-align:left}
.markdown blockquote{border-left:3px solid #ddd;margin:.5rem 0;padding-left:.8rem}
.hljs-comment,.hljs-quote{color:#5f6d76}.hljs-keyword,.hljs-selector-tag,.hljs-meta{color:#a21e43}
.hljs-number,.hljs-literal{color:#075b9b}.hljs-string,.hljs-doctag{color:#087036}
.hljs-title,.hljs-section,.hljs-name{color:#7343a1}.hljs-type,.hljs-built_in{color:#875000}
@media(max-width:36rem){input[type=search]{flex-basis:100%}output{min-width:0}}
"""

const conversationscript = raw"""
(() => {
  for (const code of document.querySelectorAll(".markdown pre code")) {
    const language = code.dataset.language;
    try {
      const result = language && hljs.getLanguage(language)
        ? hljs.highlight(code.textContent, { language })
        : hljs.highlightAuto(code.textContent);
      code.innerHTML = result.value;
      code.classList.add("hljs");
    } catch { /* Keep the escaped source visible if highlighting fails. */ }
  }
  const search = document.getElementById("conversation-search");
  const status = document.getElementById("search-status");
  const showTools = document.getElementById("show-tools");
  const previous = document.getElementById("previous-match");
  const next = document.getElementById("next-match");
  const expand = document.getElementById("expand-tools");
  const thinking = document.getElementById("toggle-thinking");
  const thoughts = Array.from(document.querySelectorAll("article details.thinking"));
  thinking.hidden = thoughts.length === 0;
  let thinkingExpanded = true;
  const articles = Array.from(document.querySelectorAll("article[data-role]"));
  let matches = [], selected = 0, expanded = false;
  function update(scroll) {
    const query = search.value.trim().toLocaleLowerCase();
    matches = [];
    for (const article of articles) {
      const visible = (showTools.checked || article.dataset.role !== "tool") && (!query || article.textContent.toLocaleLowerCase().includes(query));
      article.hidden = !visible;
      if (visible && query) matches.push(article);
    }
    selected = Math.min(selected, Math.max(0, matches.length - 1));
    status.textContent = !query ? "" : matches.length ? (selected + 1) + " of " + matches.length + " matches" : "No matches";
    previous.disabled = next.disabled = matches.length === 0;
    for (const article of articles) article.classList.toggle("current", article === matches[selected] && matches.length > 0);
    if (scroll && matches.length) matches[selected].scrollIntoView({ block: "center" });
  }
  search.addEventListener("input", () => { selected = 0; update(false); });
  showTools.addEventListener("change", () => { selected = 0; update(false); });
  previous.addEventListener("click", () => { selected = (selected + matches.length - 1) % matches.length; update(true); });
  next.addEventListener("click", () => { selected = (selected + 1) % matches.length; update(true); });
  search.addEventListener("keydown", event => {
    if (event.key === "Enter" && matches.length) { event.preventDefault(); (event.shiftKey ? previous : next).click(); }
  });
  expand.addEventListener("click", () => {
    expanded = !expanded;
    for (const details of document.querySelectorAll("article details.tool-call")) details.open = expanded;
    expand.textContent = expanded ? "Collapse tool calls" : "Expand tool calls";
  });
  thinking.addEventListener("click", () => {
    thinkingExpanded = !thinkingExpanded;
    for (const details of thoughts) details.open = thinkingExpanded;
    thinking.setAttribute("aria-pressed", String(thinkingExpanded));
    thinking.textContent = thinkingExpanded ? "Collapse thinking" : "Expand thinking";
  });
  update(false);
})();
"""

function conversationhtml(io::IO, messages; title="Julia Forever conversation")
    heading = escape(title)
    print(io, "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>", heading, "</title><style>", conversationstyle, "</style></head><body><main><h1>", heading, "</h1>\n")
    print(io, """<nav aria-label="Conversation controls"><input id="conversation-search" type="search" aria-label="Search conversation" placeholder="Search conversation"><button id="previous-match" type="button" disabled>Previous match</button><button id="next-match" type="button" disabled>Next match</button><output id="search-status" role="status" aria-live="polite"></output><label><input id="show-tools" type="checkbox" checked> Show tool results</label><button id="toggle-thinking" type="button" aria-pressed="true" hidden>Collapse thinking</button><button id="expand-tools" type="button">Expand tool calls</button></nav>\n""")
    for message in messages
        conversationmessage(io, get(message, "role", ""), message)
    end
    assets = joinpath(@__DIR__, "..", "assets")
    print(io, "</main><script>/*\n", read(joinpath(assets, "highlight-LICENSE"), String), "\n*/\n", read(joinpath(assets, "highlight.min.js"), String), "\n</script><script>", conversationscript, "</script></body></html>\n")
    nothing
end

conversationmessage(io, role, message) = nothing
function conversationmessage(io, role::AbstractString, message)
    label = get(Dict("user" => "User", "assistant" => "Assistant", "tool" => "Tool result"), role, nothing)
    conversationmessage(io, label, message, role)
end
conversationmessage(io, ::Nothing, message, role) = nothing
function conversationmessage(io, label::AbstractString, message, role)
    print(io, "<article data-role=\"", escape(role), "\"><h2>", escape(label), "</h2>")
    get(thinkingrenderers, role, nothinking)(io, message)
    conversationcontent(io, role, get(message, "content", nothing))
    foreach(image -> conversationimage(io, image), get(message, "images", []))
    conversationimage(io, get(message, "image", nothing))
    for call in get(message, "tool_calls", [])
        conversationcall(io, call)
    end
    print(io, "</article>\n")
    nothing
end
conversationcontent(io, role, ::Nothing) = nothing
conversationcontent(io, role, text::AbstractString) = get(conversationrenderers, role, plaintext)(io, text)
conversationcontent(io, role, content) = plaintext(io, JSON3.write(content))
plaintext(io, text) = print(io, "<pre>", escape(text), "</pre>")
const conversationrenderers = Dict("user" => markdowncontent, "assistant" => markdowncontent)
nothinking(io, message) = nothing
assistantthinking(io, message) = conversationthinking(io, get(message, "reasoning_content", get(message, "reasoning", get(message, "reasoning_text", nothing))))
conversationthinking(io, value) = nothing
conversationthinking(io, text::AbstractString) = conversationthinking(io, text, match(r"\S", text))
conversationthinking(io, text, ::Nothing) = nothing
function conversationthinking(io, text, ::RegexMatch)
    print(io, "<details class=\"thinking\" open><summary>Thinking</summary><pre>", escape(text), "</pre></details>")
    nothing
end
const thinkingrenderers = Dict("assistant" => assistantthinking)
conversationimage(io, image) = nothing
conversationimage(io, image::AbstractDict) = conversationimage(io, get(image, "mime", nothing), get(image, "data", nothing))
conversationimage(io, mime, data) = nothing
function conversationimage(io, mime::AbstractString, data::AbstractString)
    mime in ("image/png", "image/jpeg") || return nothing
    print(io, "<p><img alt=\"Attached image\" style=\"max-width:100%;height:auto\" src=\"data:", escape(mime), ";base64,", escape(data), "\"></p>")
    nothing
end

function conversationcall(io, call)
    fn = get(call, "function", Dict())
    name = string(get(fn, "name", "tool"))
    arguments = string(get(fn, "arguments", ""))
    print(io, "<details class=\"tool-call\"><summary>", escape(name), "</summary><pre>", escape(arguments), "</pre></details>")
    nothing
end

end
