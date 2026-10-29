module Logs

using JSON3
import ..Kernel

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

end
