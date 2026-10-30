mutable struct CLIOptions
    codemode
    packages::Vector{String}
    environments::Vector{String}
    action
    selected
    requested_model
    auth
    session
    sessiondir
    sessionname
    args::Vector{String}
    baseline
    rules
    excluded::Vector{Regex}
    tui
    outputmode
end

CLIOptions() = CLIOptions(nothing, String[], String[], nothing, nothing, nothing, APIKeyAuth(), SessionCatalog.New(), SessionCatalog.directory(ENV), nothing, String[], ToolSelection.Defaults(), ToolSelection.Inherit(), Regex[], LiveTerminal.FullscreenMode(), TextMode())

struct CLIReady
    options::CLIOptions
end
struct CLIValue{F, V}
    options::CLIOptions
    action::F
    valid::V
    message::String
end
struct CLIModelQuery
    options::CLIOptions
end
struct CLIRest
    options::CLIOptions
end
struct CLIStopped
    status::Int
end

function clierror(message)
    println(stderr, message)
    CLIStopped(2)
end

clivalue(action, valid, message) = (state, option) -> CLIValue(state.options, action, valid, message(option))
clirequired(action, valid) = clivalue(action, valid, option -> "$option requires a value.")
clituivalue(value) = haskey(tuimodes, value)
climodevalue(value) = !startswith(value, "-")
cliprovidervalue(value) = !isempty(strip(value)) && !startswith(value, "--")
clioptionvalue(value) = !isempty(value) && !startswith(value, "--")
clipathvalue(value) = !startswith(value, "--")
clinamevalue(value) = !isempty(Conversation.sessionname(value))

cliargument(state::CLIValue, value) = cliargument(state, value, state.valid)
function cliargument(state::CLIValue, value, valid)
    valid(value) || return clierror(state.message)
    cliargument(state, value, nothing)
end
function cliargument(state::CLIValue, value, ::Nothing)
    state.action(state.options, value)
    CLIReady(state.options)
end

function cliargument(state::CLIRest, value)
    push!(state.options.args, value)
    state
end
cliargument(state::CLIStopped, value) = state
cliargument(state::CLIReady, value) = get(cliactions, value, clipositional!)(state, value)
function cliargument(state::CLIModelQuery, value)
    (startswith(value, "-") || startswith(value, "@")) && return cliargument(CLIReady(state.options), value)
    state.options.action = ModelListing(value)
    CLIReady(state.options)
end

function clipositional!(state, value)
    push!(state.options.args, value)
    state
end
function clirest!(state, value)
    push!(state.options.args, value)
    CLIRest(state.options)
end
clihelp!(state, value) = CLIStopped(help!())
clicode!(state, value) = (state.options.codemode = CodeMode; state)
cliexcludeall!(state, value) = (state.options.baseline = ToolSelection.baseline(state.options.baseline, ToolSelection.NoTools()); state)
cliexcludebuiltin!(state, value) = (state.options.baseline = ToolSelection.baseline(state.options.baseline, ToolSelection.NoBuiltin()); state)
clicontinue!(state, value) = (state.options.session = SessionCatalog.assign(state.options.session, SessionCatalog.Recent()); state)
cliresume!(state, value) = (state.options.session = SessionCatalog.assign(state.options.session, SessionCatalog.Picker()); state)
cliephemeral!(state, value) = (state.options.session = SessionCatalog.assign(state.options.session, SessionCatalog.Ephemeral()); state)
cliinspect!(state, value) = (state.options.action = historyinspect(state.options.action); state)
climodels!(state, value) = (state.options.action = ModelListing(""); CLIModelQuery(state.options))

clilogin(state, auth) = clilogin(state, state.options.auth, auth)
clilogin(state, ::APIKeyAuth, auth::OpenRouterAuth) = (state.options.auth = auth; state)
clilogin(state, ::OpenRouterAuth, auth) = clierror("Select only one OpenRouter login mode.")

settui!(options, value) = (options.tui = tuimodes[value]; nothing)
setmode!(options, value) = (options.outputmode = assignmode(options.outputmode, terminalmode(value)); nothing)
settools!(options, value) = (options.rules = ToolSelection.assign(options.rules, ToolSelection.entries(value)); nothing)
setexcluded!(options, value) = (options.excluded = ToolSelection.patterns(value); nothing)
setprovider!(options, value) = (options.selected = lowercase(value); nothing)
setmodel!(options, value) = (options.requested_model = value; nothing)
setplugin!(options, value) = (push!(options.packages, value); nothing)
setenvironment!(options, value) = (push!(options.environments, value); nothing)
sethistory!(options, value) = (options.session = SessionCatalog.assign(options.session, SessionCatalog.Explicit(value)); nothing)
setsession!(options, value) = (options.session = SessionCatalog.assign(options.session, SessionCatalog.Target(value)); nothing)
setfork!(options, value) = (options.session = SessionCatalog.assign(options.session, SessionCatalog.Fork(value)); nothing)
setsessiondir!(options, value) = (options.sessiondir = abspath(expanduser(value)); nothing)
setname!(options, value) = (options.sessionname = Conversation.sessionname(value); nothing)
setabandon!(options, value) = (options.action = historyabandon(options.action, value); nothing)

const clituioption = clivalue(settui!, clituivalue, option -> "--tui-mode requires regular or fullscreen.")
const climodeoption = clivalue(setmode!, climodevalue, option -> "--mode requires text or json.")
const clitoolsoption = clirequired(settools!, nothing)
const cliexcludeoption = clirequired(setexcluded!, nothing)
const clinameoption = clivalue(setname!, clinamevalue, option -> "--name requires a non-empty value.")
const cliactions = Dict{String, Function}(
    "--" => clirest!, "--help" => clihelp!, "-h" => clihelp!,
    "--codemode" => clicode!, "--mode" => climodeoption, "--tui-mode" => clituioption,
    "--no-tools" => cliexcludeall!, "-nt" => cliexcludeall!,
    "--no-builtin-tools" => cliexcludebuiltin!, "-nbt" => cliexcludebuiltin!,
    "--tools" => clitoolsoption, "-t" => clitoolsoption,
    "--exclude-tools" => cliexcludeoption, "-xt" => cliexcludeoption,
    "--list-models" => climodels!,
    "--provider" => clirequired(setprovider!, cliprovidervalue),
    "--model" => clirequired(setmodel!, cliprovidervalue),
    "--login-openrouter" => (state, option) -> clilogin(state, CodeAuth()),
    "--login-openrouter-callback" => (state, option) -> clilogin(state, CallbackAuth()),
    "--plugin" => clivalue(setplugin!, clioptionvalue, option -> "$option requires a package name."),
    "--plugin-env" => clivalue(setenvironment!, clioptionvalue, option -> "$option requires a path."),
    "--history" => clivalue(sethistory!, clipathvalue, option -> "--history requires a path."),
    "--session" => clirequired(setsession!, clioptionvalue),
    "--session-dir" => clirequired(setsessiondir!, clioptionvalue),
    "--fork" => clirequired(setfork!, clioptionvalue),
    "--continue" => clicontinue!, "-c" => clicontinue!,
    "--resume" => cliresume!, "-r" => cliresume!,
    "--no-session" => cliephemeral!, "--name" => clinameoption, "-n" => clinameoption,
    "--abandon" => clivalue(setabandon!, clioptionvalue, option -> "--abandon requires a reason."),
    "--inspect-history" => cliinspect!,
)

clifinal(state::CLIReady) = clifinal(state.options)
clifinal(state::CLIRest) = clifinal(state.options)
clifinal(state::CLIModelQuery) = clifinal(state.options)
clifinal(state::CLIValue) = clifinal(clierror(state.message))
clifinal(state::CLIStopped) = state.status
function clifinal(options::CLIOptions)
    (; codemode, packages, environments, action, selected, requested_model, auth, session, sessiondir, sessionname, args, baseline, rules, excluded, tui, outputmode) = options
    values = (; auth, selected, requested_model, packages, environments, codemode, session, sessiondir, args, sessionname, baseline, rules, excluded, tui, outputmode, output=stdout)
    selectedmode(action, values, outputmode)
end
