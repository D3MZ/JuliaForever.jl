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

function listmodels!(io, query, env)
    usable = usableproviders(env)
    available = filter(model -> model.provider in usable, Models.catalog())
    Models.list(io, available, query)
    0
end

modelconstraint(::APIKeyAuth, selected) = modelconstraint(selected)
modelconstraint(::OpenRouterAuth, selected) = "openrouter"
modelconstraint(::Nothing) = nothing
modelconstraint(selected::AbstractString) = get(modelconstraints, selected, selected)
resolveprovider(options, ::Nothing) = launchprovider(options)
function resolveprovider(options, text::AbstractString)
    usable = usableproviders(ENV)
    result = Models.resolve(text, Models.catalog(), usable; provider=modelconstraint(options.auth, options.selected))
    resolveprovider(options, result)
end

adapter(model::Models.Model) = get(modeladapters, (model.provider, model.api), model.provider)
resolveprovider(options, result::Models.Resolved) = resolveprovider(options, result.model, result.thinking)
resolveprovider(options, model::Models.Model, ::Nothing) = launchprovider(merge(options, (; selected=adapter(model), requested_model=model.id)))
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
    launchprovider(merge(options, (; selected, requested_model=target.id)))
end
resolveprovider(options, target::Models.Target, thinking::AbstractString) = unsupportedthinking()
function unsupportedthinking()
    println(stderr, "Thinking-level model suffixes are not yet supported by the CLI.")
    2
end
