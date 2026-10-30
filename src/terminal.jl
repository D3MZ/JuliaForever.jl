abstract type TerminalPresentation end
struct Unstreamed <: TerminalPresentation end
struct Streamed <: TerminalPresentation end
abstract type TerminalLine end
struct LineClosed <: TerminalLine end
struct LineOpen <: TerminalLine end
abstract type TerminalMode end
struct TextMode <: TerminalMode end
struct JSONMode <: TerminalMode
    provider::String
end
struct RPCMode <: TerminalMode
    provider::String
    thinking::Union{Nothing, String}
    model::Union{Nothing, String}
end
RPCMode(provider::String) = RPCMode(provider, nothing, nothing)
RPCMode(provider::String, thinking::Union{Nothing, String}) = RPCMode(provider, thinking, nothing)
struct InvalidMode <: TerminalMode end

const terminalmodes = Dict("text" => TextMode(), "json" => JSONMode(""), "rpc" => RPCMode(""))
terminalmode(value) = get(terminalmodes, value, InvalidMode())
assignmode(::TerminalMode, mode::TerminalMode) = mode
assignmode(invalid::InvalidMode, ::TerminalMode) = invalid
provider(mode::TerminalMode, name) = mode
provider(::JSONMode, name) = JSONMode(name)
provider(::RPCMode, name) = RPCMode(name)
thinkingmode(mode::TerminalMode, level) = mode
thinkingmode(mode::RPCMode, level) = RPCMode(mode.provider, level, mode.model)
modelmode(mode::TerminalMode, model) = mode
modelmode(mode::RPCMode, model) = RPCMode(mode.provider, mode.thinking, model)

streamstate(value::Bool) = (Unstreamed(), Streamed())[Int(value) + 1]
linestate(value::Bool) = (LineClosed(), LineOpen())[Int(value) + 1]
streamed(::Unstreamed) = false
streamed(::Streamed) = true
lineopen(::LineClosed) = false
lineopen(::LineOpen) = true

mutable struct Terminal{O<:IO, E<:IO, M<:TerminalMode}
    output::O
    diagnostics::E
    secrets::Vector{String}
    presentation::TerminalPresentation
    line::TerminalLine
    mode::M
end

Terminal(output, diagnostics, secrets) = Terminal(output, diagnostics, secrets, TextMode())
Terminal(output, diagnostics, secrets, mode::TerminalMode) = Terminal(output, diagnostics, secrets, Unstreamed(), LineClosed(), mode)
Terminal(output, diagnostics, secrets, streamed::Bool, lineopen::Bool) = Terminal(output, diagnostics, secrets, streamstate(streamed), linestate(lineopen), TextMode())

function Base.getproperty(terminal::Terminal, name::Symbol)
    name === :streamed && return streamed(getfield(terminal, :presentation))
    name === :lineopen && return lineopen(getfield(terminal, :line))
    getfield(terminal, name)
end

function Base.setproperty!(terminal::Terminal, name::Symbol, value)
    name === :streamed && return (setfield!(terminal, :presentation, streamstate(convert(Bool, value))); value)
    name === :lineopen && return (setfield!(terminal, :line, linestate(convert(Bool, value))); value)
    setfield!(terminal, name, convert(fieldtype(typeof(terminal), name), value))
end
Base.propertynames(::Terminal, private::Bool=false) = (:output, :diagnostics, :secrets, :streamed, :lineopen, :presentation, :line, :mode)

# A following hexadecimal or octal digit can change the last escape.
forms(secret) = (chop(repr(secret * "0"); head=1, tail=2), chop(repr(secret); head=1, tail=1), secret)

function redact(terminal::Terminal, text)
    result = string(text)
    for secret in terminal.secrets
        isempty(secret) && continue
        for form in forms(secret)
            result = replace(result, form => "[redacted]")
        end
    end
    result
end

function text!(terminal::Terminal, text)
    isempty(text) && return
    print(terminal.output, text)
    flush(terminal.output)
    terminal.presentation = Streamed()
    terminal.line = linestate(!endswith(text, '\n'))
end

function line!(terminal::Terminal)
    line!(terminal, terminal.line)
    flush(terminal.output)
    terminal.line = LineClosed()
end
line!(terminal::Terminal, ::LineOpen) = println(terminal.output)
line!(terminal::Terminal, ::LineClosed) = nothing

status(::Terminal, ::ToolSuccess) = "ok"
status(terminal::Terminal, result::ToolFailure) = "error: " * redact(terminal, result.text)

abstract type TerminalEvent end
struct AssistantEnded <: TerminalEvent
    content::Any
end
struct ToolStarted <: TerminalEvent
    name::Any
end
struct ToolUpdated <: TerminalEvent
    name::Any
    result::ShellUpdate
end
struct ToolEnded <: TerminalEvent
    name::Any
    result::Any
end

const terminaleventtypes = Dict(:message_end => AssistantEnded, :tool_execution_start => ToolStarted, :tool_execution_end => ToolEnded, :tool_execution_update => ToolUpdated)
const terminalroles = Dict("assistant" => AssistantEnded)
terminalevent(event) = terminalevent(get(terminaleventtypes, event.type, nothing), event)
terminalevent(::Nothing, event) = nothing
terminalevent(::Type{AssistantEnded}, event) = terminalassistant(get(terminalroles, get(event.message, "role", nothing), nothing), event.message)
terminalevent(::Type{ToolStarted}, event) = ToolStarted(event.tool_name)
terminalevent(::Type{ToolUpdated}, event) = ToolUpdated(event.tool_name, event.partial_result)
terminalevent(::Type{ToolEnded}, event) = ToolEnded(event.tool_name, event.result)
terminalassistant(::Nothing, message) = nothing
terminalassistant(::Type{AssistantEnded}, message) = AssistantEnded(get(message, "content", nothing))

render!(terminal::Terminal, event) = render!(terminal, terminalevent(event))
render!(terminal::Terminal, ::Nothing) = nothing

function render!(terminal::Terminal, event::AssistantEnded)
    showcontent!(terminal, event.content)
    line!(terminal)
    terminal.presentation = Unstreamed()
end

showcontent!(terminal::Terminal, content) = nothing
showcontent!(terminal::Terminal, content::AbstractString) = showcontent!(terminal, content, terminal.presentation)
showcontent!(terminal::Terminal, content::AbstractString, ::Unstreamed) = text!(terminal, content)
showcontent!(terminal::Terminal, content::AbstractString, ::Streamed) = nothing

function render!(terminal::Terminal, event::ToolStarted)
    println(terminal.diagnostics, "[tool] ", redact(terminal, something(event.name, "unknown")), ": started")
    flush(terminal.diagnostics)
end

function render!(terminal::Terminal, event::ToolUpdated)
    println(terminal.diagnostics, "[tool] ", redact(terminal, event.name), ": output ", ncodeunits(event.result.text), " bytes available")
    flush(terminal.diagnostics)
end

function render!(terminal::Terminal, event::ToolEnded)
    name = redact(terminal, something(event.name, "unknown"))
    result = status(terminal, event.result)
    println(terminal.diagnostics, "[tool] ", name, ": ", result)
    flush(terminal.diagnostics)
end

const finishdetails = Dict("content_filter" => "content was filtered", "failed" => "the provider reported failure", "incomplete" => "the provider reported incomplete output")
result!(terminal::Terminal, result::Completion) = result!(terminal, result, result.error)
result!(terminal::Terminal, result::Completion, error::InvalidResponse) = failure!(terminal, error)
result!(terminal::Terminal, result::Completion, error::ProviderStatus) = failure!(terminal, error)

function result!(terminal::Terminal, ::Completion, ::UnsupportedImage)
    println(terminal.diagnostics, "The selected provider does not support image attachments in tool results.")
    flush(terminal.diagnostics)
    1
end

function result!(terminal::Terminal, ::Truncated)
    println(terminal.diagnostics, "Response was truncated: the model reached its output token limit.")
    flush(terminal.diagnostics)
    1
end

function result!(terminal::Terminal, result::Completion, error)
    detail = get(finishdetails, result.finish, "the provider stream did not finish")
    println(terminal.diagnostics, "Response incomplete: ", detail)
    flush(terminal.diagnostics)
    1
end

const resultstatuses = Dict(:cancelled => 130)
function result!(terminal::Terminal, result::Symbol)
    println(terminal.diagnostics, "Request ", result, ".")
    flush(terminal.diagnostics)
    get(resultstatuses, result, 1)
end

result!(::Terminal, ::Union{AbstractString, Nothing}) = 0

struct PendingInputs end

queueplace(::Union{Nothing, History.Memory}) = "These messages exist only in memory; exiting discards them."
queueplace(history::History.Tree) = queueplace(history.store)
queueplace(history::SessionCatalog.Deferred) = queueplace(history.store)
queueplace(::History.Store) = "These messages remain saved in this session."

function checkqueues!(terminal::Terminal, state::Conversation.State, history)
    isempty(state.steering) && isempty(state.followups) && return nothing
    println(terminal.diagnostics, "History has unprocessed queued messages. No new prompt was sent.")
    for text in state.steering
        println(terminal.diagnostics, "Unprocessed steering: ", repr(redact(terminal, Conversation.queuetext(text))))
    end
    for text in state.followups
        println(terminal.diagnostics, "Unprocessed follow-up: ", repr(redact(terminal, Conversation.queuetext(text))))
    end
    queuewarning!(terminal, Conversation.queuecontent(state))
    println(terminal.diagnostics, queueplace(history))
    flush(terminal.diagnostics)
    PendingInputs()
end
queuewarning!(terminal, ::Conversation.TextOnly) = nothing
queuewarning!(terminal, ::Conversation.ContainsImages) = result!(terminal, History.Rejected(:queued_images))

const historydiagnostics = Dict(
    :uncertain_effect => "History has an uncertain pending effect. It was not retried. Use --inspect-history and inspect external state, then use --abandon with a reason before continuing.",
    :incomplete_turn => "History has an incomplete turn. Use --inspect-history and inspect external state, then use --abandon with a reason before continuing.",
    :not_interrupted => "History has no interrupted turn to abandon.",
    :pending_inputs => "History has unprocessed queued messages. Review them before forking this session.",
    :queued_images => "Queued images cannot be restored to the text editor; the queue remains unchanged.",
    :image_edit => "Image messages cannot be edited in the text editor; the session remains unchanged.",
)

function result!(terminal::Terminal, result::History.Rejected)
    println(terminal.diagnostics, get(historydiagnostics, result.reason, "History rejected: $(result.reason)."))
    flush(terminal.diagnostics)
    1
end

function historyagent(f, terminal::Terminal, path::AbstractString)
    path = expanduser(path)
    if !isfile(path)
        println(terminal.diagnostics, "Recovery requires an existing history file.")
        return 2
    end
    historyagent(f, terminal, SessionCatalog.adapt(open(History.SQLite, path; create=false)))
end
historyagent(f, terminal::Terminal, rejected::History.Rejected) = result!(terminal, rejected)

function historyagent(f, terminal::Terminal, history::History.Store)
    try
        historysnapshot(f, terminal, history, History.snapshot(history))
    finally
        close(history)
    end
end

historysnapshot(f, terminal, history, rejected::History.Rejected) = result!(terminal, rejected)
function historysnapshot(f, terminal, history, snapshot::History.Snapshot)
    snapshot.revision == 0 && return result!(terminal, History.Rejected(:not_interrupted))
    historyopened(f, terminal, Agent(nothing, []; history))
end
historyopened(f, terminal, rejected::History.Rejected) = result!(terminal, rejected)
historyopened(f, terminal, agent::Agent) = f(agent)

function abandonhistory!(terminal::Terminal, path, reason)
    historyagent(terminal, path) do agent
        abandoned!(terminal, abandon!(agent, reason))
    end
end
abandoned!(terminal::Terminal, rejected::History.Rejected) = result!(terminal, rejected)
function abandoned!(terminal::Terminal, result)
    println(terminal.output, "Interrupted turn abandoned. No effect was retried or undone.")
    flush(terminal.output)
    0
end

function inspect!(terminal::Terminal, effect::Union{Conversation.ToolRequest, Conversation.SkipRequest})
    println(terminal.output, "Pending tool: ", repr(effect.call.name))
    println(terminal.output, "Arguments: ", repr(effect.call.arguments))
end

inspect!(terminal::Terminal, ::Conversation.ModelRequest) = println(terminal.output, "Pending model request")

historystatus(::Nothing) = "ready"
historystatus(fault::History.Rejected) = string(fault.reason)

function inspecthistory!(terminal::Terminal, path)
    historyagent(terminal, path) do agent
        println(terminal.output, "History status: ", historystatus(agent.fault))
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

function failure!(terminal::Terminal, exception::Union{SystemError, Base.IOError})
    println(terminal.diagnostics, "Request failed: ", redact(terminal, sprint(showerror, exception)))
    flush(terminal.diagnostics)
    1
end

function failure!(terminal::Terminal, ::InvalidResponse)
    println(terminal.diagnostics, "Request failed (invalid provider response).")
    flush(terminal.diagnostics)
    1
end

function failure!(terminal::Terminal, failure::ProviderStatus)
    println(terminal.diagnostics, "Request failed (HTTP ", failure.status, ").")
    flush(terminal.diagnostics)
    1
end

function request!(terminal::Terminal, task, exception::Union{HTTP.HTTPError, InterruptException, SystemError, Base.IOError})
    line!(terminal)
    terminal.presentation = Unstreamed()
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

const streamtypes = Dict(:text => TextDelta)
streamevent(event) = streamevent(get(streamtypes, event.type, nothing), event)
streamevent(::Nothing, event) = nothing
streamevent(::Type{TextDelta}, event) = TextDelta(event.text)
streamrender!(terminal::Terminal, event) = streamrender!(terminal, streamevent(event))
streamrender!(terminal::Terminal, ::Nothing) = nothing
streamrender!(terminal::Terminal, event::TextDelta) = text!(terminal, event.text)

function failures!(terminal::Terminal, listener::Extensions.Listener)
    for failure in Extensions.failures(listener)
        println(terminal.diagnostics, "[plugin] ", redact(terminal, failure.plugin), " ", failure.event, ": ", redact(terminal, sprint(showerror, failure.exception)))
    end
    flush(terminal.diagnostics)
end

failures!(::Terminal, ::Function) = nothing
observer(terminal::Terminal, ::Nothing, callback) = event -> (render!(terminal, event); callback(event))
observer(terminal::Terminal, snapshot::Extensions.Snapshot, callback) = Extensions.listen(snapshot; on_event=observer(terminal, nothing, callback))

run!(terminal::Terminal, agent::Agent, prompt, snapshot=nothing; on_agent_event=identity) = run!(terminal, agent, prompt, snapshot, checkqueues!(terminal, agent.state, agent.history), on_agent_event)
run!(terminal::Terminal, agent::Agent, prompt, snapshot, ::PendingInputs, on_agent_event) = 1

function run!(terminal::Terminal, agent::Agent, prompt, snapshot, ::Nothing, on_agent_event)
    runmode!(terminal, agent, prompt, snapshot, on_agent_event, terminal.mode)
end

function runmode!(terminal::Terminal, agent::Agent, prompt, snapshot, on_agent_event, ::TextMode)
    callback = observer(terminal, snapshot, on_agent_event)
    result = try
        request!(terminal) do
            respond!(agent, prompt; on_event=event -> streamrender!(terminal, event), on_agent_event=callback)
        end
    finally
        failures!(terminal, callback)
    end
    result.status == 0 || return result.status
    result!(terminal, result.value)
end
