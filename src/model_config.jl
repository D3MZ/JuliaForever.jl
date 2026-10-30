struct ConfiguredProvider{S, I}
    name::String
    settings::S
    builtin::I
    id::Union{Nothing, String}
    model::Union{Nothing, Models.Model}
    registry::Models.Registry
end

Base.show(io::IO, ::ConfiguredProvider) = print(io, "Configured provider ([redacted])")
StructTypes.StructType(::Type{<:ConfiguredProvider}) = StructTypes.CustomStruct()
StructTypes.lower(::ConfiguredProvider) = "[redacted]"

const configtokens = r"\$(?:\$|!|\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*)"
const configliterals = Dict("\$\$" => "\$", "\$!" => "!")

configpath(env) = joinpath(get(env, "PI_CODING_AGENT_DIR", joinpath(homedir(), ".pi", "agent")), "models.json")
modelconfig(env) = Models.load(configpath(env))

function configvalue(value::AbstractString, env)
    startswith(value, "!") && return nothing
    output = IOBuffer()
    start = firstindex(value)
    for token in eachmatch(configtokens, value)
        output = appendvalue!(output, value[start:prevind(value, token.offset)])
        output = appendvalue!(output, configtoken(token.match, env))
        start = nextind(value, token.offset, length(token.match))
    end
    finishvalue(appendvalue!(output, value[start:end]))
end
configvalue(value, env) = nothing
appendvalue!(::Nothing, value) = nothing
appendvalue!(output::IOBuffer, ::Nothing) = nothing
appendvalue!(output::IOBuffer, value::AbstractString) = (write(output, value); output)
finishvalue(::Nothing) = nothing
finishvalue(output::IOBuffer) = String(take!(output))

configtoken(token, env) = configtoken(token, env, get(configliterals, token, nothing))
configtoken(token, env, literal::String) = literal
function configtoken(token, env, ::Nothing)
    name = token[nextind(token, firstindex(token)):end]
    name = startswith(name, "{") ? name[nextind(name, firstindex(name)):prevind(name, lastindex(name))] : name
    envvalue(get(env, name, nothing))
end
envvalue(::Nothing) = nothing
envvalue(value::AbstractString) = isempty(value) ? nothing : String(value)

configuredkey(name, settings, builtin, env) = configcredential(storedmodelkey(name, builtin, env), get(settings, "apiKey", nothing), builtin, env)
storedmodelkey(name, ::Nothing, env) = get(storedcredentials(env), name, nothing)
function storedmodelkey(name, builtin::NamedTuple, env)
    get(credentialreaders, builtin.key, readpicredential)(storedcredentials(env), env, builtin)
end
configcredential(::Nothing, ::Nothing, ::Nothing, env) = nothing
configcredential(::Nothing, ::Nothing, builtin::NamedTuple, env) = get(env, builtin.key, "")
configcredential(::Nothing, value::AbstractString, builtin, env) = configvalue(value, env)
configcredential(::Nothing, value, builtin, env) = nothing
configcredential(value::AbstractDict, fallback, builtin, env) = get(credentialhandlers, get(value, "type", ""), unsupportedcredential)(value, env)
configcredential(value, fallback, builtin, env) = nothing
storedkey(value, env) = configvalue(get(value, "key", nothing), env)
unsupportedcredential(value, env) = nothing
const credentialhandlers = Dict("api_key" => storedkey)

requestedid(model::AbstractString, builtin, env) = String(model)
requestedid(::Nothing, ::Nothing, env) = nothing
requestedid(::Nothing, builtin::NamedTuple, env) = envvalue(get(env, builtin.model, nothing))

catalogbuiltin(name) = catalogbuiltin(name, name)
catalogbuiltin(name, provider) = catalogbuiltinfrom(name, get(modelconstraints, provider, nothing))
catalogbuiltinfrom(name, ::Nothing) = providerinfo(name)
catalogbuiltinfrom(name, ::AbstractString) = nothing
catalogprovider(registry::Models.Registry, name::AbstractString) = catalogprovider(name, get(registry.providers, name, nothing))
catalogprovider(name, ::Nothing) = get(modelconstraints, name, name)
catalogprovider(name, ::AbstractDict) = name

configuredinfo(registry::Models.Registry, name, model, env) = configuredinfo(registry, name, model, env, catalogprovider(registry, name))
function configuredinfo(registry::Models.Registry, name, model, env, provider)
    builtin = catalogbuiltin(name, provider)
    settings = get(registry.providers, provider, nothing)
    configuredinfo(registry, provider, model, env, builtin, settings)
end
configuredinfo(registry, name, model, env, builtin, ::Nothing) = builtin
function configuredinfo(registry, name, model, env, builtin, settings::AbstractDict)
    id = requestedid(model, builtin, env)
    selected = Models.findmodel(candidate -> candidate.provider == name && candidate.id == id, registry.models)
    ConfiguredProvider(name, settings, builtin, id, selected, registry)
end

definition(settings::AbstractDict, id) = definition(get(settings, "models", []), id)
function definition(definitions::AbstractVector, id)
    Models.item(definitions, findfirst(model -> get(model, "id", nothing) == id, definitions))
end
definition(settings::AbstractDict, ::Nothing) = nothing
effective(settings::AbstractDict, id) = get(Dict(model["id"] => model for model in get(settings, "models", [])), id, nothing)
effective(settings::AbstractDict, ::Nothing) = nothing
definitionvalue(::Nothing, field, fallback) = fallback
definitionvalue(definition::AbstractDict, field, fallback) = get(definition, field, fallback)
modeloverride(settings, id) = get(get(settings, "modelOverrides", Dict()), id, Dict())

builtinbase(::Nothing, env) = nothing
builtinbase(info::NamedTuple, env) = get(env, info.base, info.url)
function modelbase(provider::ConfiguredProvider, env)
    base = get(provider.settings, "baseUrl", builtinbase(provider.builtin, env))
    providers = foldl(groupmodel!, Models.catalog(); init=Dict{String, Vector{Models.Model}}())
    builtin = get(providers, provider.name, Models.Model[])
    routes = Dict{String, NamedTuple}(model.id => (; id=model.id, api=model.api, base) for model in builtin)
    ids = [model.id for model in builtin]
    foldl((state, model) -> route!(state, model, provider.settings), get(provider.settings, "models", []); init=(routes, ids))
    routebase(get(routes, provider.id, nothing), base)
end
groupmodel!(providers, model) = (push!(get!(providers, model.provider, Models.Model[]), model); providers)
routebase(::Nothing, fallback) = fallback
routebase(route::NamedTuple, fallback) = route.base
routeapi(::Nothing) = ""
routeapi(route::NamedTuple) = route.api
routebase(::Nothing) = nothing
routebase(route::NamedTuple) = route.base

function route!(state, definition, settings)
    routes, ids = state
    id = String(definition["id"])
    existing = get(routes, id, nothing)
    candidates = [routes[name] for name in ids]
    api = get(definition, "api", get(settings, "api", ""))
    defaults = routedefault(existing, candidates, api)
    api = String(get(definition, "api", get(settings, "api", routeapi(defaults))))
    base = get(definition, "baseUrl", get(settings, "baseUrl", routebase(defaults)))
    routes[id] = (; id, api, base)
    addroute!(ids, existing, id)
    state
end
addroute!(ids, ::Nothing, id) = (push!(ids, id); nothing)
addroute!(ids, existing::NamedTuple, id) = nothing
routedefault(existing::NamedTuple, routes, api) = existing
routedefault(::Nothing, routes, api) = routedefault(Models.findmodel(route -> route.api == api, routes), routes)
routedefault(existing::NamedTuple, routes) = existing
routedefault(::Nothing, routes) = routedefault(Models.findmodel(route -> route.api == "openai-completions", routes), routes, nothing)
routedefault(existing::NamedTuple, routes, ::Nothing) = existing
routedefault(::Nothing, routes, ::Nothing) = get(routes, 1, nothing)

const builtinapis = IdDict(openai => "openai-completions", responses => "openai-responses", anthropic => "anthropic-messages", google => "google-generative-ai")
modelapi(provider::ConfiguredProvider) = modelapi(provider.model, provider)
modelapi(model::Models.Model, provider) = model.api
modelapi(::Nothing, provider) = fallbackapi(provider.builtin, provider.settings)
fallbackapi(::Nothing, settings) = get(settings, "api", "")
fallbackapi(info::NamedTuple, settings) = get(settings, "api", get(builtinapis, info.factory, ""))

const modelapis = Dict("openai-completions" => OpenAI, "openai-responses" => OpenAIResponses, "anthropic-messages" => Anthropic, "google-generative-ai" => Google)
const unsupportedmodelsettings = ("compat", "samplingParams", "samplingParamsByThinkingLevel", "thinkingLevelMap", "promptCache", "inputLimits")
supportedsettings(settings::AbstractDict) = Models.check(all(key -> !haskey(settings, key), unsupportedmodelsettings))
supportedsettings(::Nothing) = Models.ValidConfig()
function supportedsettings(provider::ConfiguredProvider)
    Models.combine(supportedsettings(provider.settings), supportedsettings(effective(provider.settings, provider.id)), supportedsettings(modeloverride(provider.settings, provider.id)), Models.check(!haskey(provider.settings, "oauth")))
end

function configheaders(provider::ConfiguredProvider, env, key)
    defined = definition(provider.settings, provider.id)
    overrides = modeloverride(provider.settings, provider.id)
    headers = configheaders!(Pair{String, String}[], get(provider.settings, "headers", Dict()), env)
    headers = get(authheaderhandlers, get(provider.settings, "authHeader", false), invalidauthheader)(headers, key)
    modelheaders!(headers, get(overrides, "headers", Dict()), definitionvalue(defined, "headers", Dict()), env)
end
modelheaders!(headers, overrides, defined, env) = nothing
function modelheaders!(headers::Vector{Pair{String, String}}, overrides::AbstractDict, defined::AbstractDict, env)
    values = merge(overrides, defined)
    names = unique([collect(keys(overrides)); collect(keys(defined))])
    foldl((current, name) -> configheader!(current, name, configvalue(values[name], env)), names; init=headers)
end
authheader!(headers, key) = configheader!(headers, "Authorization", authvalue(key))
noauthheader!(headers, key) = headers
invalidauthheader(headers, key) = nothing
authvalue(::Nothing) = nothing
authvalue(key::AbstractString) = "Bearer " * key
const authheaderhandlers = Dict(true => authheader!, false => noauthheader!)
configheaders!(::Nothing, raw, env) = nothing
configheaders!(headers, raw, env) = nothing
function configheaders!(headers::Vector{Pair{String, String}}, raw::AbstractDict, env)
    foldl((current, pair) -> configheader!(current, first(pair), configvalue(last(pair), env)), pairs(raw); init=headers)
end
configheader!(::Nothing, name, value) = nothing
configheader!(headers::Vector{Pair{String, String}}, name, ::Nothing) = nothing
configheader!(headers::Vector{Pair{String, String}}, name, value::AbstractString) = (push!(headers, String(name) => String(value)); headers)

acquire(auth::APIKeyAuth, provider::ConfiguredProvider, model) = acquire(auth, provider, model, supportedsettings(provider))
acquire(auth::APIKeyAuth, provider::ConfiguredProvider, model, ::Models.InvalidConfig) = invalidmodelconfig()
function acquire(::APIKeyAuth, provider::ConfiguredProvider, model, ::Models.ValidConfig)
    key = configuredkey(provider.name, provider.settings, provider.builtin, ENV)
    headers = configheaders(provider, ENV, key)
    base = modelbase(provider, ENV)
    factory = get(modelapis, modelapi(provider), nothing)
    configuredmodel(factory, base, provider.id, key, headers, CatalogRoute(provider.name, provider.registry), provider, ENV)
end
configuredmodel(factory, base, id, key::AbstractString, headers, route, provider, env) = configuredmodel(factory, base, id, key, headers, route)
function configuredmodel(factory, base, id, ::Nothing, headers, route, provider, env)
    keylessmodel(factory, base, id, headers, route, provider.builtin, get(provider.settings, "apiKey", nothing), storedmodelkey(provider.name, provider.builtin, env))
end
keylessmodel(factory, base, id, headers, route, builtin, configured, stored) = invalidmodelconfig()
function keylessmodel(factory::Type, base::AbstractString, id::AbstractString, headers::Vector{Pair{String, String}}, route::CatalogRoute, ::Nothing, ::Nothing, ::Nothing)
    isempty(base) && return invalidmodelconfig()
    isempty(id) && return invalidmodelconfig()
    requestauth(factory, headers) || return invalidmodelconfig()
    factory(String(base), String(id), "", headers, route)
end
requestauth(factory, headers) = false
requestauth(::Type{OpenAI}, headers) = hasrequestheader(headers, ("authorization", "cf-aig-authorization"))
requestauth(::Type{OpenAIResponses}, headers) = hasrequestheader(headers, ("authorization", "cf-aig-authorization"))
requestauth(::Type{Anthropic}, headers) = hasrequestheader(headers, ("authorization", "x-api-key", "cf-aig-authorization"))
hasrequestheader(headers, names) = any(pair -> lowercase(first(pair)) in names && !isempty(strip(last(pair))), mergeheaders(Pair{String, String}[], headers))
configuredmodel(factory, base, id, key, headers, route) = invalidmodelconfig()
function configuredmodel(factory::Type, base::AbstractString, id::AbstractString, key::AbstractString, headers::Vector{Pair{String, String}}, route::CatalogRoute)
    isempty(base) && return invalidmodelconfig()
    isempty(id) && return invalidmodelconfig()
    isempty(key) && return invalidmodelconfig()
    factory(String(base), String(id), String(key), headers, route)
end
function invalidmodelconfig()
    println(stderr, "Model configuration is invalid, unsupported, or missing credentials.")
    2
end

modelcatalog(provider) = Models.catalog()
modelcatalog(provider::Union{OpenAI, OpenAIResponses, Anthropic, Google}) = modelcatalog(provider.route)
modelcatalog(::DirectRoute) = Models.catalog()
modelcatalog(route::CatalogRoute) = route.registry.models
modelcatalogname(provider, fallback) = modelconstraint(fallback)
modelcatalogname(provider::Union{OpenAI, OpenAIResponses, Anthropic, Google}, fallback) = modelcatalogname(provider.route, fallback)
modelcatalogname(route::CatalogRoute, fallback) = route.name

modelchange(provider, model, ::DirectRoute) = typeof(provider)(provider.base, String(model), provider.key, provider.extra, provider.route)
modelchange(provider::OpenAIResponses, model, ::DirectRoute) = responsechange(provider, model, Models.suffix(model))
responsechange(provider, model, suffix::Models.Suffix) = responsesuffix(provider, suffix, get(responselevels, suffix.base, nothing))
responsesuffix(provider, suffix, ::Nothing) = unsupportedthinking()
responsesuffix(provider, suffix, levels::AbstractDict) = responsesuffix(provider, suffix, levels, thinkingwire(levels))
responsesuffix(provider, suffix, levels, ::DirectThinking) = unsupportedthinking()
responsesuffix(provider, suffix, levels, ::UpdateThinking) = responselevel(provider, suffix.base, get(levels, suffix.thinking, nothing), levels)
responsechange(provider, model, ::Nothing) = responselevel(provider, model, provider.thinking)
responselevel(provider, model, ::Nothing) = OpenAIResponses(provider.base, String(model), provider.key, provider.extra, provider.route)
responselevel(provider, model, effort::AbstractString) = responselevel(provider, model, effort, get(responselevels, model, nothing))
responselevel(provider, model, effort, ::Nothing) = unsupportedthinking()
responselevel(provider, model, ::Nothing, levels::AbstractDict) = unsupportedthinking()
responselevel(provider, model, effort, levels::AbstractDict) = responselevel(provider, model, effort, Models.combine(Models.check(effort in values(levels)), supportedthinking(thinkingwire(levels), effort), authorizedthinking(thinkingwire(levels), provider, effort)))
responselevel(provider, model, effort, ::Models.InvalidConfig) = unsupportedthinking()
responselevel(provider, model, effort, ::Models.ValidConfig) = OpenAIResponses(provider.base, String(model), provider.key, provider.extra, provider.route, effort)
authorizedthinking(::DirectThinking, provider, effort) = Models.ValidConfig()
authorizedthinking(::UpdateThinking, provider, effort) = authorizedthinking(provider.route, provider, effort)
authorizedthinking(::CatalogRoute, provider, effort) = Models.check(effort == "none")
authorizedthinking(::DirectRoute, provider, effort) = Models.check(effort == "none" || (!responsesignin(provider) && !responseauthoverride(provider)))
function modelchange(provider, model, route::CatalogRoute)
    configured = configuredinfo(route.registry, route.name, model, ENV)
    modelchange(configured, model, configured.model)
end
modelchange(configured, model, ::Nothing) = invalidmodelconfig()
modelchange(configured, model, ::Models.Model) = acquire(APIKeyAuth(), configured, model)
