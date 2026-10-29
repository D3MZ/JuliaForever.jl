mutable struct Terminal{O<:IO, E<:IO}
    output::O
    diagnostics::E
    secrets::Vector{String}
    streamed::Bool
    lineopen::Bool
end

Terminal(output, diagnostics, secrets) = Terminal(output, diagnostics, secrets, false, false)

function redact(terminal::Terminal, text)
    result = string(text)
    for secret in terminal.secrets
        isempty(secret) || (result = replace(result, secret => "[redacted]"))
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
        result = event.iserror ? "error: " * redact(terminal, event.result.text) : "ok"
        println(terminal.diagnostics, "[tool] ", name, ": ", result)
        flush(terminal.diagnostics)
    end
end

function result!(terminal::Terminal, result::Completion)
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

function malformed(entry)
    entry.exception isa ArgumentError || return false
    message = entry.exception.msg
    any(prefix -> startswith(message, prefix), ("invalid JSON at byte position ", "JSON invalid unicode hex value", "encountered invalid escape character in json string:", "encountered unescaped control character in json:")) && return true
    any(frame -> !isnothing(frame.linfo) && frame.linfo.def isa Method && frame.linfo.def.module === JSON3, stacktrace(entry.backtrace))
end

function request!(f, terminal::Terminal)
    task = @async f()
    ready = Channel{Nothing}(1)
    @async begin
        try
            wait(task)
        catch
        end
        put!(ready, nothing)
    end
    take!(ready)
    if istaskfailed(task)
        entry = last(current_exceptions(task))
        if entry.exception isa Union{HTTP.HTTPError, InterruptException}
            line!(terminal)
            terminal.streamed = false
            return (; value=nothing, status=failure!(terminal, entry.exception))
        elseif malformed(entry)
            line!(terminal)
            terminal.streamed = false
            println(terminal.diagnostics, "Request failed (invalid provider response).")
            flush(terminal.diagnostics)
            return (; value=nothing, status=1)
        end
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
