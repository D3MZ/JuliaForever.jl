module Logs

using JSON3
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
record(value::Conversation.Dequeue) = (; type="dequeue", value.revision)
record(value::Conversation.SessionName) = (; type="session_name", value.revision, value.name)
record(value::Conversation.Advance) = (; type="advance", value.revision)
record(value::Conversation.Cancel) = (; type="cancel", value.revision)
record(value::Conversation.History) = (; type="history", value.revision, messages=map(record, value.messages))
record(value::Conversation.Interrupt) = (; type="interrupt", value.revision, value.reason)
record(value::Conversation.State) = (; type="conversation", kernel=record(value.kernel), value.revision, messages=map(record, value.messages), phase=string(value.phase), value.order, calls=map(record, value.calls), value.steering, value.followups, value.automatic, value.cancelled, value.flushed)

"""
    json([io,] history; project=record)

Write a finite history as a JSON array, or return the JSON as a string when `io` is omitted. The history is traversed once, in order. `project` maps each record to a JSON3-compatible value and defaults to `record`, which can be extended for native record types.
"""
function json(io::IO, history; project=record)
    print(io, '[')
    first = true
    for item in history
        first || print(io, ',')
        JSON3.write(io, project(item))
        first = false
    end
    print(io, ']')
    nothing
end

json(history; project=record) = sprint(io -> json(io, history; project))

escape(text::AbstractString) = replace(text, '&' => "&amp;", '<' => "&lt;", '>' => "&gt;", '"' => "&quot;", '\'' => "&#39;")

"""
    html([io,] history; project=record, title="Julia Forever history")

Write a self-contained HTML view of a finite history, or return it as a string when `io` is omitted. Each projected record is displayed as escaped, formatted JSON. The history is traversed once, in order.
"""
function html(io::IO, history; project=record, title="Julia Forever history")
    heading = escape(title)
    print(io, "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>", heading, "</title><style>body{font:16px system-ui,sans-serif;line-height:1.5;max-width:70rem;margin:2rem auto;padding:0 1rem}li{margin:1rem 0}pre{background:#f5f5f5;border-radius:.4rem;padding:1rem;white-space:pre-wrap;overflow-wrap:anywhere}</style></head><body><main><h1>", heading, "</h1>\n<ol>\n")
    empty = true
    for item in history
        data = JSON3.write(project(item))
        formatted = sprint(output -> JSON3.pretty(output, data))
        print(io, "<li><pre>", escape(formatted), "</pre></li>\n")
        empty = false
    end
    print(io, "</ol>\n")
    empty && print(io, "<p>No events.</p>\n")
    print(io, "</main></body></html>\n")
    nothing
end

html(history; project=record, title="Julia Forever history") = sprint(io -> html(io, history; project, title))


function conversationhtml(io::IO, messages; title="Julia Forever conversation")
    heading = escape(title)
    print(io, "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>", heading, "</title><style>body{font:16px system-ui,sans-serif;line-height:1.55;max-width:72rem;margin:2rem auto;padding:0 1rem;color:#1b1b1b}article{border-top:1px solid #ddd;padding:1rem 0}h2{font-size:1rem;margin:0 0 .5rem}pre{white-space:pre-wrap;overflow-wrap:anywhere;margin:0;font:inherit}details{margin:.5rem 0;padding:.6rem;background:#f4f4f4}summary{cursor:pointer;font-weight:600}</style></head><body><main><h1>", heading, "</h1>\n")
    for message in messages
        conversationmessage(io, get(message, "role", ""), message)
    end
    print(io, "</main></body></html>\n")
    nothing
end

conversationmessage(io, role, message) = nothing
function conversationmessage(io, role::AbstractString, message)
    label = get(Dict("user" => "User", "assistant" => "Assistant", "tool" => "Tool result"), role, nothing)
    conversationmessage(io, label, message, role)
end
conversationmessage(io, ::Nothing, message, role) = nothing
function conversationmessage(io, label::AbstractString, message, role)
    print(io, "<article><h2>", escape(label), "</h2>")
    conversationcontent(io, get(message, "content", nothing))
    foreach(image -> conversationimage(io, image), get(message, "images", []))
    conversationimage(io, get(message, "image", nothing))
    for call in get(message, "tool_calls", [])
        conversationcall(io, call)
    end
    print(io, "</article>\n")
    nothing
end
conversationcontent(io, ::Nothing) = nothing
conversationcontent(io, text::AbstractString) = print(io, "<pre>", escape(text), "</pre>")
conversationcontent(io, content) = print(io, "<pre>", escape(JSON3.write(content)), "</pre>")
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
    print(io, "<details><summary>", escape(name), "</summary><pre>", escape(arguments), "</pre></details>")
    nothing
end

end
