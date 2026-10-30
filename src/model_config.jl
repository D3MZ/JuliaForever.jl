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

configuredkey(name, settings, builtin, env) = configcredential(get(storedcredentials(env), name, nothing), get(settings, "apiKey", nothing), builtin, env)
configcredential(::Nothing, ::Nothing, ::Nothing, env) = nothing
configcredential(::Nothing, ::Nothing, builtin::NamedTuple, env) = keyvalue(env, builtin)
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

function configuredinfo(registry::Models.Registry, name, model, env)
    builtin = providerinfo(name)
    provider = get(modelconstraints, name, name)
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
definitionvalue(::Nothing, field, fallback) = fallback
definitionvalue(definition::AbstractDict, field, fallback) = get(definition, field, fallback)
modeloverride(settings, id) = get(get(settings, "modelOverrides", Dict()), id, Dict())

builtinbase(::Nothing, env) = nothing
builtinbase(info::NamedTuple, env) = get(env, info.base, info.url)
function modelbase(provider::ConfiguredProvider, env)
    base = get(provider.settings, "baseUrl", builtinbase(provider.builtin, env))
    definitionvalue(definition(provider.settings, provider.id), "baseUrl", base)
end

const defaultapis = Dict("openai" => "openai-completions", "openai-responses" => "openai-responses", "openrouter" => "openai-completions", "anthropic" => "anthropic-messages", "google" => "google-generative-ai")
modelapi(provider::ConfiguredProvider) = modelapi(provider.model, provider)
modelapi(model::Models.Model, provider) = model.api
modelapi(::Nothing, provider) = get(provider.settings, "api", get(defaultapis, provider.name, ""))

const modelapis = Dict("openai-completions" => OpenAI, "openai-responses" => OpenAIResponses, "anthropic-messages" => Anthropic, "google-generative-ai" => Google)
const unsupportedmodelsettings = ("compat", "samplingParams", "samplingParamsByThinkingLevel", "thinkingLevelMap", "promptCache", "inputLimits")
supportedsettings(settings::AbstractDict) = Models.check(all(key -> !haskey(settings, key), unsupportedmodelsettings))
supportedsettings(::Nothing) = Models.ValidConfig()
function supportedsettings(provider::ConfiguredProvider)
    Models.combine(supportedsettings(provider.settings), supportedsettings(definition(provider.settings, provider.id)), supportedsettings(modeloverride(provider.settings, provider.id)), Models.check(!haskey(provider.settings, "oauth")))
end

function configheaders(provider::ConfiguredProvider, env, key)
    defined = definition(provider.settings, provider.id)
    overrides = modeloverride(provider.settings, provider.id)
    headers = configheaders!(Pair{String, String}[], get(provider.settings, "headers", Dict()), env)
    headers = get(authheaderhandlers, get(provider.settings, "authHeader", false), invalidauthheader)(headers, key)
    headers = configheaders!(headers, get(overrides, "headers", Dict()), env)
    configheaders!(headers, definitionvalue(defined, "headers", Dict()), env)
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
    configuredmodel(factory, base, provider.id, key, headers, CatalogRoute(provider.name, provider.registry))
end
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

modelchange(provider, model, ::DirectRoute) = typeof(provider)(provider.base, String(model), provider.key, provider.extra, provider.route)
function modelchange(provider, model, route::CatalogRoute)
    configured = configuredinfo(route.registry, route.name, model, ENV)
    modelchange(configured, model, configured.model)
end
modelchange(configured, model, ::Nothing) = invalidmodelconfig()
modelchange(configured, model, ::Models.Model) = acquire(APIKeyAuth(), configured, model)
