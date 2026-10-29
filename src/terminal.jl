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

result!(terminal::Terminal, result::Completion) = result!(terminal, result, result.error)
result!(terminal::Terminal, ::Completion, failure::InvalidResponse) = failure!(terminal, failure)

function result!(terminal::Terminal, ::Truncated)
    println(terminal.diagnostics, "Response was truncated: the model reached its output token limit.")
    flush(terminal.diagnostics)
    1
end

function result!(terminal::Terminal, result::Completion, ::Union{Nothing, String})
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
    history = open(History.SQLite, path; create=false)
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
        if entry.exception isa Union{HTTP.HTTPError, InterruptException}
            line!(terminal)
            terminal.streamed = false
            return (; value=nothing, status=failure!(terminal, entry.exception))
        end
    end
    (; value=fetch(task), status=0)
end

function failures!(terminal::Terminal, listener::Extensions.Listener)
    for failure in Extensions.failures(listener)
        println(terminal.diagnostics, "[plugin] ", redact(terminal, failure.plugin), " ", failure.event, ": ", redact(terminal, sprint(showerror, failure.exception)))
    end
    flush(terminal.diagnostics)
end

failures!(::Terminal, ::Function) = nothing
observer(terminal::Terminal, ::Nothing) = event -> render!(terminal, event)
observer(terminal::Terminal, snapshot::Extensions.Snapshot) = Extensions.listen(snapshot; on_event=event -> render!(terminal, event))

function run!(terminal::Terminal, agent::Agent, prompt, snapshot=nothing)
    callback = observer(terminal, snapshot)
    result = try
        request!(terminal) do
            respond!(agent, prompt; on_event=event -> event.type == :text && text!(terminal, event.text), on_agent_event=callback)
        end
    finally
        failures!(terminal, callback)
    end
    result.status == 0 || return result.status
    result!(terminal, result.value)
end

mutable struct InputHistory <: REPL.LineEdit.HistoryProvider
    entries::Vector{String}
    drafts::Dict{Int, String}
    index::Int
end

InputHistory() = InputHistory(String[], Dict{Int, String}(), 1)

function reset!(history::InputHistory)
    empty!(history.drafts)
    history.index = length(history.entries) + 1
    nothing
end

function REPL.LineEdit.add_history(history::InputHistory, state::REPL.LineEdit.PromptState)
    text = REPL.LineEdit.input_string(state)
    isempty(text) || text == "/exit" || push!(history.entries, text)
    reset!(history)
end

function history!(state::REPL.LineEdit.MIState, history::InputHistory, step)
    target = history.index + step
    if target < 1 || target > length(history.entries) + 1
        REPL.LineEdit.beep(state)
        return
    end
    history.drafts[history.index] = REPL.LineEdit.input_string(state)
    history.index = target
    text = get(history.drafts, target, target <= length(history.entries) ? history.entries[target] : "")
    REPL.LineEdit.replace_line(state, text)
    if step < 0
        REPL.LineEdit.move_input_start(state)
        REPL.LineEdit.move_line_end(state)
    else
        REPL.LineEdit.move_input_end(state)
    end
    REPL.LineEdit.refresh_line(state)
end

REPL.LineEdit.history_prev(state::REPL.LineEdit.MIState, history::InputHistory) = history!(state, history, -1)
REPL.LineEdit.history_next(state::REPL.LineEdit.MIState, history::InputHistory) = history!(state, history, 1)
REPL.LineEdit.history_first(state::REPL.LineEdit.MIState, history::InputHistory) = history!(state, history, 1 - history.index)
REPL.LineEdit.history_last(state::REPL.LineEdit.MIState, history::InputHistory) = history!(state, history, length(history.entries) + 1 - history.index)

function unsupported!(state::REPL.LineEdit.MIState, action)
    edit = REPL.LineEdit
    edit.move_input_end(state)
    edit.refresh_line(state)
    println(edit.terminal(state))
    println(edit.terminal(state), action, " is not supported.")
    edit.state(state).ias = edit.InputAreaState(0, 0)
    edit.refresh_line(state)
end

function edit!(terminal::Terminal, agent::Agent, snapshot=nothing)
    edit = REPL.LineEdit
    history = InputHistory()
    newline = (state, args...) -> edit.edit_insert_newline(state, 0)
    keymap = Dict{Any, Any}(
        '\n' => newline,
        "\e[13;2u" => newline,
        "\e[27;2;13~" => newline,
        "\e\r" => (state, args...) -> unsupported!(state, "Alt+Enter follow-up"),
        "\e\n" => (state, args...) -> unsupported!(state, "Alt+Enter follow-up"),
        "^G" => (state, args...) -> unsupported!(state, "External editor"),
        "\ee" => (state, args...) -> unsupported!(state, "External editor"),
        "\em" => nothing,
        "\e." => nothing,
        "\e[200~" => (state, args...) -> begin
            text = readuntil(edit.terminal(state), "\e[201~")
            edit.edit_insert(state, replace(text, "\r\n" => "\n", '\r' => '\n'))
        end,
        "^D" => (state, args...) -> begin
            if isempty(edit.input_string(state))
                println(edit.terminal(state))
                :abort
            else
                edit.edit_delete(state)
            end
        end,
        "^C" => (state, args...) -> begin
            edit.cancel_beep(state)
            edit.move_input_end(state)
            edit.refresh_line(state)
            print(edit.terminal(state), "^C\n")
            edit.transition(state, :reset)
            reset!(history)
            edit.refresh_line(state)
        end,
    )
    prompt = edit.Prompt("> "; hist=history, keymap_dict=edit.keymap(Dict{Any, Any}[keymap, edit.history_keymap, edit.default_keymap, edit.escape_defaults]))
    interface = edit.ModalInterface(edit.TextInterface[prompt])
    tty = REPL.Terminals.TTYTerminal(get(ENV, "TERM", ""), stdin, stderr, stderr)
    state = edit.init_state(tty, interface)
    status = 0
    while true
        buffer, ok, suspend = edit.prompt!(tty, interface, state)
        if suspend
            @static if Sys.isunix()
                ccall(:jl_repl_raise_sigtstp, Cint, ())
            end
            continue
        end
        ok || break
        text = String(take!(buffer))
        edit.reset_state(state)
        text == "/exit" && break
        status = max(status, run!(terminal, agent, text, snapshot))
    end
    status
end
