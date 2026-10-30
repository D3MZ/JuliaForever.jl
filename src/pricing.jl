struct ModelRate
    input::Float64
    output::Float64
    cache_read::Float64
    cache_write::Float64
end

struct ModelPrices
    base::ModelRate
    tiers::Vector{Pair{Float64, ModelRate}}
end

const pricecatalog = Base.OncePerProcess{Dict{Tuple{String, String}, Any}}() do
    Dict((model["provider"], model["id"]) => model["cost"] for model in Models.metadata())
end
const zeroprices = Dict("input" => 0, "output" => 0, "cacheRead" => 0, "cacheWrite" => 0)

modelrate(raw) = ModelRate(raw["input"], raw["output"], raw["cacheRead"], raw["cacheWrite"])
priceplan(raw::Nothing) = nothing
priceplan(raw::AbstractDict) = priceplan(raw, Models.costcomplete(raw))
priceplan(raw, ::Models.InvalidConfig) = nothing
priceplan(raw, ::Models.ValidConfig) = ModelPrices(modelrate(raw), [Float64(tier["inputTokensAbove"]) => modelrate(tier) for tier in get(raw, "tiers", [])])

pricename(provider) = nothing
pricename(provider::Union{OpenAI, OpenAIResponses, Anthropic, Google}) = pricename(provider, provider.route)
pricename(provider, route::CatalogRoute) = route.name
pricename(provider, ::DirectRoute) = get(pricehosts, (typeof(provider), lowercase(HTTP.URI(provider.base).host)), nothing)
const pricehosts = Dict((OpenAI, "api.openai.com") => "openai", (OpenAIResponses, "api.openai.com") => "openai", (OpenAI, "openrouter.ai") => "openrouter", (Anthropic, "api.anthropic.com") => "anthropic", (Google, "generativelanguage.googleapis.com") => "google")

priceconfig(provider, name) = nothing
priceconfig(provider, name, ::DirectRoute) = nothing
priceconfig(provider, name, route::CatalogRoute) = get(route.registry.providers, name, nothing)
priceconfig(provider::Union{OpenAI, OpenAIResponses, Anthropic, Google}, name) = priceconfig(provider, name, provider.route)

pricebook(::Nothing, id, config) = nothing
pricebook(name::String, id, ::Nothing) = get(pricecatalog(), (name, id), nothing)
function pricebook(name::String, id, config::AbstractDict)
    base = definitionprice(name, id, effective(config, id))
    mergeprice(base, get(modeloverride(config, id), "cost", nothing))
end
definitionprice(name, id, ::Nothing) = get(pricecatalog(), (name, id), nothing)
definitionprice(name, id, definition::AbstractDict) = get(definition, "cost", zeroprices)
mergeprice(base, ::Nothing) = base
mergeprice(::Nothing, override::AbstractDict) = override
mergeprice(base::AbstractDict, override::AbstractDict) = merge(base, override)

rates(provider) = rates(provider, pricename(provider))
rates(provider, ::Nothing) = nothing
rates(provider, name::String) = priceplan(pricebook(name, provider.model, priceconfig(provider, name)))

function rate(prices::ModelPrices, usage::Usage)
    tokens = usage.input + usage.cache_read + usage.cache_write
    selected = prices.base
    threshold = -Inf
    for (above, tier) in prices.tiers
        if tokens > above && above > threshold
            selected = tier
            threshold = above
        end
    end
    selected
end

price(provider, value) = value
price(provider, ::Nothing) = nothing
price(provider::Union{OpenAI, OpenAIResponses, Anthropic, Google}, usage::Usage) = price(usage, rates(provider))
price(usage::Usage, ::Nothing) = usage
reported(cost, ::Nothing) = cost
reported(cost, breakdown::CostBreakdown) = breakdown.reported
function price(usage::Usage, prices::ModelPrices)
    selected = rate(prices, usage)
    input = selected.input / 1_000_000 * usage.input
    output = selected.output / 1_000_000 * usage.output
    read = selected.cache_read / 1_000_000 * usage.cache_read
    write = (selected.cache_write * (usage.cache_write - usage.cache_write_1h) + selected.input * 2 * usage.cache_write_1h) / 1_000_000
    upstream = reported(usage.cost, usage.breakdown)
    total = something(upstream, input + output + read + write)
    breakdown = CostBreakdown(input, output, read, write, upstream)
    Usage(usage.input, usage.output, usage.cache_read, usage.cache_write, usage.reasoning, usage.total, total, breakdown, usage.cache_write_1h)
end
function price(provider, result::Completion)
    Completion(result.message, price(provider, result.usage), result.finish, getfield(result, :status), result.error)
end

priceevent(provider, event) = get(priceevents, event.type, unchangedpriceevent)(provider, event)
unchangedpriceevent(provider, event) = event
priceusageevent(provider, event) = merge(event, (; usage=price(provider, event.usage)))
pricecompleteevent(provider, event) = merge(event, (; result=price(provider, event.result)))
const priceevents = Dict(:usage => priceusageevent, :done => pricecompleteevent, :incomplete => pricecompleteevent)
