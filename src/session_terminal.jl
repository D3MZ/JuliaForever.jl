abstract type TerminalCommand end
struct TreeCommand <: TerminalCommand end
struct ResumeCommand <: TerminalCommand end
struct CompactCommand <: TerminalCommand end
struct ReloadCommand <: TerminalCommand end
struct NewCommand <: TerminalCommand end
struct CloneCommand <: TerminalCommand end
struct ForkCommand <: TerminalCommand end
struct ExitCommand <: TerminalCommand end
struct ShowName <: TerminalCommand end
struct SetName <: TerminalCommand
    name::String
end
struct SelectModel <: TerminalCommand end
struct SetModel <: TerminalCommand
    model::String
end

const terminalcommands = Dict{String, TerminalCommand}("/compact" => CompactCommand(), "/reload" => ReloadCommand(), "/tree" => TreeCommand(), "/resume" => ResumeCommand(), "/new" => NewCommand(), "/clone" => CloneCommand(), "/fork" => ForkCommand(), "/exit" => ExitCommand(), "/model" => SelectModel())
const namepattern = r"\A/name(?: +([\s\S]*))?\z"
const modelpattern = r"\A/model +([^\r\n]+)\z"
terminalcommand(text) = terminalcommand(get(terminalcommands, text, nothing), text)
terminalcommand(command::TerminalCommand, text) = command
terminalcommand(::Nothing, text) = modelcommand(namecommand(match(namepattern, text)), text)
modelcommand(command::TerminalCommand, text) = command
modelcommand(::Nothing, text) = modelcommand(match(modelpattern, text))
modelcommand(::Nothing) = nothing
modelcommand(found::RegexMatch) = SetModel(strip(found[1]))
namecommand(::Nothing) = nothing
namecommand(found::RegexMatch) = namecommand(Conversation.sessionname(something(found[1], "")))
namecommand(name::String) = isempty(name) ? ShowName() : SetName(name)

command!(::ReloadCommand, terminal, agent, history, input, directory, snapshot) = reload!(terminal, agent, history, () -> Skills.render(Skills.load(pwd())))

command!(::CompactCommand, terminal, agent, history, input, directory, snapshot) = (agent, history, compactresult!(terminal, compact!(agent)))

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
        Skills.render(skills)
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
    messages = skillmessages(plan.messages, agent.initial.messages, content)
    projected = Dict{String, Any}[convert(Dict{String, Any}, message) for message in messages]
    Kernel.same(projected, plan.original) && return reloadsuccess!(terminal, agent, history)
    result = attempt(() -> transition!(revision -> Conversation.History(revision, messages), agent))
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

legacy(::Nothing) = nothing
legacy(::Conversation.Message) = nothing
legacy(message::Conversation.RawMessage) = legacy(message.value, get(message.value, "content", nothing))
legacy(value, content) = nothing
legacy(value, content::AbstractString) = get(skillroles, get(value, "role", nothing), legacynone)(value, content)
legacynone(value, content) = nothing
function legacysystem(value, content)
    startswith(content, "<skills>\nThe following skills provide specialized instructions for specific tasks.\n") || return nothing
    endswith(content, "\n</available_skills>\n</skills>") || return nothing
    value
end
const skillroles = Dict("system" => legacysystem)

function marklegacy!(messages, initial)
    original = legacy(get(initial, 2, nothing))
    marklegacy!(messages, original, get(messages, 2, nothing))
end
marklegacy!(messages, original, message) = messages
function marklegacy!(messages, original::AbstractDict, message::Conversation.RawMessage)
    Kernel.same(original, message.value) && (messages[2] = Conversation.SkillContext(message.value["content"]))
    messages
end

placement(::Nothing) = 1
placement(::Conversation.Message) = 1
const skillplacements = Dict("system" => 2)
placement(message::Conversation.RawMessage) = get(skillplacements, get(message.value, "role", nothing), 1)
addskill!(messages, ::Nothing) = messages
function addskill!(messages, content::AbstractString)
    insert!(messages, placement(get(messages, 1, nothing)), Conversation.SkillContext(String(content)))
end
function skillmessages(messages, initial, content)
    current = marklegacy!(copy(messages), initial)
    kept = foldl(keepmanaged!, current; init=Conversation.Message[])
    addskill!(kept, content)
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
    lock(agent.lock) do
        previous = agent.provider
        agent.provider = P(previous.base, String(model), previous.key)
    end
    println(terminal.diagnostics, "Model set: ", redact(terminal, model))
    flush(terminal.diagnostics)
    agent, history, 0
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
new!(terminal::Terminal, agent::Agent, history, directory, snapshot, resources) = newchecked!(terminal, agent, history, directory, snapshot, resources, sourcecheck!(terminal, agent, history))
newchecked!(terminal, agent, history, directory, snapshot, resources, blocked::Union{PendingInputs, History.Rejected}) = (agent, history, sourcestatus!(terminal, blocked))

function newchecked!(terminal, agent, history, directory, snapshot, resources, ::Nothing)
    selected = fresh(history, directory)
    pending = Ref{Union{Nothing, History.Tree}}(selected)
    loaded = Ref{Union{Nothing, Vector{Skills.Skill}}}(nothing)
    try
        replacement = attempt(() -> begin
            skills = Skills.load(pwd())
            loaded[] = skills
            Agent(agent.provider, agent.tools, initial(agent, snapshot, skills); history=selected)
        end)
        result = newresult!(terminal, agent, history, selected, replacement, pending)
        updateskills!(resources, loaded[], result[3])
        result
    finally
        release!(history, pending[])
    end
end

initial(agent::Agent, snapshot::Extensions.Snapshot, skills::Vector{Skills.Skill}) = initial(snapshot, skills)
initial(agent::Agent, ::Nothing) = initial(agent, nothing, Skills.load(pwd()))
function initial(agent::Agent, ::Nothing, skills::Vector{Skills.Skill})
    cwd = pwd()
    files = Instructions.load(cwd; agentdir=get(ENV, "JF_INSTRUCTIONS_DIR", nothing))
    prompt = context(cwd, collect(values(agent.tools)), files)
    messages = Conversation.Message[Conversation.RawMessage(Dict("role" => "system", "content" => prompt))]
    Skills.appendprompt!(messages, Skills.render(skills))
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

function resume!(terminal::Terminal, agent::Agent, history, input::IO, directory::AbstractString)
    resumepick!(terminal, agent, history, input, directory, sourcecheck!(terminal, agent, history))
end

function sourcecheck!(terminal::Terminal, agent::Agent, history)
    lock(agent.lock) do
        sourcecheck!(terminal, agent, history, agent.fault)
    end
end

sourcecheck!(terminal::Terminal, agent::Agent, history, rejected::History.Rejected) = rejected
sourcecheck!(terminal::Terminal, agent::Agent, history, ::Nothing) = checkqueues!(terminal, agent.state, history)
sourcestatus!(terminal::Terminal, ::PendingInputs) = 1
sourcestatus!(terminal::Terminal, rejected::History.Rejected) = result!(terminal, rejected)
resumepick!(terminal::Terminal, agent::Agent, history, input, directory, blocked::Union{PendingInputs, History.Rejected}) = (agent, history, sourcestatus!(terminal, blocked))

function resumepick!(terminal::Terminal, agent::Agent, history, input, directory, ::Nothing)
    selected = attempt(() -> SessionCatalog.choose(SessionCatalog.Picker(), directory, pwd(), input, terminal.diagnostics, text -> redact(terminal, text)))
    resume!(terminal, agent, history, selected)
end

resume!(terminal::Terminal, agent::Agent, history, ::SessionCatalog.Cancelled) = (agent, history, 0)
resume!(terminal::Terminal, agent::Agent, history, rejected::History.Rejected) = (agent, history, result!(terminal, rejected))
function resume!(terminal::Terminal, agent::Agent, history, failure::ToolFailure)
    println(terminal.diagnostics, redact(terminal, failure.text))
    flush(terminal.diagnostics)
    agent, history, 1
end

function resume!(terminal::Terminal, agent::Agent, history, selected::History.Tree)
    pending = Ref{Union{Nothing, History.Tree}}(selected)
    try
        resumeactive!(terminal, agent, history, selected, pending, sourcecheck!(terminal, agent, history))
    finally
        release!(history, pending[])
    end
end

release!(history, ::Nothing) = nothing
release!(history, selected::History.Tree) = history === selected ? nothing : close(selected)
resumeactive!(terminal::Terminal, agent::Agent, history, selected::History.Tree, pending, blocked::Union{PendingInputs, History.Rejected}) = (agent, history, sourcestatus!(terminal, blocked))

function resumeactive!(terminal::Terminal, agent::Agent, history, selected::History.Tree, pending, ::Nothing)
    history === selected && return (agent, history, 0)
    restored = attempt(() -> Agent(agent.provider, agent.tools, Dict{String, Any}[]; history=selected))
    resume!(terminal, agent, history, selected, restored, pending)
end

function resume!(terminal::Terminal, agent::Agent, history, selected::History.Tree, rejected::History.Rejected, pending)
    agent, history, result!(terminal, rejected)
end

resume!(terminal::Terminal, agent::Agent, history, selected::History.Tree, failure::ToolFailure, pending) = resume!(terminal, agent, history, failure)
resume!(terminal::Terminal, agent::Agent, history, selected::History.Tree, restored::Agent, pending) = resume!(terminal, agent, history, selected, restored, restored.fault, pending)

function resume!(terminal::Terminal, agent::Agent, history, selected::History.Tree, restored::Agent, fault::History.Rejected, pending)
    status = sessionfault!(terminal, fault, selected)
    agent, history, status
end

resume!(terminal::Terminal, agent::Agent, history, selected::History.Tree, restored::Agent, ::Nothing, pending) = resumechecked!(terminal, agent, history, selected, restored, pending, checkqueues!(terminal, restored.state, selected))
resumechecked!(terminal::Terminal, agent::Agent, history, selected::History.Tree, restored::Agent, pending, ::PendingInputs) = (agent, history, 1)

function resumechecked!(terminal::Terminal, agent::Agent, history, selected::History.Tree, restored::Agent, pending, ::Nothing)
    lock(agent.lock) do
        resumefinal!(terminal, agent, history, selected, restored, pending, sourcecheck!(terminal, agent, history, agent.fault))
    end
end

resumefinal!(terminal::Terminal, agent::Agent, history, selected::History.Tree, restored::Agent, pending, blocked::Union{PendingInputs, History.Rejected}) = (agent, history, sourcestatus!(terminal, blocked))

function resumefinal!(terminal::Terminal, agent::Agent, history, selected::History.Tree, restored::Agent, pending, ::Nothing)
    result = (restored, selected, 0)
    println(terminal.diagnostics, "Resuming session.")
    flush(terminal.diagnostics)
    closehistory!(history)
    pending[] = nothing
    result
end
