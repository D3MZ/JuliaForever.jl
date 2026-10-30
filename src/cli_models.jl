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
resolveprovider(options, model::Models.Model, thinking::AbstractString) = unsupportedthinking()

function resolveprovider(options, result::Models.Ambiguous)
    choices = sort([model.provider * "/" * model.id for model in result.models]; by=Models.collation)
    println(stderr, "Model is ambiguous: ", join(choices, ", "), ". Use --provider or provider/model.")
    2
end
resolveprovider(options, result::Models.Unmatched) = resolveprovider(options, result.target)
resolveprovider(options, target::Models.Target) = resolveprovider(options, target, target.thinking)
function resolveprovider(options, target::Models.Target, ::Nothing)
    selected = something(options.selected, target.provider)
    launchprovider(merge(options, (; selected, requested_model=target.id, catalog_provider=target.provider)))
end
resolveprovider(options, target::Models.Target, thinking::AbstractString) = unsupportedthinking()
function unsupportedthinking()
    println(stderr, "Thinking-level model suffixes are not yet supported by the CLI.")
    2
end
