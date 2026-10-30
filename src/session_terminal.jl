abstract type TerminalCommand end
struct TreeCommand <: TerminalCommand end
struct ResumeCommand <: TerminalCommand end
struct CompactCommand <: TerminalCommand end
struct ReloadCommand <: TerminalCommand end
struct NewCommand <: TerminalCommand end
struct CloneCommand <: TerminalCommand end
struct ForkCommand <: TerminalCommand end
struct ExitCommand <: TerminalCommand end
struct SessionCommand <: TerminalCommand end
struct ExportCommand{P} <: TerminalCommand
    path::P
end
ExportCommand() = ExportCommand(nothing)
struct ShowName <: TerminalCommand end
struct SetName <: TerminalCommand
    name::String
end
struct SelectModel <: TerminalCommand end
struct SetModel <: TerminalCommand
    model::String
end

const terminalcommands = Dict{String, TerminalCommand}("/compact" => CompactCommand(), "/reload" => ReloadCommand(), "/tree" => TreeCommand(), "/resume" => ResumeCommand(), "/new" => NewCommand(), "/clone" => CloneCommand(), "/fork" => ForkCommand(), "/exit" => ExitCommand(), "/model" => SelectModel(), "/export" => ExportCommand(), "/session" => SessionCommand())
const namepattern = r"\A/name(?: +([\s\S]*))?\z"
const modelpattern = r"\A/model +([^\r\n]+)\z"
const exportpattern = r"\A/export +([^\r\n]*)\z"
terminalcommand(text) = terminalcommand(get(terminalcommands, text, nothing), text)
terminalcommand(command::TerminalCommand, text) = command
terminalcommand(::Nothing, text) = modelcommand(exportcommand(namecommand(match(namepattern, text)), text), text)
exportcommand(command::TerminalCommand, text) = command
exportcommand(::Nothing, text) = exportcommand(match(exportpattern, text))
exportcommand(::Nothing) = nothing
exportcommand(found::RegexMatch) = exportpath(match(r"\A\s*(?:\"([^\"]*)\"|'([^']*)'|(?![\"'])(\S+))", found[1]))
exportpath(::Nothing) = ExportCommand()
exportpath(found::RegexMatch) = ExportCommand(String(something(found[1], found[2], found[3], "")))
modelcommand(command::TerminalCommand, text) = command
modelcommand(::Nothing, text) = modelcommand(match(modelpattern, text))
modelcommand(::Nothing) = nothing
modelcommand(found::RegexMatch) = SetModel(strip(found[1]))
namecommand(::Nothing) = nothing
namecommand(found::RegexMatch) = namecommand(Conversation.sessionname(something(found[1], "")))
namecommand(name::String) = isempty(name) ? ShowName() : SetName(name)

command!(::ReloadCommand, terminal, agent, history, input, directory, snapshot) = reload!(terminal, agent, history, () -> Skills.render(Skills.load(pwd()), Skills.reader(values(agent.tools))))

command!(::CompactCommand, terminal, agent, history, input, directory, snapshot) = (agent, history, compactresult!(terminal, textcompact!(terminal, agent, history)))

textcompact!(terminal, agent, ::Nothing) = compact!(agent)
textcompact!(terminal, agent, ::History.Store) = textcompactstart!(terminal, agent, startturn!(agent))
textcompactstart!(terminal, agent, ::Nothing) = :busy
function textcompactstart!(terminal, agent, ::Running)
    try
        textcompactready!(terminal, agent, sync!(agent))
    finally
        finish!(agent)
    end
end
textcompactready!(terminal, agent, rejected::History.Rejected) = rejected
function textcompactready!(terminal, agent, ::Nothing)
    stream = LiveJSON.Stream(terminal, agent, JSONMode(terminal.mode.provider), devnull)
    recorder = LiveJSON.Recorder(agent)
    LiveJSON.backfill!(recorder, stream, LiveJSON.recordpresence(recorder.entries))
    plan = lock(() -> compactionplan(agent, agent.fault), agent.lock)
    textcompactplan!(agent, recorder, plan)
end
textcompactplan!(agent, recorder, rejected::History.Rejected) = rejected
function textcompactplan!(agent, recorder, plan::CompactionPlan)
    tokens = compactiontokens(agent)
    result = compact!(agent, Summarizer(agent.provider), plan)
    info, after = lock(agent.lock) do
        (latestcompactioninfo(result, getfield(agent, :events)), sum(pretoken, agent.state.messages; init=0))
    end
    entry = LiveJSON.compactionentry((; result, plan, tokens_before=tokens, estimated_after=after, info), recorder.entries)
    outcome(LiveJSON.savecompaction!(recorder, entry), result)
end

function compactresult!(terminal, summary::AbstractString)
    println(terminal.diagnostics, "Context compacted.")
    flush(terminal.diagnostics)
    0
end

compactresult!(terminal, result) = result!(terminal, result)

struct ReloadPlan
    revision::Int
    original::Vector{Dict{String, Any}}
    messages::Vector{Conversation.Message}
end

function reload!(terminal, agent, history, load)
    reloadstart!(terminal, agent, history, load, startturn!(agent))
end

function reload!(terminal, agent, history, resources::Skills.Resources)
    loaded = Ref{Union{Nothing, Vector{Skills.Skill}}}(nothing)
    result = reload!(terminal, agent, history, () -> begin
        skills = Skills.load(pwd())
        loaded[] = skills
        Skills.render(skills, Skills.reader(values(agent.tools)))
    end)
    updateskills!(resources, loaded[], result[3])
    result
end

updateskills!(::Nothing, skills, status) = nothing
updateskills!(resources::Skills.Resources, ::Nothing, status) = nothing
updateskills!(resources::Skills.Resources, skills::Vector{Skills.Skill}, status) = get(skillupdates, status, skipupdate!)(resources, skills)
skipupdate!(resources, skills) = nothing
const skillupdates = Dict(0 => Skills.refresh!)

function reloadstart!(terminal, agent, history, load, ::Nothing)
    println(terminal.diagnostics, "Wait for the current response to finish before reloading.")
    flush(terminal.diagnostics)
    agent, history, 0
end

function reloadstart!(terminal, agent, history, load, ::Running)
    try
        plan = lock(agent.lock) do
            reloadplan(terminal, agent, history, sourcecheck!(terminal, agent, history, agent.fault))
        end
        reloadload!(terminal, agent, history, load, plan)
    finally
        finish!(agent)
    end
end

reloadplan(terminal, agent, history, blocked::Union{PendingInputs, History.Rejected}) = blocked
reloadplan(terminal, agent, history, ::Nothing) = reloadplan(agent, History.ready(agent.state))
reloadplan(agent, rejected::History.Rejected) = rejected
function reloadplan(agent, ::Nothing)
    messages = agent.state.messages
    projected = Dict{String, Any}[convert(Dict{String, Any}, message) for message in messages]
    Kernel.same(projected, agent.messages) || return History.Rejected(:revision)
    ReloadPlan(agent.state.revision, deepcopy(agent.messages), messages)
end

reloadload!(terminal, agent, history, load, blocked::Union{PendingInputs, History.Rejected}) = (agent, history, sourcestatus!(terminal, blocked))
reloadload!(terminal, agent, history, load, plan::ReloadPlan) = reloadloaded!(terminal, agent, history, plan, attempt(load))
function reloadloaded!(terminal, agent, history, plan, failure::ToolFailure)
    println(terminal.diagnostics, "Skill reload failed: ", redact(terminal, failure.text))
    flush(terminal.diagnostics)
    agent, history, 1
end
function reloadloaded!(terminal, agent, history, plan, content::Union{Nothing, AbstractString})
    lock(agent.lock) do
        reloadcommit!(terminal, agent, history, plan, content, agent.turn)
    end
end
reloadcommit!(terminal, agent, history, plan, content, ::Cancelled) = (agent, history, 1)
reloadcommit!(terminal, agent, history, plan, content, ::Running) = reloadcommit!(terminal, agent, history, plan, content, agent.fault)
reloadcommit!(terminal, agent, history, plan, content, rejected::History.Rejected) = (agent, history, result!(terminal, rejected))
function reloadcommit!(terminal, agent, history, plan, content, ::Nothing)
    agent.state.revision == plan.revision || return (agent, history, result!(terminal, History.Rejected(:revision)))
    Kernel.same(agent.messages, plan.original) || return (agent, history, result!(terminal, History.Rejected(:revision)))
    messages = skillmessages(plan.messages, content)
    projected = Dict{String, Any}[convert(Dict{String, Any}, message) for message in messages]
    Kernel.same(projected, plan.original) && return reloadsuccess!(terminal, agent, history)
    result = attempt(() -> transition!(revision -> Conversation.SystemUpdate(revision, messages), agent))
    reloadtransition!(terminal, agent, history, plan, result)
end
reloadtransition!(terminal, agent, history, plan, failure::ToolFailure) = reloadloaded!(terminal, agent, history, plan, failure)
reloadtransition!(terminal, agent, history, plan, result::Tuple) = reloadresult!(terminal, agent, history, first(result))
reloadresult!(terminal, agent, history, rejected::History.Rejected) = (agent, history, result!(terminal, rejected))
function reloadresult!(terminal, agent, history, result::Kernel.Applied)
    agent.messages = [convert(Dict{String, Any}, message) for message in result.state.messages]
    reloadsuccess!(terminal, agent, history)
end
function reloadsuccess!(terminal, agent, history)
    println(terminal.diagnostics, "Reloaded skills.")
    flush(terminal.diagnostics)
    agent, history, 0
end

keepmanaged!(messages, ::Conversation.SkillContext) = messages
keepmanaged!(messages, message::Conversation.Message) = push!(messages, message)

placement(::Nothing) = 1
placement(::Conversation.Message) = 1
const skillplacements = Dict("system" => 2)
placement(message::Conversation.RawMessage) = get(skillplacements, get(message.value, "role", nothing), 1)
addskill!(messages, ::Nothing) = messages
function addskill!(messages, content::AbstractString)
    insert!(messages, placement(get(messages, 1, nothing)), Conversation.SkillContext(String(content)))
end
function skillmessages(messages, content)
    kept = foldl(keepmanaged!, messages; init=Conversation.Message[])
    addskill!(kept, content)
end

function refreshskills!(agent, skills)
    lock(agent.lock) do
        content = Skills.render(skills, Skills.reader(values(agent.tools)))
        messages = foldl(keepmanaged!, agent.state.messages; init=Conversation.Message[])
        addskill!(messages, content)
        projected = Dict{String, Any}[convert(Dict{String, Any}, message) for message in messages]
        Kernel.same(projected, agent.messages) && return nothing
        result, _ = transition!(revision -> Conversation.SystemUpdate(revision, messages), agent)
        refreshresult!(agent, result)
    end
end
refreshresult!(agent, rejected::History.Rejected) = rejected
refreshresult!(agent, result) = result
function refreshresult!(agent, result::Kernel.Applied)
    agent.messages = Dict{String, Any}[convert(Dict{String, Any}, message) for message in result.state.messages]
    nothing
end

command!(::TreeCommand, terminal, agent, history, input, directory, snapshot) = tree!(terminal, agent, history, input, snapshot)
command!(::ResumeCommand, terminal, agent, history, input, directory, snapshot) = resume!(terminal, agent, history, input, directory)
command!(::NewCommand, terminal, agent, history, input, directory, snapshot) = new!(terminal, agent, history, directory, snapshot)
command!(::CloneCommand, terminal, agent, history, input, directory, snapshot) = clone!(terminal, agent, history, directory)
command!(::ForkCommand, terminal, agent, history, input, directory, snapshot) = forkcommand!(terminal, agent, history, input, directory, snapshot, identity)
command!(command::TerminalCommand, terminal, agent, history, input, directory, snapshot, draft::Ref{String}) = command!(command, terminal, agent, history, input, directory, snapshot)
command!(::ForkCommand, terminal, agent, history, input, directory, snapshot, draft::Ref{String}) = fork!(terminal, agent, history, input, directory, draft)
command!(command::TerminalCommand, terminal, agent, history, input, directory, snapshot, draft::Ref{String}, resources) = command!(command, terminal, agent, history, input, directory, snapshot, draft)
command!(::ReloadCommand, terminal, agent, history, input, directory, snapshot, draft::Ref{String}, resources::Skills.Resources) = reload!(terminal, agent, history, resources)
command!(::NewCommand, terminal, agent, history, input, directory, snapshot, draft::Ref{String}, resources::Skills.Resources) = new!(terminal, agent, history, directory, snapshot, resources)
command!(::ResumeCommand, terminal, agent, history, input, directory, snapshot, draft::Ref{String}, resources::Skills.Resources) = resume!(terminal, agent, history, input, directory, resources)
command!(::ShowName, terminal, agent, history, input, directory, snapshot) = showname!(terminal, agent, history, SessionCatalog.sessionname(history))
command!(command::SetName, terminal, agent, history, input, directory, snapshot) = setname!(terminal, agent, history, command.name, name!(agent, command.name))
command!(command::SetModel, terminal, agent, history, input, directory, snapshot) = setmodel!(terminal, agent, history, command.model)

function command!(::SelectModel, terminal, agent, history, input, directory, snapshot)
    print(terminal.diagnostics, "Model ID (empty cancels): ")
    flush(terminal.diagnostics)
    eof(input) && return agent, history, 0
    model = strip(readline(input))
    isempty(model) && return agent, history, 0
    setmodel!(terminal, agent, history, model)
end

function setmodel!(terminal, agent::Agent{P}, history, model::AbstractString) where {P<:Union{OpenAI, OpenAIResponses, Anthropic, Google}}
    isempty(model) && return agent, history, 0
    selected = modelchange(agent.provider, model, agent.provider.route)
    setmodel!(terminal, agent, history, model, selected)
end
function setmodel!(terminal, agent::Agent{P}, history, model, selected::P) where {P<:Union{OpenAI, OpenAIResponses, Anthropic, Google}}
    lock(agent.lock) do
        agent.provider = selected
    end
    append!(terminal.secrets, [selected.key; last.(selected.extra)])
    println(terminal.diagnostics, "Model set: ", redact(terminal, model))
    flush(terminal.diagnostics)
    agent, history, 0
end
setmodel!(terminal, agent::Agent, history, model, status::Integer) = (agent, history, status)
function setmodel!(terminal, agent::Agent, history, model, selected)
    println(terminal.diagnostics, "Model switching across APIs is unavailable.")
    flush(terminal.diagnostics)
    agent, history, 1
end
function setmodel!(terminal, agent::Agent, history, model)
    println(terminal.diagnostics, "Model switching is unavailable for this provider.")
    flush(terminal.diagnostics)
    agent, history, 1
end

function showname!(terminal, agent, history, ::Nothing)
    println(terminal.diagnostics, "Usage: /name <name>")
    flush(terminal.diagnostics)
    agent, history, 0
end
function showname!(terminal, agent, history, name::String)
    println(terminal.diagnostics, "Session name: ", name)
    flush(terminal.diagnostics)
    agent, history, 0
end
showname!(terminal, agent, history, rejected::History.Rejected) = (agent, history, result!(terminal, rejected))

function setname!(terminal, agent, history, name, ::Nothing)
    println(terminal.diagnostics, "Session name set: ", name)
    flush(terminal.diagnostics)
    agent, history, 0
end
setname!(terminal, agent, history, name, rejected::History.Rejected) = (agent, history, result!(terminal, rejected))

fresh(::Nothing, directory) = History.Tree(History.Memory())
fresh(::History.Memory, directory) = History.Tree(History.Memory())
fresh(::History.Tree{<:History.Memory}, directory) = History.Tree(History.Memory())
fresh(history::History.Store, directory) = SessionCatalog.new(directory, pwd())

new!(terminal::Terminal, agent::Agent, history, directory, snapshot) = new!(terminal, agent, history, directory, snapshot, nothing)
new!(terminal::Terminal, agent::Agent, history, directory, snapshot, resources; parent=nothing) = newchecked!(terminal, agent, history, directory, snapshot, resources, parent, sourcecheck!(terminal, agent, history))
newchecked!(terminal, agent, history, directory, snapshot, resources, parent, blocked::Union{PendingInputs, History.Rejected}) = (agent, history, sourcestatus!(terminal, blocked))

function newchecked!(terminal, agent, history, directory, snapshot, resources, parent, ::Nothing)
    selected = fresh(history, directory)
    pending = Ref{Union{Nothing, History.Tree}}(selected)
    loaded = Ref{Union{Nothing, Vector{Skills.Skill}}}(nothing)
    try
        replacement = attempt(() -> begin
            skills = Skills.load(pwd())
            loaded[] = skills
            replacement = Agent(agent.provider, agent.tools, initial(agent, snapshot, skills); history=selected)
            newparent!(replacement, parent)
        end)
        result = newresult!(terminal, agent, history, selected, replacement, pending)
        updateskills!(resources, loaded[], result[3])
        result
    finally
        release!(history, pending[])
    end
end

newparent!(agent::Agent, ::Nothing) = agent
newparent!(agent::Agent, path::String) = newparent!(agent, first(transition!(revision -> Conversation.SessionParent(revision, path), agent)))
newparent!(agent::Agent, result::Kernel.Applied) = agent
newparent!(agent::Agent, result) = result

initial(agent::Agent, snapshot::Extensions.Snapshot, skills::Vector{Skills.Skill}) = initial(snapshot, skills)
initial(agent::Agent, ::Nothing) = initial(agent, nothing, Skills.load(pwd()))
function initial(agent::Agent, ::Nothing, skills::Vector{Skills.Skill})
    cwd = pwd()
    files = Instructions.load(cwd; agentdir=get(ENV, "JF_INSTRUCTIONS_DIR", nothing))
    prompt = context(cwd, collect(values(agent.tools)), files)
    messages = Conversation.Message[Conversation.RawMessage(Dict("role" => "system", "content" => prompt))]
    Skills.appendprompt!(messages, Skills.render(skills, Skills.reader(values(agent.tools))))
    messages
end

newresult!(terminal, agent, history, selected, rejected::History.Rejected, pending) = (agent, history, result!(terminal, rejected))
newresult!(terminal, agent, history, selected, failure::ToolFailure, pending) = resume!(terminal, agent, history, failure)
newresult!(terminal, agent, history, selected, replacement::Agent, pending) = newresult!(terminal, agent, history, selected, replacement, pending, replacement.fault)
newresult!(terminal, agent, history, selected, replacement::Agent, pending, rejected::History.Rejected) = (agent, history, sessionfault!(terminal, rejected, selected))

function newresult!(terminal, agent, history, selected, replacement::Agent, pending, ::Nothing)
    lock(agent.lock) do
        newfinal!(terminal, agent, history, selected, replacement, pending, sourcecheck!(terminal, agent, history, agent.fault))
    end
end

newfinal!(terminal, agent, history, selected, replacement, pending, blocked::Union{PendingInputs, History.Rejected}) = (agent, history, sourcestatus!(terminal, blocked))
function newfinal!(terminal, agent, history, selected, replacement, pending, ::Nothing)
    closehistory!(history)
    pending[] = nothing
    println(terminal.diagnostics, "New session started.")
    flush(terminal.diagnostics)
    replacement, selected, 0
end

sessiontree(history::History.Tree) = history
sessiontree(history::History.SQLite) = History.Tree(history)
sessiontree(history) = History.Rejected(:invalid_record)

clone!(terminal, agent, history, directory) = clonechecked!(terminal, agent, history, directory, sourcecheck!(terminal, agent, history))
clonechecked!(terminal, agent, history, directory, blocked::Union{PendingInputs, History.Rejected}) = (agent, history, sourcestatus!(terminal, blocked))
clonechecked!(terminal, agent, history, directory, ::Nothing) = clone!(terminal, agent, history, directory, attempt(() -> sessiontree(history)))
clone!(terminal, agent, history, directory, failure::ToolFailure) = resume!(terminal, agent, history, failure)
clone!(terminal, agent, history, directory, rejected::History.Rejected) = (agent, history, result!(terminal, rejected))
clone!(terminal, agent, history, directory, tree::History.Tree) = clone!(terminal, agent, history, directory, tree, attempt(() -> History.snapshot(tree)))
clone!(terminal, agent, history, directory, tree, failure::ToolFailure) = resume!(terminal, agent, history, failure)
clone!(terminal, agent, history, directory, tree, rejected::History.Rejected) = (agent, history, result!(terminal, rejected))
function clone!(terminal, agent, history, directory, tree, snapshot::History.Snapshot)
    if length(snapshot.batches) <= 1
        println(terminal.diagnostics, "Nothing to clone yet.")
        flush(terminal.diagnostics)
        return agent, history, 0
    end
    clone!(terminal, agent, history, directory, tree, cloneable(tree))
end
cloneable(::History.Tree) = nothing
cloneable(tree::History.Tree{<:SessionCatalog.Deferred}) = cloneable(tree.store.store)
cloneable(::History.Memory) = SessionCatalog.Invalid("This session has not been saved yet. Send a message before cloning it.")
cloneable(::History.SQLite) = nothing
function clone!(terminal, agent, history, directory, tree, invalid::SessionCatalog.Invalid)
    println(terminal.diagnostics, invalid.message)
    flush(terminal.diagnostics)
    agent, history, 1
end
function clone!(terminal, agent, history, directory, tree, ::Nothing)
    selected = attempt(() -> SessionCatalog.duplicate(fresh(history, directory), SessionCatalog.branchpath(tree, tree.leaf), SessionCatalog.Path()))
    switch!(terminal, agent, history, selected, "Cloned to new session.", () -> nothing)
end

switch!(terminal, agent, history, rejected::History.Rejected, message, action) = (agent, history, result!(terminal, rejected))
switch!(terminal, agent, history, failure::ToolFailure, message, action) = resume!(terminal, agent, history, failure)
function switch!(terminal, agent, history, selected::History.Tree, message, action)
    pending = Ref{Union{Nothing, History.Tree}}(selected)
    try
        restored = attempt(() -> Agent(agent.provider, agent.tools, Dict{String, Any}[]; history=selected))
        switch!(terminal, agent, history, selected, message, action, restored, pending)
    finally
        release!(history, pending[])
    end
end
switch!(terminal, agent, history, selected, message, action, rejected::History.Rejected, pending) = (agent, history, result!(terminal, rejected))
switch!(terminal, agent, history, selected, message, action, failure::ToolFailure, pending) = resume!(terminal, agent, history, failure)
switch!(terminal, agent, history, selected, message, action, restored::Agent, pending) = switch!(terminal, agent, history, selected, message, action, restored, restored.fault, pending)
switch!(terminal, agent, history, selected, message, action, restored::Agent, rejected::History.Rejected, pending) = (agent, history, result!(terminal, rejected))
switch!(terminal, agent, history, selected, message, action, restored::Agent, ::Nothing, pending) = switchchecked!(terminal, agent, history, selected, message, action, restored, pending, checkqueues!(terminal, restored.state, selected))
switchchecked!(terminal, agent, history, selected, message, action, restored, pending, ::PendingInputs) = (agent, history, 1)
function switchchecked!(terminal, agent, history, selected, message, action, restored, pending, ::Nothing)
    lock(agent.lock) do
        switchfinal!(terminal, agent, history, selected, message, action, restored, pending, switchsource!(terminal, agent, history, agent.fault))
    end
end
switchsource!(terminal, agent, history, fault) = switchsource!(agent, sourcecheck!(terminal, agent, history, fault))
switchsource!(agent, blocked::Union{PendingInputs, History.Rejected}) = blocked
switchsource!(agent, ::Nothing) = History.ready(agent.state)
switchfinal!(terminal, agent, history, selected, message, action, restored, pending, blocked::Union{PendingInputs, History.Rejected}) = (agent, history, sourcestatus!(terminal, blocked))
function switchfinal!(terminal, agent, history, selected, message, action, restored, pending, ::Nothing)
    closehistory!(history)
    pending[] = nothing
    action()
    println(terminal.diagnostics, message)
    flush(terminal.diagnostics)
    restored, selected, 0
end

function forkcommand!(terminal, agent, history, input, directory, snapshot, expand)
    draft = Ref("")
    agent, history, status = fork!(terminal, agent, history, input, directory, draft)
    forkprompt!(terminal, agent, history, input, draft[], status, snapshot, expand)
end

fork!(terminal, agent, history, input, directory, draft::Ref{String}) = forkchecked!(terminal, agent, history, input, directory, draft, sourcecheck!(terminal, agent, history))
forkchecked!(terminal, agent, history, input, directory, draft, blocked::Union{PendingInputs, History.Rejected}) = (agent, history, sourcestatus!(terminal, blocked))
forkchecked!(terminal, agent, history, input, directory, draft, ::Nothing) = fork!(terminal, agent, history, input, directory, draft, attempt(() -> sessiontree(history)))
fork!(terminal, agent, history, input, directory, draft::Ref{String}, failure::ToolFailure) = resume!(terminal, agent, history, failure)
fork!(terminal, agent, history, input, directory, draft::Ref{String}, rejected::History.Rejected) = (agent, history, result!(terminal, rejected))
fork!(terminal, agent, history, input, directory, draft::Ref{String}, tree::History.Tree) = fork!(terminal, agent, history, directory, draft, tree, attempt(() -> TreeTerminal.fork(tree, input, terminal.diagnostics, text -> redact(terminal, text))))
fork!(terminal, agent, history, directory, draft, tree::History.Tree, failure::ToolFailure) = resume!(terminal, agent, history, failure)
fork!(terminal, agent, history, directory, draft, tree::History.Tree, ::TreeTerminal.Cancelled) = (agent, history, 0)
fork!(terminal, agent, history, directory, draft, tree::History.Tree, rejected::History.Rejected) = (agent, history, result!(terminal, rejected))
function fork!(terminal, agent, history, directory, draft, tree::History.Tree, choice::TreeTerminal.InputFork)
    selected = attempt(() -> SessionCatalog.duplicate(fresh(history, directory), SessionCatalog.branchpath(tree, choice.node), SessionCatalog.Path()))
    forked!(terminal, agent, history, draft, selected, choice)
end
fork!(terminal, agent, history, directory, draft, tree::History.Tree, ::TreeTerminal.ImageFork) = (agent, history, result!(terminal, History.Rejected(:image_edit)))
fork!(terminal, agent, history, directory, draft, tree::History.Tree, choice::TreeTerminal.QueuedFork) = fork!(terminal, agent, history, directory, draft, choice, attempt(() -> SessionCatalog.queuedpath(tree, choice.node)))
fork!(terminal, agent, history, directory, draft, choice::TreeTerminal.QueuedFork, failure::ToolFailure) = resume!(terminal, agent, history, failure)
fork!(terminal, agent, history, directory, draft, choice::TreeTerminal.QueuedFork, rejected::History.Rejected) = (agent, history, result!(terminal, rejected))
function fork!(terminal, agent, history, directory, draft, choice::TreeTerminal.QueuedFork, path::NamedTuple)
    selected = attempt(() -> queuedcopy(fresh(history, directory), path))
    forked!(terminal, agent, history, draft, selected, choice)
end
queuedcopy(tree::History.Tree, path::NamedTuple) = queuedcopy(SessionCatalog.duplicate(tree, path.batches, SessionCatalog.Path()), path.state)
queuedcopy(rejected::History.Rejected, state) = rejected
queuedcopy(tree::History.Tree, state::Conversation.State) = SessionCatalog.prepare!(tree, state)
function forked!(terminal, agent, history, draft, selected, choice::TreeTerminal.ForkChoice)
    switch!(terminal, agent, history, selected, "Forked to new session.", () -> (draft[] = join(filter(!isempty, [choice.text, draft[]]), "\n\n")))
end

function forkprompt!(terminal, agent, history, input, draft, status, snapshot, expand)
    isempty(draft) && return agent, history, status
    print(terminal.diagnostics, "Message [", TreeTerminal.clean(redact(terminal, draft)), "] (empty keeps it, /cancel aborts): ")
    flush(terminal.diagnostics)
    eof(input) && return agent, history, status
    text = readline(input)
    text == "/cancel" && return agent, history, status
    result = run!(terminal, agent, expand(isempty(text) ? draft : text), snapshot)
    agent, history, max(status, result)
end

resume!(terminal::Terminal, agent::Agent, history, input::IO, directory::AbstractString) = resume!(terminal, agent, history, input, directory, nothing)
function resume!(terminal::Terminal, agent::Agent, history, input::IO, directory::AbstractString, resources)
    resumepick!(terminal, agent, history, input, directory, resources, resumecheck!(terminal, agent, history))
end

function resumecheck!(terminal::Terminal, agent::Agent, history)
    lock(agent.lock) do
        resumecheck!(agent.turn, sourcecheck!(terminal, agent, history, agent.fault))
    end
end
resumecheck!(turn::TurnState, blocked::Union{PendingInputs, History.Rejected}) = blocked
resumecheck!(::Idle, ::Nothing) = nothing
resumecheck!(::Union{Running, Cancelled}, ::Nothing) = History.Rejected(:busy)

function sourcecheck!(terminal::Terminal, agent::Agent, history)
    lock(agent.lock) do
        sourcecheck!(terminal, agent, history, agent.fault)
    end
end

sourcecheck!(terminal::Terminal, agent::Agent, history, rejected::History.Rejected) = rejected
sourcecheck!(terminal::Terminal, agent::Agent, history, ::Nothing) = checkqueues!(terminal, agent.state, history)
sourcestatus!(terminal::Terminal, ::PendingInputs) = 1
sourcestatus!(terminal::Terminal, rejected::History.Rejected) = result!(terminal, rejected)
resumepick!(terminal::Terminal, agent::Agent, history, input, directory, resources, blocked::Union{PendingInputs, History.Rejected}) = (agent, history, sourcestatus!(terminal, blocked))

function resumepick!(terminal::Terminal, agent::Agent, history, input, directory, resources, ::Nothing)
    selected = attempt(() -> SessionCatalog.choose(SessionCatalog.Picker(), directory, pwd(), input, terminal.diagnostics, text -> redact(terminal, text)))
    resume!(terminal, agent, history, selected, resources)
end

resume!(terminal::Terminal, agent::Agent, history, ::SessionCatalog.Cancelled) = (agent, history, 0)
resume!(terminal::Terminal, agent::Agent, history, rejected::History.Rejected) = (agent, history, result!(terminal, rejected))
function resume!(terminal::Terminal, agent::Agent, history, failure::ToolFailure)
    println(terminal.diagnostics, redact(terminal, failure.text))
    flush(terminal.diagnostics)
    agent, history, 1
end

resume!(terminal::Terminal, agent::Agent, history, selected::History.Tree) = resume!(terminal, agent, history, selected, nothing)
resume!(terminal::Terminal, agent::Agent, history, selected, resources) = resume!(terminal, agent, history, selected)
function resume!(terminal::Terminal, agent::Agent, history, selected::History.Tree, resources::Union{Nothing, Skills.Resources})
    pending = Ref{Union{Nothing, History.Tree}}(selected)
    try
        resumeactive!(terminal, agent, history, selected, pending, resources, resumecheck!(terminal, agent, history))
    finally
        release!(history, pending[])
    end
end

release!(history, ::Nothing) = nothing
release!(history, selected::History.Tree) = history === selected ? nothing : close(selected)
resumeactive!(terminal::Terminal, agent::Agent, history, selected::History.Tree, pending, resources, blocked::Union{PendingInputs, History.Rejected}) = (agent, history, sourcestatus!(terminal, blocked))

function resumeactive!(terminal::Terminal, agent::Agent, history, selected::History.Tree, pending, resources, ::Nothing)
    history === selected && return (agent, history, 0)
    restored = attempt(() -> Agent(agent.provider, agent.tools, Dict{String, Any}[]; history=selected))
    resume!(terminal, agent, history, selected, restored, pending, resources)
end

function resume!(terminal::Terminal, agent::Agent, history, selected::History.Tree, rejected::History.Rejected, pending, resources)
    agent, history, result!(terminal, rejected)
end

resume!(terminal::Terminal, agent::Agent, history, selected::History.Tree, failure::ToolFailure, pending, resources) = resume!(terminal, agent, history, failure)
resume!(terminal::Terminal, agent::Agent, history, selected::History.Tree, restored::Agent, pending, resources) = resume!(terminal, agent, history, selected, restored, restored.fault, pending, resources)

function resume!(terminal::Terminal, agent::Agent, history, selected::History.Tree, restored::Agent, fault::History.Rejected, pending, resources)
    status = sessionfault!(terminal, fault, selected)
    agent, history, status
end

resume!(terminal::Terminal, agent::Agent, history, selected::History.Tree, restored::Agent, ::Nothing, pending, resources) = resumechecked!(terminal, agent, history, selected, restored, pending, resources, checkqueues!(terminal, restored.state, selected))
resumechecked!(terminal::Terminal, agent::Agent, history, selected::History.Tree, restored::Agent, pending, resources, ::PendingInputs) = (agent, history, 1)

function resumechecked!(terminal::Terminal, agent::Agent, history, selected::History.Tree, restored::Agent, pending, resources, ::Nothing)
    loaded = attempt(() -> Skills.load(pwd()))
    resumeloaded!(terminal, agent, history, selected, restored, pending, resources, loaded)
end
resumeloaded!(terminal, agent, history, selected, restored, pending, resources, failure::ToolFailure) = resume!(terminal, agent, history, failure)
function resumeloaded!(terminal, agent, history, selected, restored, pending, resources, skills::Vector{Skills.Skill})
    lock(agent.lock) do
        resumesource!(terminal, agent, history, selected, restored, pending, resources, skills, resumecheck!(agent.turn, sourcecheck!(terminal, agent, history, agent.fault)))
    end
end
resumesource!(terminal, agent, history, selected, restored, pending, resources, skills, blocked::Union{PendingInputs, History.Rejected}) = resumefinal!(terminal, agent, history, selected, restored, pending, resources, skills, blocked)
function resumesource!(terminal, agent, history, selected, restored, pending, resources, skills, ::Nothing)
    refreshed = attempt(() -> refreshskills!(restored, skills))
    resumerefreshed!(terminal, agent, history, selected, restored, pending, resources, skills, refreshed)
end
resumerefreshed!(terminal, agent, history, selected, restored, pending, resources, skills, failure::ToolFailure) = resume!(terminal, agent, history, failure)
resumerefreshed!(terminal, agent, history, selected, restored, pending, resources, skills, rejected::History.Rejected) = (agent, history, result!(terminal, rejected))
resumerefreshed!(terminal, agent, history, selected, restored, pending, resources, skills, ::Nothing) = resumefinal!(terminal, agent, history, selected, restored, pending, resources, skills, nothing)

resumefinal!(terminal::Terminal, agent::Agent, history, selected::History.Tree, restored::Agent, pending, resources, skills, blocked::Union{PendingInputs, History.Rejected}) = (agent, history, sourcestatus!(terminal, blocked))

function resumefinal!(terminal::Terminal, agent::Agent, history, selected::History.Tree, restored::Agent, pending, resources, skills, ::Nothing)
    result = (restored, selected, 0)
    println(terminal.diagnostics, "Resuming session.")
    flush(terminal.diagnostics)
    closehistory!(history)
    updateskills!(resources, skills, 0)
    pending[] = nothing
    result
end
