module JuliaForever

using HTTP, JSON3, StructTypes, Unicode, Base64, Random, SHA, REPL

export Execution, ContextEstimates
export Read, Write, Edit, Bash, PowerShell, Ls, Find, Grep, CodeMode, CodeCancellation, CodeResult, CodeSuccess, CodeFailure, cancel!, codeexecute, Image, ToolResult, ToolSuccess, ToolFailure, execute, Agent, OpenAI, OpenAIResponses, Anthropic, Google, Usage, Completion, Truncated, InvalidResponse, ProviderStatus, ProviderError, UnsupportedImage, OpenRouterLogin, OpenRouterCallback, provider, authorize, exchange, stream, respond!, Durable, History, Sessions, Kernel, Conversation
export ToolSet, ToolNamespace, expose!, register!, unregister!

include("instructions.jl")
include("prompts.jl")
include("tools.jl")
include("tool_search.jl")
include("file_arguments.jl")
include("system.jl")
include("provider.jl")
include("kernel.jl")
include("conversation.jl")
include("durable.jl")
include("history.jl")
include("sqlite_history.jl")
include("tool_search_events.jl")
include("agent.jl")
include("estimates.jl")
include("extensions.jl")
include("agent_history.jl")
include("compaction.jl")
include("responses.jl")
include("anthropic.jl")
include("google.jl")
include("sessions.jl")
include("session_catalog.jl")
include("execution.jl")
include("execution_kernel.jl")
include("agent_execution.jl")
include("logs.jl")
include("search.jl")
include("context.jl")
include("skills.jl")
include("codemode.jl")
include("tool_selection.jl")
include("terminal.jl")
include("terminal_editor.jl")
include("tree_terminal.jl")
include("session_terminal.jl")
include("terminal_live.jl")
include("mcp.jl")

const tuimode = Base.ScopedValues.ScopedValue{LiveTerminal.Mode}(LiveTerminal.FullscreenMode())
const tuimodes = Dict("fullscreen" => LiveTerminal.FullscreenMode(), "regular" => LiveTerminal.RegularMode())

missingmodel(env, info, ::Nothing) = isempty(strip(get(env, info.model, ""))) ? [info.model] : String[]
missingmodel(env, info, model::AbstractString) = isempty(strip(model)) ? [info.model] : String[]

function reportmissing(missing)
    isempty(missing) && return true
    println(stderr, "Set ", join(missing, " and "), ".")
    false
end

missingkey!(missing, ::Nothing, info) = push!(missing, info.key)
missingkey!(missing, key::AbstractString, info) = isempty(key) && push!(missing, info.key)

function configured(env, info, model)
    missing = missingmodel(env, info, model)
    missingkey!(missing, keyvalue(env, info), info)
    reportmissing(missing)
end

configuredlogin(env, info, model) = reportmissing(missingmodel(env, info, model))

abstract type Authentication end
struct APIKeyAuth <: Authentication end
abstract type OpenRouterAuth <: Authentication end
struct CodeAuth <: OpenRouterAuth end
struct CallbackAuth <: OpenRouterAuth end

struct HistoryInspection end
struct HistoryAbandonment
    reason::String
end
struct HistoryConflict end

historyinspect(::Nothing) = HistoryInspection()
historyinspect(action::HistoryInspection) = action
historyinspect(::Union{HistoryAbandonment, HistoryConflict}) = HistoryConflict()
historyabandon(::Union{Nothing, HistoryAbandonment}, reason) = HistoryAbandonment(reason)
historyabandon(::Union{HistoryInspection, HistoryConflict}, reason) = HistoryConflict()

haslogin(::APIKeyAuth) = false
haslogin(::OpenRouterAuth) = true
const loginproviders = Dict("openrouter" => providerinfos["openrouter"])
providername(::APIKeyAuth, ::Nothing) = get(ENV, "JF_PROVIDER", "openai")
providername(::APIKeyAuth, selected::AbstractString) = selected
providername(::OpenRouterAuth, selected) = "openrouter"

function authorize(::CodeAuth)
    login = authorize()
    println("Open this URL and authorize Julia Forever: ", login.url)
    print("Authorization code: ")
    flush(stdout)
    login, strip(readline(stdin))
end

function authorize(::CallbackAuth)
    callback = OpenRouterCallback()
    try
        login = authorize(callback)
        println("Open this URL and authorize Julia Forever: ", login.url)
        flush(stdout)
        login, wait(callback)
    finally
        close(callback)
    end
end

function authenticated(::Nothing, base, model)
    println(stderr, "OpenRouter did not return an API key.")
    2
end

authenticated(failure::InvalidResponse, base, model) = failure!(Terminal(stdout, stderr, String[]), failure)
authenticated(failure::ProviderStatus, base, model) = failure!(Terminal(stdout, stderr, String[]), failure)
authenticated(key::AbstractString, base, model) = OpenAI(base, model, key)

function login!(login::OpenRouterLogin, ::Nothing, info, model)
    println(stderr, "OpenRouter authorization was denied or timed out.")
    2
end

function login!(login::OpenRouterLogin, code::AbstractString, info, model)
    base = get(ENV, info.base, info.url)
    result = request!(Terminal(stdout, stderr, String[])) do
        exchange(login, code; base)
    end
    result.status == 0 || return result.status
    authenticated(result.value, base, modelvalue(ENV, info.model, model))
end

function acquire(::Authentication, ::Nothing, model)
    println(stderr, "Unknown provider; choose openai, openai-responses, openrouter, anthropic, or google.")
    2
end

function acquire(::APIKeyAuth, info::NamedTuple, model)
    configured(ENV, info, model) || return 2
    provider(info, ENV, model)
end

function acquire(auth::OpenRouterAuth, info::NamedTuple, model)
    configuredlogin(ENV, info, model) || return 2
    login, code = authorize(auth)
    login!(login, code, info, model)
end

launch(output, status::Integer, packages, environments, codemode, session, sessiondir, args, sessionname, baseline, rules, excluded, mode) = status

function launch(output, model::Union{OpenAI, OpenAIResponses, Anthropic, Google}, packages, environments, codemode, session, sessiondir, args, sessionname, baseline, rules, excluded, mode)
    tools = Tool[Read(pwd()), Write(pwd()), Edit(pwd()), Bash(pwd()), PowerShell(pwd()), Ls(pwd()), Find(pwd()), Grep(pwd())]
    terminal = Terminal(output, stderr, [model.key], mode)
    registry = plugins(terminal, tools, packages, environments)
    Base.invokelatest(terminal!, terminal, model, registry, codemode, session, sessiondir, args, sessionname, baseline, rules, excluded)
end

pluginfailure!(terminal::Terminal, name, exception::InterruptException) = failure!(terminal, exception)

function pluginfailure!(terminal::Terminal, name, exception)
    println(terminal.diagnostics, "[plugin] ", redact(terminal, name), ": ", redact(terminal, sprint(showerror, exception)))
    flush(terminal.diagnostics)
    2
end

function pluginfailure!(terminal::Terminal, name, rejected::Extensions.Rejected)
    println(terminal.diagnostics, "[plugin] ", redact(terminal, name), ": ", rejected.reason, " ", redact(terminal, rejected.name))
    flush(terminal.diagnostics)
    2
end

function plugins(terminal::Terminal, tools, packages, environments)
    registry = Extensions.Registry()
    Extensions.register!(registry, gensym(:builtins), Extensions.Plugin(; tools))
    if !isempty(packages)
        for environment in reverse(environments)
            insert!(LOAD_PATH, min(2, length(LOAD_PATH) + 1), abspath(expanduser(environment)))
        end
        isempty(environments) || (ENV["JULIA_LOAD_PATH"] = join(Base.load_path(), Sys.iswindows() ? ';' : ':'))
    end
    seen = Set{Symbol}()
    result = registry
    for name in packages
        result = plugin!(terminal, result, name, seen)
    end
    result
end

plugin!(terminal, status::Integer, name, seen) = status

function plugin!(terminal, registry::Extensions.Registry, name, seen)
    id = Symbol(name)
    id in seen && return pluginfailure!(terminal, name, Extensions.Rejected(:duplicate_plugin, name))
    push!(seen, id)
    result = try
        package = Base.require(Main, id)
        factory = Base.invokelatest(getproperty, package, :plugin)
        plugin = Base.invokelatest(factory)
        Base.invokelatest(Extensions.register!, registry, id, plugin)
    catch exception
        return pluginfailure!(terminal, name, exception)
    end
    registered(terminal, registry, name, result)
end

registered(terminal, registry, name, ::Bool) = registry
registered(terminal, registry, name, result::Extensions.Rejected) = pluginfailure!(terminal, name, result)

function help!()
    println("jf [--provider NAME] [--model ID] [--codemode] [--history PATH] [prompt] | jf --history PATH --inspect-history | jf --history PATH --abandon REASON | jf [options] --login-openrouter [prompt] | jf [options] --login-openrouter-callback [prompt]\nProviders: openai, openai-responses, openrouter, anthropic, google. --provider overrides JF_PROVIDER; --model overrides the selected provider's model environment variable. Set the selected provider's API key. Use --plugin PACKAGE and optional --plugin-env PATH to load a trusted native Julia plugin; both options may be repeated. Code mode runs Julia with your permissions. Set JF_INSTRUCTIONS_DIR to include global instructions.")
    println("Sessions: --continue (-c), --resume (-r), --session PATH|ID, --fork PATH|ID, --session-dir DIR, --no-session, --name NAME (-n). Set JF_SESSION_DIR to choose the default directory.")
    println("Tools: --tools (-t) LIST, --exclude-tools (-xt) LIST, --no-builtin-tools (-nbt), --no-tools (-nt).")
    println("Terminal: --tui-mode fullscreen|regular (default: fullscreen).")
    println("Output: --mode text|json.")
    println("Use @PATH to include a text file or image in the initial prompt.")
    0
end

function (@main)(args)
    codemode = false
    packages = String[]
    environments = String[]
    action = nothing
    selected = nothing
    requested_model = nothing
    auth = APIKeyAuth()
    session = SessionCatalog.New()
    sessiondir = SessionCatalog.directory(ENV)
    sessionname = nothing
    positional = String[]
    baseline = ToolSelection.Defaults()
    rules = ToolSelection.Inherit()
    excluded = Regex[]
    tui = LiveTerminal.FullscreenMode()
    outputmode = TextMode()
    while !isempty(args)
        if first(args) == "--"
            append!(positional, args)
            break
        elseif first(args) in ("--help", "-h")
            return help!()
        elseif first(args) == "--tui-mode"
            if length(args) < 2 || !haskey(tuimodes, args[2])
                println(stderr, "--tui-mode requires regular or fullscreen.")
                return 2
            end
            tui = tuimodes[args[2]]
            args = args[3:end]
        elseif first(args) == "--codemode"
            codemode = true
            args = args[2:end]
        elseif first(args) == "--mode"
            if length(args) < 2 || startswith(args[2], "-")
                println(stderr, "--mode requires text or json.")
                return 2
            end
            outputmode = assignmode(outputmode, terminalmode(args[2]))
            args = args[3:end]
        elseif first(args) in ("--no-tools", "-nt")
            baseline = ToolSelection.baseline(baseline, ToolSelection.NoTools())
            args = args[2:end]
        elseif first(args) in ("--no-builtin-tools", "-nbt")
            baseline = ToolSelection.baseline(baseline, ToolSelection.NoBuiltin())
            args = args[2:end]
        elseif first(args) in ("--tools", "-t", "--exclude-tools", "-xt")
            option = first(args)
            if length(args) < 2
                println(stderr, option, " requires a value.")
                return 2
            end
            if option in ("--tools", "-t")
                rules = ToolSelection.assign(rules, ToolSelection.entries(args[2]))
            else
                excluded = ToolSelection.patterns(args[2])
            end
            args = args[3:end]
        elseif first(args) in ("--provider", "--model")
            option = first(args)
            if length(args) < 2 || isempty(strip(args[2])) || startswith(args[2], "--")
                println(stderr, option, " requires a value.")
                return 2
            end
            if option == "--provider"
                selected = args[2]
            else
                requested_model = args[2]
            end
            args = args[3:end]
        elseif first(args) in ("--login-openrouter", "--login-openrouter-callback")
            if haslogin(auth)
                println(stderr, "Select only one OpenRouter login mode.")
                return 2
            end
            auth = first(args) == "--login-openrouter" ? CodeAuth() : CallbackAuth()
            args = args[2:end]
        elseif first(args) in ("--plugin", "--plugin-env")
            option = first(args)
            if length(args) < 2 || isempty(args[2]) || startswith(args[2], "--")
                println(stderr, option, " requires a ", option == "--plugin" ? "package name" : "path", ".")
                return 2
            end
            push!(option == "--plugin" ? packages : environments, args[2])
            args = args[3:end]
        elseif first(args) == "--history"
            if length(args) < 2 || startswith(args[2], "--")
                println(stderr, "--history requires a path.")
                return 2
            end
            session = SessionCatalog.assign(session, SessionCatalog.Explicit(args[2]))
            args = args[3:end]
        elseif first(args) in ("--session", "--session-dir", "--fork")
            if length(args) < 2 || isempty(args[2]) || startswith(args[2], "--")
                println(stderr, first(args), " requires a value.")
                return 2
            end
            if first(args) == "--session"
                session = SessionCatalog.assign(session, SessionCatalog.Target(args[2]))
            elseif first(args) == "--fork"
                session = SessionCatalog.assign(session, SessionCatalog.Fork(args[2]))
            else
                sessiondir = abspath(expanduser(args[2]))
            end
            args = args[3:end]
        elseif first(args) in ("--continue", "-c")
            session = SessionCatalog.assign(session, SessionCatalog.Recent())
            args = args[2:end]
        elseif first(args) in ("--resume", "-r")
            session = SessionCatalog.assign(session, SessionCatalog.Picker())
            args = args[2:end]
        elseif first(args) == "--no-session"
            session = SessionCatalog.assign(session, SessionCatalog.Ephemeral())
            args = args[2:end]
        elseif first(args) in ("--name", "-n")
            if length(args) < 2 || isempty(Conversation.sessionname(args[2]))
                println(stderr, "--name requires a non-empty value.")
                return 2
            end
            sessionname = Conversation.sessionname(args[2])
            args = args[3:end]
        elseif first(args) == "--abandon"
            if length(args) < 2 || isempty(args[2]) || startswith(args[2], "--")
                println(stderr, "--abandon requires a reason.")
                return 2
            end
            action = historyabandon(action, args[2])
            args = args[3:end]
        elseif first(args) == "--inspect-history"
            action = historyinspect(action)
            args = args[2:end]
        else
            push!(positional, first(args))
            args = args[2:end]
        end
    end
    args = positional
    options = (; auth, selected, requested_model, packages, environments, codemode, session, sessiondir, args, sessionname, baseline, rules, excluded, tui, outputmode, output=stdout)
    selectedmode(action, options, outputmode)
end

selectedmode(action, options, ::TerminalMode) = selectedtools(action, options, options.rules)
function selectedmode(action, options, ::JSONMode)
    output = Base.fdio(reinterpret(Int32, Base.Libc.dup(Base.RawFD(1))), true)
    try
        redirect_stdout(first(Base.unwrapcontext(stderr))) do
            selectedtools(action, merge(options, (; output)), options.rules)
        end
    finally
        close(output)
    end
end
function selectedmode(action, options, ::InvalidMode)
    println(stderr, "--mode requires text or json.")
    2
end
selectedtools(action, options, ::ToolSelection.Rule) = selectedprovider(action, options, options.selected)
function selectedtools(action, options, invalid::ToolSelection.Invalid)
    println(stderr, "--tools: ", invalid.message)
    2
end
selectedprovider(action, options, ::Nothing) = historyaction(action, options)
selectedprovider(action, options, selected::AbstractString) = providerselection(action, options, providerinfo(selected))
providerselection(action, options, ::NamedTuple) = historyaction(action, options)
function providerselection(action, options, ::Nothing)
    println(stderr, "Unknown provider; choose openai, openai-responses, openrouter, anthropic, or google.")
    2
end

historyaction(::Nothing, options) = loginprovider(options.auth, options.selected, options)
loginprovider(::APIKeyAuth, selected, options) = launchprovider(options)
loginprovider(::OpenRouterAuth, ::Nothing, options) = launchprovider(options)
loginprovider(::OpenRouterAuth, selected::AbstractString, options) = loginprovider(options, get(loginproviders, selected, nothing))
loginprovider(options, ::NamedTuple) = launchprovider(options)
function loginprovider(options, ::Nothing)
    println(stderr, "OpenRouter login requires --provider openrouter.")
    2
end
function launchprovider(options)
    (; auth, selected, requested_model, packages, environments, codemode, session, sessiondir, args, sessionname, baseline, rules, excluded, outputmode, output) = options
    name = providername(auth, selected)
    info = providerinfo(name)
    model = acquire(auth, info, requested_model)
    Base.ScopedValues.with(tuimode => options.tui) do
        launch(output, model, packages, environments, codemode, session, sessiondir, args, sessionname, baseline, rules, excluded, provider(outputmode, name))
    end
end
historyaction(::HistoryInspection, options) = inspectrequest!(options.session, options.auth, options.sessionname, options.args)
historyaction(::HistoryConflict, options) = invalidinspection()
historyaction(action::HistoryAbandonment, options) = abandonrequest!(options.session, options.auth, options.sessionname, options.args, action.reason)

function invalidinspection()
    println(stderr, "--inspect-history requires --history PATH and no prompt or --abandon.")
    2
end
function invalidabandon()
    println(stderr, "--abandon requires --history PATH and no prompt.")
    2
end
inspectrequest!(session, auth, name, args) = invalidinspection()
function inspectrequest!(session::SessionCatalog.Explicit, ::APIKeyAuth, ::Nothing, args)
    isempty(args) || return invalidinspection()
    inspecthistory!(Terminal(stdout, stderr, String[]), session.path)
end
abandonrequest!(session, auth, name, args, reason) = invalidabandon()
function abandonrequest!(session::SessionCatalog.Explicit, ::APIKeyAuth, ::Nothing, args, reason)
    isempty(args) || return invalidabandon()
    abandonhistory!(Terminal(stdout, stderr, String[]), session.path, reason)
end
terminal!(terminal::Terminal, model, registry::Integer, codemode, session, sessiondir, args, sessionname, baseline, rules, excluded) = registry

function initial(extensions)
    cwd = pwd()
    files = Instructions.load(cwd; agentdir=get(ENV, "JF_INSTRUCTIONS_DIR", nothing))
    prompt = context(cwd, Extensions.tools(extensions), files)
    messages = Conversation.Message[Conversation.RawMessage(Dict("role" => "system", "content" => prompt))]
    Skills.appendprompt!(messages, Skills.render(Skills.load(cwd)))
    messages
end

initial(extensions, ::Nothing) = initial(extensions)
initial(extensions, snapshot::History.Snapshot) = iszero(snapshot.revision) ? initial(extensions) : Dict{String, Any}[]

selection(result::ToolFailure) = SessionCatalog.Invalid(result.text)
selection(result) = result

function terminal!(terminal::Terminal, model, registry::Extensions.Registry, codemode, session, sessiondir, args, sessionname, baseline, rules, excluded)
    if codemode
        mode = CodeMode(Extensions.tools(Extensions.snapshot(registry)))
        result = Extensions.register!(registry, gensym(:codemode), Extensions.Plugin(; tools=(mode,)))
        return terminal!(terminal, model, registered(terminal, registry, "codemode", result), false, session, sessiondir, args, sessionname, baseline, rules, excluded)
    end
    extensions = ToolSelection.select(Extensions.snapshot(registry), baseline, rules, excluded)
    history = selection(attempt(() -> SessionCatalog.choose(session, sessiondir, pwd(), stdin, stderr, text -> redact(terminal, text))))
    runsession!(history, terminal, model, extensions, args, sessiondir, sessionname)
end

runsession!(history, terminal, model, extensions, args) = runsession!(history, terminal, model, extensions, args, SessionCatalog.directory(ENV), nothing)
runsession!(history, terminal, model, extensions, args, sessiondir) = runsession!(history, terminal, model, extensions, args, sessiondir, nothing)
runsession!(::SessionCatalog.Cancelled, terminal, model, extensions, args, sessiondir, sessionname) = 0

function runsession!(invalid::SessionCatalog.Invalid, terminal, model, extensions, args, sessiondir, sessionname)
    println(terminal.diagnostics, redact(terminal, invalid.message))
    2
end

function sessionfault!(terminal, fault, history)
    status = result!(terminal, fault)
    println(terminal.diagnostics, "History file: ", redact(terminal, SessionCatalog.path(history)))
    flush(terminal.diagnostics)
    status
end

sessionfault!(terminal, fault, ::Nothing) = result!(terminal, fault)

runsession!(rejected::History.Rejected, terminal, model, extensions, args, sessiondir, sessionname) = result!(terminal, rejected)

function runsession!(history, terminal, model, extensions, args, sessiondir, sessionname)
    store = Ref{Union{Nothing, History.Store}}(history)
    try
        preparesession!(sessionsnapshot(history), terminal, model, extensions, store, args, sessiondir, sessionname)
    finally
        closehistory!(store[])
    end
end

sessionsnapshot(::Nothing) = nothing
sessionsnapshot(history::History.Store) = History.snapshot(history)
preparesession!(rejected::History.Rejected, terminal, model, extensions, store, args, sessiondir, sessionname) = result!(terminal, rejected)
preparesession!(snapshot, terminal, model, extensions, store, args, sessiondir, sessionname) = startsession!(terminal, model, extensions, store, args, sessiondir, sessionname, attempt(() -> initial(extensions, snapshot)))

closehistory!(::Nothing) = nothing
closehistory!(history::History.Store) = close(history)

function startsession!(terminal, model, extensions, store, args, sessiondir, sessionname, failure::ToolFailure)
    println(terminal.diagnostics, "Failed to initialize project context: ", redact(terminal, failure.text))
    flush(terminal.diagnostics)
    1
end

function startsession!(terminal, model, extensions, store, args, sessiondir, sessionname, messages)
    agent = Agent(model, extensions, messages; history=store[])
    startagent!(terminal, agent, extensions, store, args, sessiondir, sessionname)
end

startagent!(terminal, rejected::History.Rejected, extensions, store, args, sessiondir, sessionname) = result!(terminal, rejected)
startagent!(terminal, agent::Agent, extensions, store, args, sessiondir, sessionname) = startagent!(terminal, agent, extensions, store, args, sessiondir, sessionname, agent.fault)
startagent!(terminal, agent, extensions, store, args, sessiondir, sessionname, fault::History.Rejected) = sessionfault!(terminal, fault, store[])
function startagent!(terminal, agent, extensions, store, args, sessiondir, sessionname, ::Nothing)
    startsession!(terminal, agent, extensions, store, args, sessiondir, sessionname, checkqueues!(terminal, agent.state, store[]))
end

startsession!(terminal, agent, extensions, store, args, sessiondir, sessionname, ::PendingInputs) = 1

startsession!(terminal, agent, extensions, store, args, sessiondir, sessionname, ::Nothing) = startnamed!(terminal, agent, extensions, store, args, sessiondir, startname!(agent, sessionname))
startname!(agent, ::Nothing) = nothing
startname!(agent, name::String) = name!(agent, name)
startnamed!(terminal, agent, extensions, store, args, sessiondir, rejected::History.Rejected) = result!(terminal, rejected)
startnamed!(terminal, agent, extensions, store, args, sessiondir, ::Nothing) = starttemplates!(terminal, agent, extensions, store, args, sessiondir, attempt(() -> Prompts.load(pwd())))

function starttemplates!(terminal, agent, extensions, store, args, sessiondir, failure::ToolFailure)
    println(terminal.diagnostics, "Failed to load prompt templates: ", redact(terminal, failure.text))
    flush(terminal.diagnostics)
    1
end

function starttemplates!(terminal, agent, extensions, store, args, sessiondir, templates::AbstractDict)
    starttemplates!(terminal, agent, extensions, store, args, sessiondir, templates, terminal.mode)
end

function starttemplates!(terminal, agent, extensions, store, args, sessiondir, templates::AbstractDict, ::TextMode)
    parsed = FileArguments.parse(args)
    startfiles!(terminal, agent, extensions, store, sessiondir, templates, parsed.messages, parsed.files)
end

function startfiles!(terminal, agent, extensions, store, sessiondir, templates, messages, files)
    isempty(files) && return startplain!(terminal, agent, extensions, store, sessiondir, templates, messages)
    loaded = attempt(() -> FileArguments.load(files, pwd()))
    startfiles!(terminal, agent, extensions, store, sessiondir, templates, messages, loaded)
end

function startfiles!(terminal, agent, extensions, store, sessiondir, templates, messages, failure::ToolFailure)
    println(terminal.diagnostics, "Could not read file argument: ", redact(terminal, failure.text))
    flush(terminal.diagnostics)
    1
end

function startfiles!(terminal, agent, extensions, store, sessiondir, templates, messages, files::NamedTuple)
    piped = fileinput(stdin)
    initial = piped * files.text * get(messages, 1, "")
    isempty(initial) && length(messages) <= 1 && return interact!(terminal, agent, extensions, stdin, stderr, store, sessiondir, templates)
    status = isempty(initial) ? 0 : run!(terminal, agent, fileprompt(Prompts.expand(initial, templates), files.images), extensions)
    for text in Iterators.drop(messages, 1)
        status = max(status, run!(terminal, agent, Prompts.expand(text, templates), extensions))
    end
    status
end

fileinput(::Base.TTY) = ""
fileinput(input::IO) = strip(read(input, String))
fileprompt(text, images) = isempty(images) ? text : Conversation.ImagePrompt(text, images)

function startplain!(terminal, agent, extensions, store, sessiondir, templates, messages)
    if isempty(messages)
        return interact!(terminal, agent, extensions, stdin, stderr, store, sessiondir, templates)
    else
        return run!(terminal, agent, Prompts.expand(join(messages, " "), templates), extensions)
    end
end

intro!(output, input) = nothing
intro!(output, input::Base.TTY) = println(output, "Julia Forever — enter a message, or /exit to quit")
prompt!(output, input) = nothing

function prompt!(output, input::Base.TTY)
    print(output, "> ")
    flush(output)
end

interact!(terminal, agent, extensions, input, output) = interact!(terminal, agent, extensions, input, output, Ref{Union{Nothing, History.Store}}(agent.history), SessionCatalog.directory(ENV))
interact!(terminal, agent, extensions, input, output, store, sessiondir) = interact!(terminal, agent, extensions, input, output, store, sessiondir, Dict{String, String}())
interact!(terminal, agent, extensions, input, output, store, sessiondir, templates) = readloop!(terminal, agent, extensions, input, output, store, sessiondir, templates)

function interact!(terminal, agent, extensions, input::Base.TTY, output::Base.TTY, store, sessiondir, templates)
    get(ENV, "TERM", "") in ("", "dumb") && return readloop!(terminal, agent, extensions, input, output, store, sessiondir, templates)
    LiveTerminal.loop!(terminal, agent, extensions, store, input, sessiondir, templates, tuimode[])
end

function readloop!(terminal, agent, extensions, input, output, store, sessiondir, templates)
    intro!(output, input)
    status = 0
    while true
        prompt!(output, input)
        eof(input) && break
        line = readline(input)
        line == "/exit" && break
        agent, store[], result = readcommand!(terminal, agent, extensions, store[], line, input, sessiondir, templates, terminalcommand(line))
        status = max(status, result)
    end
    status
end

readcommand!(terminal, agent, extensions, history, line, input, sessiondir, templates, ::Nothing) = (agent, history, run!(terminal, agent, Prompts.expand(line, templates), extensions))
readcommand!(terminal, agent, extensions, history, line, input, sessiondir, templates, ::ForkCommand) = forkcommand!(terminal, agent, history, input, sessiondir, extensions, text -> Prompts.expand(text, templates))
readcommand!(terminal, agent, extensions, history, line, input, sessiondir, templates, command::TerminalCommand) = command!(command, terminal, agent, history, input, sessiondir, extensions)

include("live_json.jl")

end
