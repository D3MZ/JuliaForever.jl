module Headless

using JSON3, Dates
import ..JuliaForever as J

abstract type Command end
struct GetState <: Command end
struct GetMessages <: Command end
struct GetSessionStats <: Command end
struct ClearQueue <: Command end
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
    "set_model", "cycle_model", "get_available_models", "compact", "bash", "export_html",
    "switch_session", "fork", "clone", "get_fork_messages", "get_entries", "get_tree", "get_commands",
)
const commands = merge(
    Dict(name => Unsupported for name in unsupportedcommands),
    Dict(
        "prompt" => Prompt, "steer" => Queue{Steering}, "follow_up" => Queue{FollowUp}, "abort" => Abort,
        "clear_queue" => ClearQueue, "new_session" => NewSession, "get_state" => GetState, "get_session_stats" => GetSessionStats,
        "get_messages" => GetMessages, "get_last_assistant_text" => GetLastText, "set_session_name" => SetName,
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

abstract type Block end
mutable struct TextBlock <: Block
    text::IOBuffer
end
mutable struct ThinkingBlock <: Block
    text::IOBuffer
end
mutable struct CallBlock <: Block
    id::String
    name::String
    arguments::IOBuffer
end
TextBlock() = TextBlock(IOBuffer())
ThinkingBlock() = ThinkingBlock(IOBuffer())
CallBlock() = CallBlock("", "", IOBuffer())
function CallBlock(id, name, args::String)
    buffer = IOBuffer()
    write(buffer, args)
    CallBlock(id, name, buffer)
end

mutable struct Stream
    blocks::Vector{Union{TextBlock, ThinkingBlock, CallBlock}}
    indexes::Dict{Tuple{Symbol, String}, Int}
    ids::Dict{String, Int}
    usage::Union{Nothing, J.Usage}
    completion::Union{Nothing, J.Completion}
    timestamp::Int
    announced::J.MessagePresentation
    ended::J.MessagePresentation
end
Stream() = Stream(Union{TextBlock, ThinkingBlock, CallBlock}[], Dict{Tuple{Symbol, String}, Int}(), Dict{String, Int}(), nothing, nothing, round(Int, time() * 1000), J.Unannounced(), J.Unannounced())

function request(line)
    try
        data = JSON3.read(codeunits(line), Dict{String, Any})
        name = String(get(data, "type", ""))
        Request(get(data, "id", nothing), name, command(get(commands, name, Unknown), data))
    catch
        InvalidInput()
    end
end

command(type::Type{<:Command}, data) = type()
command(::Type{SetName}, data) = SetName(String(data["name"]))
command(::Type{NewSession}, data) = NewSession(get(data, "parentSession", nothing))
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

mutable struct Session{A, T, E, S, P}
    agent::A
    terminal::T
    extensions::E
    store::S
    templates::P
    directory::String
    lock::ReentrantLock
    messages::Vector{NamedTuple}
    id::String
    name::Union{Nothing, String}
    stream::Stream
    current::Union{Nothing, NamedTuple}
    assistant::Union{Nothing, NamedTuple}
    lastcontent::Union{Nothing, String}
    turntools::Vector{NamedTuple}
    toolnames::Dict{String, String}
    steering::Vector{String}
    followups::Vector{String}
    firstturn::J.MessagePresentation
    task::Union{Nothing, Task}
    started::Base.Event
    runstart::Int
    outputstate::OutputState
    turnended::J.MessagePresentation
    runended::J.MessagePresentation
    statistics::Union{AvailableStatistics, UnavailableStatistics}
end

function Session(terminal, agent, extensions, store, templates, directory)
    session = Session(agent, terminal, extensions, store, templates, directory, ReentrantLock(), NamedTuple[], agent.state.kernel.id, sessionname(J.SessionCatalog.sessionname(store[])), Stream(), nothing, nothing, nothing, NamedTuple[], Dict{String, String}(), String[], String[], J.Unannounced(), nothing, Base.Event(), 0, OpenOutput(), J.Unannounced(), J.Unannounced(), AvailableStatistics())
    restore!(session, agent)
end
sessionname(::Nothing) = nothing
sessionname(value::String) = value
sessionname(value::J.History.Rejected) = nothing

include("headless_events.jl")
include("headless_statistics.jl")

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
modelinfo(session) = (; id=session.agent.provider.model, api=apiname(session.agent.provider), provider=session.terminal.provider, baseUrl=session.agent.provider.base)
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
blocktext(block::TextBlock) = buffertext(block.text)
blocktext(block::Block) = ""
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
    agent, history, status = J.new!(session.terminal, session.agent, session.store[], session.directory, session.extensions)
    newresult!(session, agent, history, get(newstatuses, status, nothing))
end
newresult!(session, agent, history, ::Nothing) = Failure("Could not start a new session")
function newresult!(session, agent, history, ::SessionStarted)
    lock(session.lock) do
        session.agent = agent
        session.store[] = history
        session.id = agent.state.kernel.id
        session.name = nothing
        session.stream = Stream()
        session.current = nothing
        session.assistant = nothing
        session.lastcontent = nothing
        session.firstturn = J.Unannounced()
        session.statistics = AvailableStatistics()
        empty!(session.messages)
        empty!(session.turntools)
        empty!(session.toolnames)
        empty!(session.steering)
        empty!(session.followups)
        write!(session, (; type="queue_update", steering=String[], followUp=String[]))
    end
    Success((; data=(; cancelled=false)))
end

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
    lock(() -> (session.outputstate = ClosedOutput()), session.lock)
    handle!(session, Abort())
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
            J.respond!(session.agent, prompt; on_event=event -> provider!(session, event), on_agent_event=callback)
        end
    finally
        J.failures!(session.terminal, callback)
    end
    result = turnresult!(session, get(turnresults, response.status, FailedTurn()), response.value)
    finishrun!(session, session.runended)
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

function json!(terminal, agent, extensions, store, args, sessiondir, templates)
    session = Session(terminal, agent, extensions, store, templates, sessiondir)
    stamp = Dates.format(Dates.now(Dates.UTC), dateformat"yyyy-mm-ddTHH:MM:SS.sss") * "Z"
    write!(session, (; type="session", version=3, id=session.id, timestamp=stamp, cwd=pwd()))
    parsed = J.FileArguments.parse(args)
    jsonfiles!(session, parsed.messages, parsed.files, templates)
end

jsonfiles!(session, messages, files, templates) = jsonfiles!(session, messages, templates, J.attempt(() -> J.FileArguments.load(files, pwd())))
function jsonfiles!(session, messages, templates, failure::J.ToolFailure)
    println(session.terminal.diagnostics, "Could not read file argument: ", J.redact(session.terminal, failure.text))
    1
end
function jsonfiles!(session, messages, templates, files::NamedTuple)
    text = J.fileinput(stdin) * files.text * get(messages, 1, "")
    jsonprompt!(session, J.Prompts.expand(text, templates), files.images)
    for message in Iterators.drop(messages, 1)
        jsonprompt!(session, J.Prompts.expand(message, templates), J.Image[])
    end
    0
end
function jsonprompt!(session, text, images)
    isempty(text) && isempty(images) && return nothing
    result = turn!(session, J.fileprompt(text, images))
    settled!(session, result)
end

end
