module Headless

using JSON3
import ..JuliaForever as J
const LiveJSON = J.LiveJSON

abstract type Command end
struct GetState <: Command end
struct GetMessages <: Command end
struct GetAvailableModels <: Command end
struct GetCommands <: Command end
struct GetSessionStats <: Command end
struct ClearQueue <: Command end
struct CloneSession <: Command end
struct GetForkMessages <: Command end
struct GetLastText <: Command end
struct Abort <: Command end
struct GetThinkingLevels <: Command end
struct CycleThinking <: Command end
struct AbortRetry <: Command end
struct AbortBash <: Command end
struct SetThinking <: Command
    level::String
end
struct SetSteeringMode <: Command
    mode::String
end
struct SetFollowUpMode <: Command
    mode::String
end
struct SetAutoCompaction <: Command
    enabled::Bool
end
struct SetAutoRetry <: Command
    enabled::Bool
end
struct NewSession <: Command
    parent::Union{Nothing, String}
end
struct SwitchSession <: Command
    path::String
end
struct ExportHTML <: Command
    path::Union{Nothing, String}
end
struct ForkSession <: Command
    id::String
end
struct SetName <: Command
    name::String
end
abstract type QueueMode end
struct NoQueue <: QueueMode end
struct Steering <: QueueMode end
struct FollowUp <: QueueMode end
struct Prompt{M<:QueueMode} <: Command
    message::String
    mode::M
    images::Vector{J.Image}
end
struct Queue{M<:QueueMode} <: Command
    message::String
    mode::M
    images::Vector{J.Image}
end
struct Unknown <: Command end
struct Unsupported <: Command end
struct FailedRun end
struct SessionStarted end
abstract type TurnResult end
struct CompletedTurn <: TurnResult end
struct FailedTurn <: TurnResult end
struct InterruptedTurn <: TurnResult end
abstract type OutputState end
struct OpenOutput <: OutputState end
struct ClosedOutput <: OutputState end
abstract type StatisticsState end
struct AvailableStatistics <: StatisticsState end
struct UnavailableStatistics <: StatisticsState end
const newstatuses = Dict(0 => SessionStarted())

const unsupportedcommands = (
    "set_model", "cycle_model", "compact", "bash",
    "get_entries", "get_tree",
)
const commands = merge(
    Dict(name => Unsupported for name in unsupportedcommands),
    Dict(
        "prompt" => Prompt, "steer" => Queue{Steering}, "follow_up" => Queue{FollowUp}, "abort" => Abort,
        "clear_queue" => ClearQueue, "clone" => CloneSession, "fork" => ForkSession, "get_fork_messages" => GetForkMessages, "new_session" => NewSession, "switch_session" => SwitchSession, "export_html" => ExportHTML, "get_state" => GetState, "get_session_stats" => GetSessionStats,
        "get_messages" => GetMessages, "get_available_models" => GetAvailableModels, "get_commands" => GetCommands, "get_last_assistant_text" => GetLastText, "set_session_name" => SetName,
        "get_available_thinking_levels" => GetThinkingLevels, "cycle_thinking_level" => CycleThinking, "set_thinking_level" => SetThinking,
        "set_steering_mode" => SetSteeringMode, "set_follow_up_mode" => SetFollowUpMode,
        "set_auto_compaction" => SetAutoCompaction, "set_auto_retry" => SetAutoRetry, "abort_retry" => AbortRetry, "abort_bash" => AbortBash,
    ),
)
const queuemodes = Dict("steer" => Steering(), "followUp" => FollowUp())

struct Request{C<:Command}
    id::Union{Nothing, String}
    name::String
    command::C
end

struct InvalidInput end

function request(line)
    depth = length(current_exceptions())
    try
        return request(J.decode(line))
    finally
        for failure in inputfailures(current_exceptions(), depth)
            return failure
        end
    end
end
inputfailures(exceptions, depth) = length(exceptions) > depth ? inputfailures(last(exceptions).exception) : ()
inputfailures(::Union{ArgumentError, KeyError, MethodError, TypeError}) = (InvalidInput(),)
inputfailures(exception) = ()
request(::J.InvalidResponse) = InvalidInput()
function request(data::AbstractDict)
    name = String(get(data, "type", ""))
    Request(get(data, "id", nothing), name, command(get(commands, name, Unknown), data))
end

command(type::Type{<:Command}, data) = type()
command(::Type{SetName}, data) = SetName(String(data["name"]))
command(::Type{NewSession}, data) = NewSession(get(data, "parentSession", nothing))
command(::Type{SwitchSession}, data) = SwitchSession(String(data["sessionPath"]))
command(::Type{ExportHTML}, data) = ExportHTML(get(data, "outputPath", nothing))
command(::Type{ForkSession}, data) = ForkSession(String(data["entryId"]))
command(::Type{SetThinking}, data) = SetThinking(String(data["level"]))
command(::Type{SetSteeringMode}, data) = SetSteeringMode(String(data["mode"]))
command(::Type{SetFollowUpMode}, data) = SetFollowUpMode(String(data["mode"]))
command(::Type{SetAutoCompaction}, data) = SetAutoCompaction(data["enabled"])
command(::Type{SetAutoRetry}, data) = SetAutoRetry(data["enabled"])
images(data) = [J.Image(String(image["mimeType"]), String(image["data"])) for image in get(data, "images", [])]
command(::Type{Prompt}, data) = Prompt(String(data["message"]), get(queuemodes, get(data, "streamingBehavior", ""), NoQueue()), images(data))
command(::Type{Queue{M}}, data) where {M<:QueueMode} = Queue(String(data["message"]), M(), images(data))

abstract type Reply end
struct Success{T} <: Reply
    fields::T
end
struct Failure <: Reply
    message::String
end
Success() = Success(NamedTuple())

mutable struct Session{A, T, E, S, P, L}
    agent::A
    terminal::T
    extensions::E
    store::S
    templates::P
    directory::String
    lock::ReentrantLock
    messages::Vector{Dict{String, Any}}
    id::String
    name::Union{Nothing, String}
    stream::L
    lastcontent::Union{Nothing, String}
    steering::Vector{String}
    followups::Vector{String}
    task::Union{Nothing, Task}
    started::Base.Event
    outputstate::Union{OpenOutput, ClosedOutput}
    statistics::Union{AvailableStatistics, UnavailableStatistics}
end

function Session(terminal, agent, extensions, store, templates, directory)
    stream = LiveJSON.Stream(terminal, agent, terminal.mode)
    session = Session(agent, terminal, extensions, store, templates, directory, ReentrantLock(), Dict{String, Any}[], LiveJSON.id(store[]), sessionname(J.SessionCatalog.sessionname(store[])), stream, nothing, String[], String[], nothing, Base.Event(), OpenOutput(), AvailableStatistics())
    restore!(session, agent)
end
sessionname(::Nothing) = nothing
sessionname(value::String) = value
sessionname(value::J.History.Rejected) = nothing

include("headless_events.jl")
include("headless_statistics.jl")
include("headless_history.jl")
include("headless_commands.jl")

function write!(session, value)
    lock(session.lock) do
        write!(session, session.outputstate, value)
    end
    nothing
end
write!(session, ::ClosedOutput, value) = nothing
function write!(session, ::OpenOutput, value)
    JSON3.write(session.terminal.output, value)
    println(session.terminal.output)
    flush(session.terminal.output)
    nothing
end

withid!(response, ::Nothing) = response
withid!(response, id::String) = (response["id"] = id; response)

function reply!(session, request, success, fields=NamedTuple())
    response = Dict{String, Any}("type" => "response", "command" => request.name, "success" => success)
    for (key, value) in pairs(fields)
        response[String(key)] = value
    end
    write!(session, withid!(response, request.id))
end

function state(session)
    agent = session.agent
    active, count, name = lock(session.lock) do
        (streaming(session.task), length(session.messages), session.name)
    end
    pending = lock(agent.lock) do
        length(agent.state.steering) + length(agent.state.followups)
    end
    data = Dict{String, Any}("model" => modelinfo(session), "thinkingLevel" => "off", "isStreaming" => active, "isCompacting" => false, "steeringMode" => "one-at-a-time", "followUpMode" => "one-at-a-time", "sessionId" => session.id, "autoCompactionEnabled" => false, "messageCount" => count, "pendingMessageCount" => pending)
    optional!(data, "sessionName", name)
    optional!(data, "sessionFile", sessionfile(session.store[]))
end
modelinfo(session) = modelinfo(session.agent.provider, session.terminal.mode)
modelinfo(provider, mode) = (; id=provider.model, api=LiveJSON.api(provider), provider=LiveJSON.providername(mode, provider), baseUrl=provider.base)
modelinfo(::J.UnconfiguredProvider, mode) = (; id="unknown", name="unknown", api="unknown", provider="unknown", baseUrl="", reasoning=false, input=String[], cost=(; input=0, output=0, cacheRead=0, cacheWrite=0), contextWindow=0, maxTokens=0)
sessionfile(::Nothing) = nothing
sessionfile(::J.History.Memory) = nothing
sessionfile(history::J.History.Tree) = sessionfile(history.store)
sessionfile(history::J.History.SQLite) = J.SessionCatalog.path(history)
sessionfile(history::J.SessionCatalog.Deferred) = lock(() -> sessionfile(history.store, history.path), history.lock)
sessionfile(::J.History.Memory, path) = nothing
sessionfile(::J.History.SQLite, path) = path
streaming(::Nothing) = false
streaming(::Task) = true
optional!(data, key, ::Nothing) = data
optional!(data, key, value) = (data[key] = value; data)

handle!(session, ::GetState) = Success((; data=state(session)))
handle!(session, ::GetMessages) = Success((; data=(; messages=lock(() -> copy(session.messages), session.lock))))
handle!(session, ::GetAvailableModels) = availablemodels(session.agent.provider)
availablemodels(::J.UnconfiguredProvider) = availablemodels(J.usableproviders(ENV))
availablemodels(providers::Set{String}) = isempty(providers) ? Success((; data=(; models=NamedTuple[],))) : Failure("Model listing is not yet available over RPC")
availablemodels(provider) = Failure("Model listing is not yet available over RPC")
handle!(session, ::GetSessionStats) = lock(() -> statistics(session, session.statistics), session.lock)
handle!(session, ::GetThinkingLevels) = Success((; data=(; levels=["off"])))
handle!(session, ::CycleThinking) = Success((; data=nothing))
handle!(session, ::Union{AbortRetry, AbortBash}) = Success()
handle!(session, command::SetThinking) = get(thinkingoptions, command.level, Failure("Thinking levels are not available"))
handle!(session, command::Union{SetSteeringMode, SetFollowUpMode}) = get(queueoptions, command.mode, Failure("Only one-at-a-time queue mode is available"))
handle!(session, command::SetAutoCompaction) = get(compactionoptions, command.enabled, Failure("Automatic compaction is not available in headless mode"))
handle!(session, command::SetAutoRetry) = get(retryoptions, command.enabled, Failure("Automatic retry is not available"))
const thinkingoptions = Dict("off" => Success())
const queueoptions = Dict("one-at-a-time" => Success())
const compactionoptions = Dict(false => Success())
const retryoptions = Dict(false => Success())
handle!(session, ::ClearQueue) = cleared(session, J.dequeue!(session.agent))
function cleared(session, queue::NamedTuple)
    queues!(session)
    Success((; data=(; steering=queue.steering, followUp=queue.followups)))
end
cleared(session, rejected::J.History.Rejected) = Failure(string(rejected.reason))
handle!(session, ::GetLastText) = Success((; data=lasttext(session.lastcontent)))
lasttext(::Nothing) = NamedTuple()
lasttext(text::String) = (; text)
blocktext(block::LiveJSON.TextBlock) = LiveJSON.buffertext(block.text)
blocktext(block::LiveJSON.Block) = ""
handle!(session, command::SetName) = setname!(session, strip(command.name))
function setname!(session, name)
    isempty(name) && return Failure("Session name cannot be empty")
    named!(session, name, J.name!(session.agent, name))
end
function named!(session, name, ::Nothing)
    session.name = name
    write!(session, (; type="session_info_changed", name))
    Success()
end
named!(session, name, failure::J.History.Rejected) = Failure(string(failure.reason))

handle!(session, command::NewSession) = newsession!(session, command.parent)
newsession!(session, parent::String) = Failure("Parent session tracking is not supported")
function newsession!(session, ::Nothing)
    handle!(session, Abort())
    agent, history, status = J.new!(session.terminal, session.agent, session.store[], session.directory, session.extensions, session.templates)
    newresult!(session, agent, history, get(newstatuses, status, nothing))
end
newresult!(session, agent, history, ::Nothing) = Failure("Could not start a new session")
function newresult!(session, agent, history, ::SessionStarted)
    rebind!(session, agent, history)
    Success((; data=(; cancelled=false)))
end

function rebind!(session, agent, history)
    lock(session.lock) do
        session.agent = agent
        session.store[] = history
        session.id = J.LiveJSON.id(history)
        session.name = sessionname(J.SessionCatalog.sessionname(history))
        session.stream = LiveJSON.Stream(session.terminal, agent, session.terminal.mode)
        session.lastcontent = nothing
        session.statistics = AvailableStatistics()
        empty!(session.messages)
        empty!(session.steering)
        empty!(session.followups)
        restore!(session, agent)
        write!(session, (; type="queue_update", steering=String[], followUp=String[]))
    end
    nothing
end

function handle!(session, command::SwitchSession)
    request = J.SessionCatalog.Target(command.path)
    selected = J.attempt(() -> J.SessionCatalog.choose(request, session.directory, pwd(), stdin, session.terminal.diagnostics, text -> J.redact(session.terminal, text)))
    switch!(session, selected)
end
switch!(session, invalid::J.SessionCatalog.Invalid) = Failure(invalid.message)
switch!(session, failure::J.ToolFailure) = Failure(J.redact(session.terminal, failure.text))
switch!(session, rejected::J.History.Rejected) = Failure(string(rejected.reason))
function switch!(session, selected::J.History.Tree)
    agent, history, status = J.resume!(session.terminal, session.agent, session.store[], selected)
    newresult!(session, agent, history, get(newstatuses, status, nothing))
end

handle!(session, ::CloneSession) = clonechecked!(session, J.sourcecheck!(session.terminal, session.agent, session.store[]))
clonechecked!(session, blocked::J.PendingInputs) = Failure("Session has pending inputs")
clonechecked!(session, rejected::J.History.Rejected) = Failure(string(rejected.reason))
clonechecked!(session, ::Nothing) = clone!(session, J.attempt(() -> J.sessiontree(session.store[])))
clone!(session, failure::J.ToolFailure) = Failure(J.redact(session.terminal, failure.text))
clone!(session, rejected::J.History.Rejected) = Failure(string(rejected.reason))
function clone!(session, tree::J.History.Tree)
    agent, history, status = J.clone!(session.terminal, session.agent, session.store[], session.directory, tree, nothing)
    newresult!(session, agent, history, get(newstatuses, status, nothing))
end

handle!(session, command::ExportHTML) = export!(session, session.store[], command.path)
export!(session, ::Union{Nothing, J.History.Memory}, path) = Failure("Cannot export in-memory session to HTML")
export!(session, history::J.History.Tree, path) = export!(session, history.store, path)
export!(session, history::J.History.SQLite, path) = export!(session, J.SessionCatalog.path(history), path)
function export!(session, history::J.SessionCatalog.Deferred, path)
    store, source = lock(() -> (history.store, history.path), history.lock)
    export!(session, store, source, path)
end
export!(session, ::J.History.Memory, source, path) = Failure("Nothing to export yet - start a conversation first")
export!(session, ::J.History.SQLite, source, path) = export!(session, source, path)
function export!(session, source::String, path)
    target = exportpath(path, source)
    J.mutationkey(target) == J.mutationkey(source) && return Failure("Cannot overwrite the active session file")
    messages = lock(() -> deepcopy(session.messages), session.lock)
    html = J.Logs.html(messages; project=identity, title="Julia Forever session")
    exported(target, J.attempt(() -> write(target, html)))
end
exportpath(::Nothing, source) = "pi-session-" * splitext(basename(source))[1] * ".html"
exportpath(path::String, source) = expanduser(path)
exported(path, count::Integer) = Success((; data=(; path)))
exported(path, failure::J.ToolFailure) = Failure(failure.text)

function queue!(session, message, ::Steering)
    queued!(session, J.steer!(session.agent, message))
end
function queue!(session, message, ::FollowUp)
    queued!(session, J.followup!(session.agent, message))
end
function queued!(session, ::Nothing)
    queues!(session)
    Success((; data=(; disposition="queued")))
end
queued!(session, failure::J.History.Rejected) = Failure(string(failure.reason))
handle!(session, command::Queue) = queue!(session, command.message, command.mode, command.images)
function queue!(session, message, mode, images)
    isempty(images) || return Failure("Queued images are not supported")
    queue!(session, J.Prompts.expand(message, session.templates), mode)
end
function queues!(session)
    queues = lock(session.agent.lock) do
        (; steering=copy(session.agent.state.steering), followUp=copy(session.agent.state.followups))
    end
    lock(session.lock) do
        queues.steering == session.steering && queues.followUp == session.followups && return nothing
        session.steering = queues.steering
        session.followups = queues.followUp
        write!(session, (; type="queue_update", queues.steering, queues.followUp))
    end
end

function handle!(session, command::Prompt)
    promptprovider!(session, command, session.agent.provider)
end
promptprovider!(session, command, ::J.UnconfiguredProvider) = Failure("No configured model or API key is available.")
function promptprovider!(session, command, provider)
    lock(session.lock) do
        prompt!(session, command, session.task)
    end
end
prompt!(session, command::Prompt, ::Nothing) = prompt!(session, command, nothing, J.fault(session.agent))
prompt!(session, command::Prompt, ::Nothing, fault::J.History.Rejected) = Failure(string(fault.reason))
function prompt!(session, command::Prompt, ::Nothing, ::Nothing)
    prompt = J.fileprompt(J.Prompts.expand(command.message, session.templates), command.images)
    session.started = Base.Event()
    started = session.started
    session.task = Threads.@spawn begin
        result = FailedRun()
        try
            result = turn!(session, prompt)
        finally
            notify(started)
            lock(session.lock) do
                session.task = nothing
                settled!(session, result)
            end
        end
    end
    Success((; data=(; disposition="started")))
end
prompt!(session, command::Prompt{NoQueue}, task::Task) = Failure("Agent is already processing. Specify streamingBehavior ('steer' or 'followUp') to queue the message.")
prompt!(session, command::Prompt, task::Task) = queue!(session, command.message, command.mode, command.images)

function handle!(session, ::Abort)
    task, started = lock(() -> (session.task, session.started), session.lock)
    waitstarted(task, started)
    J.cancel!(session.agent)
    waittask(task)
    Success()
end
waitstarted(::Nothing, started) = nothing
waitstarted(task::Task, started) = wait(started)
waittask(::Nothing) = nothing
waittask(task::Task) = wait(task)
respond!(session, request::Request{Unknown}) = reply!(session, request, false, (; error="Unknown command: " * request.name))
respond!(session, request::Request{Unsupported}) = reply!(session, request, false, (; error="Unsupported command: " * request.name))
respond!(session, request::Request) = respond!(session, request, handle!(session, request.command))
respond!(session, request, reply::Success) = reply!(session, request, true, reply.fields)
respond!(session, request, reply::Failure) = reply!(session, request, false, (; error=reply.message))
respond!(session, ::InvalidInput) = write!(session, (; type="response", command="parse", success=false, error="Failed to parse command"))

function rpc!(terminal, agent, extensions, store, args, sessiondir, templates)
    parsed = J.FileArguments.parse(args)
    isempty(parsed.files) || return rpcfiles!(terminal)
    session = Session(terminal, agent, extensions, store, templates, sessiondir)
    write!(session, (; type="queue_update", steering=String[], followUp=String[]))
    for line in eachline(stdin)
        respond!(session, request(line))
    end
    handle!(session, Abort())
    lock(() -> (session.outputstate = ClosedOutput()), session.lock)
    0
end

function rpcfiles!(terminal)
    println(terminal.diagnostics, "Error: @file arguments are not supported in RPC mode")
    1
end

function turn!(session, prompt)
    callback = J.Extensions.listen(session.extensions; on_event=event -> event!(session, event))
    response = try
        J.request!(session.terminal) do
            J.respond!(session.agent, prompt; on_event=ProviderObserver(session), on_agent_event=callback)
        end
    finally
        J.failures!(session.terminal, callback)
    end
    result = turnresult!(session, get(turnresults, response.status, FailedTurn()), response.value)
    lock(() -> LiveJSON.finishrun!(session.stream, session.stream.runended), session.lock)
    result
end

const turnresults = Dict(0 => CompletedTurn(), 130 => InterruptedTurn())
turnresult!(session, ::CompletedTurn, value) = value
turnresult!(session, ::FailedTurn, value) = (failedturn!(session, nothing); FailedRun())
turnresult!(session, ::InterruptedTurn, value) = (failedturn!(session, "cancelled"); :cancelled)

const abortresults = Dict(:cancelled => true)
aborted(result) = false
aborted(result::Symbol) = get(abortresults, result, false)
settled!(session, result) = write!(session, (; type="agent_settled", aborted=aborted(result)))

end
