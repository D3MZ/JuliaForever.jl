openrouterdirectory(env) = abspath(expanduser(get(env, "JF_OPENROUTER_DIR", joinpath(homedir(), ".config", "juliaforever", "openrouter"))))

struct UnavailableOpenRouter end
struct OpenRouterSaved end
struct OpenRouterSaveFailure end

readroutercredential(pi, env, info) = readroutercredential(pi, readopenrouter(env))
readroutercredential(pi, ::Nothing) = get(pi, "openrouter", nothing)
readroutercredential(pi, ::UnavailableOpenRouter) = Dict("type" => "unavailable")
readroutercredential(pi, key::AbstractString) = Dict("type" => "api_key", "key" => key)
const credentialreaders = Dict("OPENROUTER_API_KEY" => readroutercredential)

function readopenrouter(env)
    Sys.isunix() || return nothing
    directory = openrouterdirectory(env)
    (ispath(directory) || islink(directory)) || return nothing
    try
        readopenrouter(ChatGPT.Store(directory))
    catch
        UnavailableOpenRouter()
    end
end
readopenrouter(::ChatGPT.Rejected) = UnavailableOpenRouter()
function readopenrouter(store::ChatGPT.Store)
    path = joinpath(store.root, "key")
    islink(path) && return UnavailableOpenRouter()
    readopenrouterfile(ChatGPT.readprivate(path))
end
readopenrouterfile(rejected::ChatGPT.Rejected) = get(Dict(:missing => nothing), rejected.reason, UnavailableOpenRouter())
readopenrouterfile(key::AbstractString) = isempty(key) ? UnavailableOpenRouter() : key

function rememberopenrouter(key, env)
    try
        rememberopenrouter(ChatGPT.Store(openrouterdirectory(env)), key)
    catch
        OpenRouterSaveFailure()
    end
end
rememberopenrouter(::ChatGPT.Rejected, key) = OpenRouterSaveFailure()
function rememberopenrouter(store::ChatGPT.Store, key)
    ChatGPT.guarded(store) do
        path = joinpath(store.root, "key")
        islink(path) && return OpenRouterSaveFailure()
        ChatGPT.writeprivate(path, key)
        OpenRouterSaved()
    end
end
reportremembered(::OpenRouterSaved) = nothing
reportremembered(value) = println(stderr, "OpenRouter login is available for this session only; its key could not be saved.")

struct OpenRouterLogout end
struct OpenRouterForgotten end
struct OpenRouterForgetFailure end
routerlogoutaction(::Nothing) = OpenRouterLogout()
routerlogoutaction(action) = HistoryConflict()
historyinspect(::OpenRouterLogout) = HistoryConflict()
historyabandon(::OpenRouterLogout, reason) = HistoryConflict()
historyaction(::OpenRouterLogout, options) = routerlogoutrequest(options.auth, options)
routerlogoutrequest(auth, options) = invalidrouterlogout()
function routerlogoutrequest(::APIKeyAuth, options)
    isempty(options.args) || return invalidrouterlogout()
    result = try
        forgetopenrouter(ChatGPT.Store(openrouterdirectory(ENV)))
    catch
        OpenRouterForgetFailure()
    end
    reportforgotten(result)
end
invalidrouterlogout() = (println(stderr, "--logout-openrouter takes no prompt or login option."); 2)
forgetopenrouter(::ChatGPT.Rejected) = OpenRouterForgetFailure()
function forgetopenrouter(store::ChatGPT.Store)
    ChatGPT.guarded(store) do
        path = joinpath(store.root, "key")
        islink(path) && return OpenRouterForgetFailure()
        forgetopenrouter(store, path, ChatGPT.readprivate(path))
    end
end
forgetopenrouter(store, path, rejected::ChatGPT.Rejected) = get(Dict(:missing => OpenRouterForgotten()), rejected.reason, OpenRouterForgetFailure())
function forgetopenrouter(store, path, key::AbstractString)
    rm(path)
    ChatGPT.syncdirectory(path)
    OpenRouterForgotten()
end
reportforgotten(value) = (println(stderr, "Could not remove the saved OpenRouter login."); 2)
reportforgotten(::OpenRouterForgotten) = (println(stderr, "Removed Julia Forever's OpenRouter login. Pi or environment credentials may still be used; revoke the key in OpenRouter settings if needed."); 0)
