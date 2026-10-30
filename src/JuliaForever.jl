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
include("models.jl")
include("provider.jl")
include("chatgpt.jl")
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
include("chatgpt_plan.jl")
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
include("cli_models.jl")
include("model_config.jl")
include("chatgpt_cli.jl")
include("history_export.jl")
include("openrouter_credentials.jl")

historyinspect(::Nothing) = HistoryInspection()
historyinspect(action::HistoryInspection) = action
historyinspect(::Union{HistoryAbandonment, HistoryConflict}) = HistoryConflict()
historyinspect(action::ModelListing) = action
historyabandon(::Union{Nothing, HistoryAbandonment}, reason) = HistoryAbandonment(reason)
historyabandon(::Union{HistoryInspection, HistoryConflict}, reason) = HistoryConflict()
historyabandon(action::ModelListing, reason) = action

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
function authenticated(key::AbstractString, base, model)
    reportremembered(rememberopenrouter(key, ENV))
    OpenAI(base, model, key)
end

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

acquire(auth, info, model, ::TerminalMode) = acquire(auth, info, model)
function acquire(::APIKeyAuth, info::NamedTuple, model, ::RPCMode)
    missing = missingmodel(ENV, info, model)
    missingkey!(missing, keyvalue(ENV, info), info)
    isempty(missing) || return UnconfiguredProvider()
    provider(info, ENV, model)
end

launch(output, status::Integer, packages, environments, codemode, session, sessiondir, args, sessionname, baseline, rules, excluded, mode) = status

function launch(output, model::Union{OpenAI, OpenAIResponses, Anthropic, Google, UnconfiguredProvider}, packages, environments, codemode, session, sessiondir, args, sessionname, baseline, rules, excluded, mode)
    tools = Tool[Read(pwd()), Write(pwd()), Edit(pwd()), Bash(pwd()), PowerShell(pwd()), Ls(pwd()), Find(pwd()), Grep(pwd())]
    terminal = Terminal(output, stderr, terminalkeys(model), mode)
    registry = plugins(terminal, tools, packages, environments)
    Base.invokelatest(terminal!, terminal, model, registry, codemode, session, sessiondir, args, sessionname, baseline, rules, excluded)
end
terminalkeys(model) = [model.key; last.(model.extra)]
terminalkeys(::UnconfiguredProvider) = String[]

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

function help!(io=stdout)
    println(io, "jf [--provider NAME] [--model ID] [--codemode] [--history PATH] [prompt] | jf --history PATH --inspect-history | jf --export PATH [OUTPUT.html|OUTPUT.json] | jf --history PATH --abandon REASON | jf [options] --login-chatgpt [prompt] | jf --logout-chatgpt | jf [options] --login-openrouter [prompt] | jf [options] --login-openrouter-callback [prompt] | jf --logout-openrouter\nProviders: openai, openai-responses, openrouter, anthropic, google. --provider overrides JF_PROVIDER; --model overrides the selected provider's model environment variable. Set the selected provider's API key. Use --plugin PACKAGE and optional --plugin-env PATH to load a trusted native Julia plugin; both options may be repeated. Code mode runs Julia with your permissions. Set JF_INSTRUCTIONS_DIR to include global instructions.")
    println(io, "Sessions: --continue (-c), --resume (-r), --session PATH|ID, --fork PATH|ID, --session-dir DIR, --no-session, --name NAME (-n). Set JF_SESSION_DIR to choose the default directory.")
    println(io, "Tools: --tools (-t) LIST, --exclude-tools (-xt) LIST, --no-builtin-tools (-nbt), --no-tools (-nt).")
    println(io, "Terminal: --tui-mode fullscreen|regular (default: fullscreen).")
    println(io, "Output: --mode text|json|rpc.")
    println(io, "Use @PATH to include a text file or image in the initial prompt.")
    println(io, "Models: --list-models [search] lists models for configured providers; --model accepts provider/model or a model name.")
    0
end

function helpmode(args)
    stop = something(findfirst(==("--"), args), length(args) + 1)
    positions = Dict(value => index for (index, value) in enumerate(@view args[1:stop-1]))
    index = get(positions, "--mode", nothing)
    helpmode(args, index, stop)
end
helpmode(args, ::Nothing, stop) = TextMode()
helpmode(args, index::Int, stop) = index + 1 < stop ? terminalmode(args[index+1]) : InvalidMode()
helpstream(::Union{JSONMode, RPCMode}) = stderr
helpstream(::TerminalMode) = stdout

include("cli_options.jl")

function (@main)(args)
    clifinal(foldl(cliargument, args; init=CLIReady(CLIOptions(helpstream(helpmode(args))))))
end

selectedmode(action, options, ::TerminalMode) = selectedtools(action, options, options.rules)
selectedmode(action, options, ::JSONMode) = headlessoutput(action, options)
selectedmode(action, options, ::RPCMode) = rpcauth(action, options, options.auth)
rpcauth(action, options, ::APIKeyAuth) = rpcaction(action, options)
function rpcauth(action, options, ::Union{OpenRouterAuth, ChatGPTAuth})
    println(stderr, "Interactive login is unavailable in RPC mode.")
    2
end
rpcaction(::Nothing, options) = rpcsession(options, options.session)
function rpcaction(action, options)
    println(stderr, "History inspection, abandonment and model listing are unavailable in RPC mode.")
    2
end
rpcsession(options, request::SessionCatalog.Request) = headlessoutput(nothing, options)
function rpcsession(options, ::SessionCatalog.Picker)
    println(stderr, "Interactive session selection is unavailable in RPC mode.")
    2
end
function headlessoutput(action, options)
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
    println(stderr, "--mode requires text or json or rpc.")
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
providerselection(action, options, ::Nothing) = customselection(action, options, modelconfig(ENV))
customselection(action, options, ::Models.InvalidConfig) = invalidmodelconfig()
customselection(action, options, registry::Models.Registry) = customselection(action, options, get(registry.providers, options.selected, nothing))
customselection(action, options, ::AbstractDict) = historyaction(action, options)
function customselection(action, options, ::Nothing)
    println(stderr, "Unknown provider; choose openai, openai-responses, openrouter, anthropic, or google.")
    2
end

historyaction(::Nothing, options) = loginprovider(options.auth, options.selected, options)
historyaction(action::ModelListing, options) = listmodels!(options.output, action.query, ENV)
loginprovider(::APIKeyAuth, selected, options) = resolveprovider(options, options.requested_model)
loginprovider(::APIKeyAuth, ::Nothing, options) = defaultchatgpt(options, stdin)
defaultchatgpt(options, input::IO) = resolveprovider(options, options.requested_model)
defaultchatgpt(options, input::Base.TTY) = defaultchatgpt(options, options.requested_model)
defaultchatgpt(options, ::Nothing) = defaultconfiguredchatgpt(options, modelconfig(ENV))
defaultconfiguredchatgpt(options, ::Models.InvalidConfig) = fallbackchatgpt(options)
defaultconfiguredchatgpt(options, registry::Models.Registry) = defaultconfiguredchatgpt(options, registry, get(registry.providers, "openai", nothing))
defaultconfiguredchatgpt(options, registry, ::Nothing) = fallbackchatgpt(options)
defaultconfiguredchatgpt(options, registry, settings::AbstractDict) = configureddefault(options, registry, configuredkey("openai", settings, providerinfo("openai"), ENV))
configureddefault(options, registry, ::Nothing) = configuredfallback(options, registry, get(ENV, "JF_PROVIDER", nothing))
configureddefault(options, registry, key::AbstractString) = configureddefaultkey(options, registry, envvalue(key))
configureddefaultkey(options, registry, ::Nothing) = configuredfallback(options, registry, get(ENV, "JF_PROVIDER", nothing))
configureddefaultkey(options, registry, key::AbstractString) = resolveprovider(options, options.requested_model, registry)
configuredfallback(options, registry, ::Nothing) = launchchatgpt(options, ResumeChatGPT())
configuredfallback(options, registry, selected::AbstractString) = resolveprovider(options, options.requested_model, registry)
defaultchatgpt(options, text::AbstractString) = configuredchatgpt(options, text, modelconfig(ENV))
configuredchatgpt(options, text, ::Models.InvalidConfig) = invalidmodelconfig()
function configuredchatgpt(options, text, registry::Models.Registry)
    result = Models.resolve(text, registry.models, usableproviders(ENV, registry))
    configuredchatgpt(options, registry, result)
end
configuredchatgpt(options, registry, result::Models.Resolution) = fallbackchatgpt(options)
configuredchatgpt(options, registry, result::Models.Resolved) = configuredchatgpt(options, registry, result, get(registry.providers, result.model.provider, nothing))
configuredchatgpt(options, registry, result, ::Nothing) = builtinchatgpt(options, registry, result, providerinfo(result.model.provider))
builtinchatgpt(options, registry, result, ::Nothing) = fallbackchatgpt(options)
builtinchatgpt(options, registry, result, info::NamedTuple) = configuredchatgpt(options, registry, result, envvalue(keyvalue(ENV, info)), info)
providerroute(options, registry, result, info) = resolveprovider(merge(options, (; modelconfig=registry)), result)
function configuredchatgpt(options, registry, result, settings::AbstractDict)
    builtin = catalogbuiltin(result.model.provider)
    key = configuredkey(result.model.provider, settings, builtin, ENV)
    configuredchatgpt(options, registry, result, key, builtin)
end
configuredchatgpt(options, registry, result, ::Nothing, builtin::NamedTuple) = get(missingbuiltinroutes, result.model.provider, providerroute)(options, registry, result, builtin)
configuredchatgpt(options, registry, result, key, builtin) = resolveprovider(merge(options, (; modelconfig=registry)), result)
missingopenai(options, registry, result, info) = fallbackchatgpt(options)
const missingbuiltinroutes = Dict("openai" => missingopenai)
function fallbackchatgpt(options)
    if !haskey(ENV, "JF_PROVIDER") && isempty(something(keyvalue(ENV, providerinfos["openai"]), ""))
        return launchchatgpt(options, ResumeChatGPT())
    end
    resolveprovider(options, options.requested_model)
end
loginprovider(::ChatGPTAuth, ::Nothing, options) = launchchatgpt(options, ChooseChatGPT())
function loginprovider(::ChatGPTAuth, selected::AbstractString, options)
    println(stderr, "--login-chatgpt cannot be combined with --provider.")
    2
end
loginprovider(::OpenRouterAuth, ::Nothing, options) = resolveprovider(options, options.requested_model)
loginprovider(::OpenRouterAuth, selected::AbstractString, options) = loginprovider(options, get(loginproviders, selected, nothing))
loginprovider(options, ::NamedTuple) = resolveprovider(options, options.requested_model)
function loginprovider(options, ::Nothing)
    println(stderr, "OpenRouter login requires --provider openrouter.")
    2
end
function launchprovider(options)
    (; auth, selected, requested_model, packages, environments, codemode, session, sessiondir, args, sessionname, baseline, rules, excluded, outputmode, output) = options
    name = providername(auth, selected)
    info = launchinfo(auth, options.modelconfig, name, requested_model, get(options, :catalog_provider, nothing))
    model = acquire(auth, info, requested_model, outputmode)
    model = applythinking(model, get(options, :thinking, nothing))
    Base.ScopedValues.with(tuimode => LiveTerminal.withprovider(options.tui, name)) do
        mode = thinkingmode(provider(outputmode, name), get(options, :requested_thinking, nothing))
        launch(output, model, packages, environments, codemode, session, sessiondir, args, sessionname, baseline, rules, excluded, mode)
    end
end
applythinking(model, ::Nothing) = model
applythinking(model::Integer, thinking::AbstractString) = model
applythinking(model::OpenAIResponses, thinking::AbstractString) = responselevel(model, model.model, thinking)
applythinking(model, thinking) = unsupportedthinking()
launchinfo(::APIKeyAuth, registry::Models.Registry, name, model, ::Nothing) = configuredinfo(registry, name, model, ENV)
launchinfo(::APIKeyAuth, registry::Models.Registry, name, model, provider::AbstractString) = configuredinfo(registry, name, model, ENV, provider)
launchinfo(::OpenRouterAuth, registry::Models.Registry, name, model, provider) = providerinfo(name)

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

initial(extensions) = initial(extensions, Skills.load(pwd()))
function initial(extensions, skills::Vector{Skills.Skill})
    cwd = pwd()
    files = Instructions.load(cwd; agentdir=get(ENV, "JF_INSTRUCTIONS_DIR", nothing))
    prompt = context(cwd, Extensions.tools(extensions), files)
    messages = Conversation.Message[Conversation.RawMessage(Dict("role" => "system", "content" => prompt))]
    Skills.appendprompt!(messages, Skills.render(skills))
    messages
end

selection(result::ToolFailure) = SessionCatalog.Invalid(result.text)
selection(result) = result

function terminal!(terminal::Terminal, model, registry::Extensions.Registry, ::Type{CodeMode}, session, sessiondir, args, sessionname, baseline, rules, excluded)
    mode = CodeMode(Extensions.tools(Extensions.snapshot(registry)))
    result = Extensions.register!(registry, gensym(:codemode), Extensions.Plugin(; tools=(mode,)))
    terminal!(terminal, model, registered(terminal, registry, "codemode", result), nothing, session, sessiondir, args, sessionname, baseline, rules, excluded)
end
function terminal!(terminal::Terminal, model, registry::Extensions.Registry, ::Nothing, session, sessiondir, args, sessionname, baseline, rules, excluded)
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
preparesession!(snapshot, terminal, model, extensions, store, args, sessiondir, sessionname) = startsession!(terminal, model, extensions, store, args, sessiondir, sessionname, attempt(() -> startup(extensions, snapshot)))

function startup(extensions, ::Nothing)
    skills = Skills.load(pwd())
    (; messages=initial(extensions, skills), skills)
end
startup(extensions, snapshot::History.Snapshot) = iszero(snapshot.revision) ? startup(extensions, nothing) : (; messages=Dict{String, Any}[], skills=nothing)

closehistory!(::Nothing) = nothing
closehistory!(history::History.Store) = close(history)

function startsession!(terminal, model, extensions, store, args, sessiondir, sessionname, failure::ToolFailure)
    println(terminal.diagnostics, "Failed to initialize project context: ", redact(terminal, failure.text))
    flush(terminal.diagnostics)
    1
end

function startsession!(terminal, model, extensions, store, args, sessiondir, sessionname, prepared::NamedTuple)
    agent = Agent(model, extensions, prepared.messages; history=store[])
    startagent!(terminal, agent, extensions, store, args, sessiondir, sessionname, prepared.skills)
end

startagent!(terminal, rejected::History.Rejected, extensions, store, args, sessiondir, sessionname, skills) = result!(terminal, rejected)
startagent!(terminal, agent::Agent, extensions, store, args, sessiondir, sessionname, skills) = startagent!(terminal, agent, extensions, store, args, sessiondir, sessionname, skills, agent.fault)
startagent!(terminal, agent, extensions, store, args, sessiondir, sessionname, skills, fault::History.Rejected) = sessionfault!(terminal, fault, store[])
function startagent!(terminal, agent, extensions, store, args, sessiondir, sessionname, skills, ::Nothing)
    startsession!(terminal, agent, extensions, store, args, sessiondir, sessionname, skills, checkqueues!(terminal, agent.state, store[]))
end

startsession!(terminal, agent, extensions, store, args, sessiondir, sessionname, skills, ::PendingInputs) = 1

startsession!(terminal, agent, extensions, store, args, sessiondir, sessionname, skills, ::Nothing) = startnamed!(terminal, agent, extensions, store, args, sessiondir, skills, startname!(agent, sessionname))
startname!(agent, ::Nothing) = nothing
startname!(agent, name::String) = name!(agent, name)
startnamed!(terminal, agent, extensions, store, args, sessiondir, skills, rejected::History.Rejected) = result!(terminal, rejected)
startnamed!(terminal, agent, extensions, store, args, sessiondir, skills, ::Nothing) = starttemplates!(terminal, agent, extensions, store, args, sessiondir, attempt(() -> Skills.Resources(Prompts.load(pwd()), currentskills(skills))))
currentskills(::Nothing) = Skills.load(pwd())
currentskills(skills::Vector{Skills.Skill}) = skills

function starttemplates!(terminal, agent, extensions, store, args, sessiondir, failure::ToolFailure)
    println(terminal.diagnostics, "Failed to load prompt templates or skills: ", redact(terminal, failure.text))
    flush(terminal.diagnostics)
    1
end

function starttemplates!(terminal, agent, extensions, store, args, sessiondir, templates::Union{AbstractDict, Skills.Resources})
    starttemplates!(terminal, agent, extensions, store, args, sessiondir, templates, terminal.mode)
end

function starttemplates!(terminal, agent, extensions, store, args, sessiondir, templates::Union{AbstractDict, Skills.Resources}, ::TextMode)
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
readcommand!(terminal, agent, extensions, history, line, input, sessiondir, templates, command::Union{ReloadCommand, NewCommand}) = command!(command, terminal, agent, history, input, sessiondir, extensions, Ref(""), templates)
readcommand!(terminal, agent, extensions, history, line, input, sessiondir, templates, command::TerminalCommand) = command!(command, terminal, agent, history, input, sessiondir, extensions)

include("live_json.jl")
include("session_export.jl")
include("headless.jl")
starttemplates!(terminal, agent, extensions, store, args, sessiondir, templates::Union{AbstractDict, Skills.Resources}, ::RPCMode) = Headless.rpc!(terminal, agent, extensions, store, args, sessiondir, templates)

end
