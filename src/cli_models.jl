struct ModelListing
    query::String
end

const modelconstraints = Dict("openai-responses" => "openai")
const modeladapters = Dict(("openai", "openai-responses") => "openai-responses")

addusable!(providers, name, ::Nothing) = nothing
function addusable!(providers, name, key::AbstractString)
    isempty(key) || push!(providers, name)
    nothing
end
function usableproviders(env)
    providers = Set{String}()
    for name in ("openai", "openrouter", "anthropic", "google")
        addusable!(providers, name, keyvalue(env, providerinfos[name]))
    end
    providers
end

function usableproviders(env, registry::Models.Registry)
    providers = usableproviders(env)
    for (name, settings) in registry.providers
        delete!(providers, name)
        addusable!(providers, name, configuredkey(name, settings, catalogbuiltin(name), env))
    end
    providers
end

listmodels!(io, query, env) = listmodels!(io, query, env, modelconfig(env))
listmodels!(io, query, env, ::Models.InvalidConfig) = invalidmodelconfig()
function listmodels!(io, query, env, registry::Models.Registry)
    usable = usableproviders(env, registry)
    available = filter(model -> model.provider in usable, registry.models)
    Models.list(io, available, query)
    0
end

modelconstraint(::Nothing) = nothing
modelconstraint(selected::AbstractString) = get(modelconstraints, selected, selected)
modelconstraint(::APIKeyAuth, selected, registry) = modelconstraint(selected, registry)
modelconstraint(::OpenRouterAuth, selected, registry) = "openrouter"
modelconstraint(::Nothing, registry) = nothing
modelconstraint(selected::AbstractString, registry) = configuredconstraint(selected, get(registry.providers, selected, nothing))
configuredconstraint(selected, ::Nothing) = modelconstraint(selected)
configuredconstraint(selected, ::AbstractDict) = selected
resolveprovider(options, text::Union{Nothing, AbstractString}) = resolveprovider(options, text, modelconfig(ENV))
resolveprovider(options, text, ::Models.InvalidConfig) = invalidmodelconfig()
resolveprovider(options, ::Nothing, registry::Models.Registry) = launchprovider(merge(options, (; modelconfig=registry)))
function resolveprovider(options, text::AbstractString, registry::Models.Registry)
    usable = usableproviders(ENV, registry)
    result = Models.resolve(text, registry.models, usable; provider=modelconstraint(options.auth, options.selected, registry))
    resolveprovider(merge(options, (; modelconfig=registry)), result)
end

adapter(model::Models.Model) = get(modeladapters, (model.provider, model.api), model.provider)
resolveprovider(options, result::Models.Resolved) = resolveprovider(options, result.model, result.thinking)
resolveprovider(options, model::Models.Model, ::Nothing) = launchprovider(merge(options, (; selected=adapter(model), requested_model=model.id, catalog_provider=model.provider)))
const responsepath = joinpath(@__DIR__, "..", "data", "openai-thinking.json")
Base.include_dependency(responsepath)
const responselevels = JSON3.read(read(responsepath), Dict{String, Any})
abstract type ThinkingWire end
struct DirectThinking <: ThinkingWire end
struct UpdateThinking <: ThinkingWire end
const thinkingwires = Dict(false => DirectThinking(), true => UpdateThinking())
thinkingwire(levels) = get(thinkingwires, get(levels, "configurationUpdate", false), UpdateThinking())
supportedthinking(::DirectThinking, effort) = Models.ValidConfig()
supportedthinking(::UpdateThinking, effort) = Models.check(effort == "none")
resolveprovider(options, model::Models.Model, thinking::AbstractString) = selectthinking(options, model, thinking, get(responselevels, model.id, nothing))
selectthinking(options, model, thinking, ::Nothing) = unsupportedthinking()
function selectthinking(options, model, thinking, levels::AbstractDict)
    effort = get(levels, thinking, nothing)
    selected = get(options.modelconfig.providers, model.provider, nothing)
    configuredthinking(merge(options, (; requested_thinking=String(thinking))), model, effort, selected, thinkingwire(levels))
end
configuredthinking(options, model, effort, selected::AbstractDict, wire) = unsupportedthinking()
configuredthinking(options, model, effort, ::Nothing, wire) = selectthinking(options, model, effort, Models.combine(Models.check(model.provider == "openai" && model.api == "openai-responses" && model.reasoning), supportedthinking(wire, effort)))
selectthinking(options, model, effort, ::Models.InvalidConfig) = unsupportedthinking()
selectthinking(options, model, ::Nothing, ::Models.ValidConfig) = unsupportedthinking()
function selectthinking(options, model, effort::AbstractString, ::Models.ValidConfig)
    launchprovider(merge(options, (; selected=adapter(model), requested_model=model.id, catalog_provider=model.provider, thinking=String(effort))))
end

function resolveprovider(options, result::Models.Ambiguous)
    choices = sort([model.provider * "/" * model.id for model in result.models]; by=Models.collation)
    println(stderr, "Model is ambiguous: ", join(choices, ", "), ". Use --provider or provider/model.")
    2
end
resolveprovider(options, result::Models.Unmatched) = resolveunmatched(options, result.target, Models.suffix(options.requested_model))
resolveunmatched(options, target, ::Nothing) = resolveprovider(options, target)
resolveunmatched(options, ::Nothing, ::Models.Suffix) = unsupportedthinking()
resolveunmatched(options, target::Models.Target, ::Models.Suffix) = resolveprovider(options, target)
resolveprovider(options, target::Models.Target) = resolveprovider(options, target, target.thinking)
function resolveprovider(options, target::Models.Target, ::Nothing)
    selected = something(options.selected, target.provider)
    launchprovider(merge(options, (; selected, requested_model=target.id, catalog_provider=target.provider)))
end
resolveprovider(options, target::Models.Target, thinking::AbstractString) = unsupportedthinking()
function unsupportedthinking()
    println(stderr, "Thinking level is unsupported for this model or provider.")
    2
end
