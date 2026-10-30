mutable struct Terminal{O<:IO, E<:IO}
    output::O
    diagnostics::E
    secrets::Vector{String}
    streamed::Bool
    lineopen::Bool
end

Terminal(output, diagnostics, secrets) = Terminal(output, diagnostics, secrets, false, false)

# A following hexadecimal or octal digit can change the last escape.
forms(secret) = (chop(repr(secret * "0"); head=1, tail=2), chop(repr(secret); head=1, tail=1), secret)
redacted(text, form) = replace(text, form => "[redacted]")

function redact(terminal::Terminal, text)
    result = string(text)
    for secret in terminal.secrets
        isempty(secret) || (result = foldl(redacted, forms(secret); init=result))
    end
    result
end

function text!(terminal::Terminal, text)
    isempty(text) && return
    print(terminal.output, text)
    flush(terminal.output)
    terminal.streamed = true
    terminal.lineopen = !endswith(text, '\n')
end

function line!(terminal::Terminal)
    terminal.lineopen && println(terminal.output)
    flush(terminal.output)
    terminal.lineopen = false
end

status(::Terminal, ::ToolSuccess) = "ok"
status(terminal::Terminal, result::ToolFailure) = "error: " * redact(terminal, result.text)

function render!(terminal::Terminal, event)
    if event.type == :message_end && get(event.message, "role", nothing) == "assistant"
        content = get(event.message, "content", nothing)
        !terminal.streamed && content isa AbstractString && text!(terminal, content)
        line!(terminal)
        terminal.streamed = false
    elseif event.type == :tool_execution_start
        println(terminal.diagnostics, "[tool] ", redact(terminal, something(event.tool_name, "unknown")), ": started")
        flush(terminal.diagnostics)
    elseif event.type == :tool_execution_end
        name = redact(terminal, something(event.tool_name, "unknown"))
        result = status(terminal, event.result)
        println(terminal.diagnostics, "[tool] ", name, ": ", result)
        flush(terminal.diagnostics)
    end
end

function result!(terminal::Terminal, result::Completion)
    result.error isa InvalidResponse && return failure!(terminal, result.error)
    detail = result.finish == "content_filter" ? "content was filtered" : result.finish == "failed" ? "the provider reported failure" : result.finish == "incomplete" ? "the provider reported incomplete output" : "the provider stream did not finish"
    println(terminal.diagnostics, "Response incomplete: ", detail)
    flush(terminal.diagnostics)
    1
end

function result!(terminal::Terminal, result::Symbol)
    println(terminal.diagnostics, "Request ", result, ".")
    flush(terminal.diagnostics)
    result == :cancelled ? 130 : 1
end

result!(::Terminal, ::Union{AbstractString, Nothing}) = 0

function result!(terminal::Terminal, result::History.Rejected)
    if result.reason == :uncertain_effect
        println(terminal.diagnostics, "History has an uncertain pending effect. It was not retried. Use --inspect-history and inspect external state, then use --abandon with a reason before continuing.")
    elseif result.reason == :incomplete_turn
        println(terminal.diagnostics, "History has an incomplete turn. Use --inspect-history and inspect external state, then use --abandon with a reason before continuing.")
    elseif result.reason == :not_interrupted
        println(terminal.diagnostics, "History has no interrupted turn to abandon.")
    else
        println(terminal.diagnostics, "History rejected: ", result.reason, ".")
    end
    flush(terminal.diagnostics)
    1
end

function historyagent(f, terminal::Terminal, path)
    path = expanduser(path)
    if !isfile(path)
        println(terminal.diagnostics, "Recovery requires an existing history file.")
        return 2
    end
    history = SessionCatalog.adapt(open(History.SQLite, path; create=false))
    history isa History.Rejected && return result!(terminal, history)
    try
        snapshot = History.snapshot(history)
        snapshot isa History.Rejected && return result!(terminal, snapshot)
        snapshot.revision == 0 && return result!(terminal, History.Rejected(:not_interrupted))
        agent = Agent(nothing, []; history)
        agent isa History.Rejected && return result!(terminal, agent)
        f(agent)
    finally
        close(history)
    end
end

function abandonhistory!(terminal::Terminal, path, reason)
    historyagent(terminal, path) do agent
        result = abandon!(agent, reason)
        result isa History.Rejected && return result!(terminal, result)
        println(terminal.output, "Interrupted turn abandoned. No effect was retried or undone.")
        flush(terminal.output)
        0
    end
end

function inspect!(terminal::Terminal, effect::Union{Conversation.ToolRequest, Conversation.SkipRequest})
    println(terminal.output, "Pending tool: ", repr(effect.call.name))
    println(terminal.output, "Arguments: ", repr(effect.call.arguments))
end

inspect!(terminal::Terminal, ::Conversation.ModelRequest) = println(terminal.output, "Pending model request")

function inspecthistory!(terminal::Terminal, path)
    historyagent(terminal, path) do agent
        println(terminal.output, "History status: ", isnothing(agent.fault) ? "ready" : string(agent.fault.reason))
        for pending in agent.state.kernel.pending
            println(terminal.output, "Effect ID: ", repr(pending.id))
            inspect!(terminal, pending.effect)
        end
        flush(terminal.output)
        0
    end
end

function failure!(terminal::Terminal, exception::HTTP.StatusError)
    println(terminal.diagnostics, "Request failed (HTTP ", exception.status, ").")
    flush(terminal.diagnostics)
    1
end

function failure!(terminal::Terminal, exception::InterruptException)
    println(terminal.diagnostics, "Request interrupted.")
    flush(terminal.diagnostics)
    130
end

function failure!(terminal::Terminal, exception::HTTP.HTTPError)
    println(terminal.diagnostics, "Request failed (", nameof(typeof(exception)), ").")
    flush(terminal.diagnostics)
    1
end

function failure!(terminal::Terminal, ::InvalidResponse)
    println(terminal.diagnostics, "Request failed (invalid provider response).")
    flush(terminal.diagnostics)
    1
end

function request!(terminal::Terminal, task, exception::Union{HTTP.HTTPError, InterruptException})
    line!(terminal)
    terminal.streamed = false
    (; value=nothing, status=failure!(terminal, exception))
end

request!(terminal::Terminal, task, exception) = (; value=fetch(task), status=0)

function request!(f, terminal::Terminal)
    task = Threads.@spawn f()
    ready = Channel{Nothing}(1)
    Threads.@spawn begin
        try
            wait(task)
        catch
        end
        put!(ready, nothing)
    end
    take!(ready)
    if istaskfailed(task)
        entry = last(current_exceptions(task))
        return request!(terminal, task, entry.exception)
    end
    (; value=fetch(task), status=0)
end

function run!(terminal::Terminal, agent::Agent, prompt)
    result = request!(terminal) do
        respond!(agent, prompt; on_event=event -> event.type == :text && text!(terminal, event.text), on_agent_event=event -> render!(terminal, event))
    end
    result.status == 0 || return result.status
    result!(terminal, result.value)
end
