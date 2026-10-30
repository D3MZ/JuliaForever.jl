module Models

using JSON3, StructTypes

struct Model
    provider::String
    id::String
    name::String
    api::String
    context::Int
    maxoutput::Int
    reasoning::Bool
    images::Bool
end

struct Registry
    models::Vector{Model}
    providers::Dict{String, Any}
end
struct InvalidConfig end
struct ValidConfig end

const validation = Dict(true => ValidConfig(), false => InvalidConfig())
check(value::Bool) = validation[value]
combine() = ValidConfig()
combine(::InvalidConfig, rest...) = InvalidConfig()
combine(::ValidConfig, rest...) = combine(rest...)

Base.show(io::IO, ::Registry) = print(io, "Model registry ([redacted])")
StructTypes.StructType(::Type{Registry}) = StructTypes.CustomStruct()
StructTypes.lower(registry::Registry) = (; models=registry.models, providers="[redacted]")

Model(provider, id, name) = Model(provider, id, name, "", 0, 0, false, false)
StructTypes.StructType(::Type{Model}) = StructTypes.Struct()

abstract type Resolution end
struct Resolved <: Resolution
    model::Model
    thinking::Union{Nothing, String}
end
struct Ambiguous <: Resolution
    models::Vector{Model}
    usable::Int
    thinking::Union{Nothing, String}
end
struct Target
    provider::String
    id::String
    thinking::Union{Nothing, String}
end
struct Unmatched <: Resolution
    target::Union{Nothing, Target}
end
struct Suffix
    base::String
    thinking::String
end

const levels = Set(["off", "minimal", "low", "medium", "high", "xhigh", "max"])
const path = joinpath(@__DIR__, "..", "data", "models.json")
const metadatapath = joinpath(@__DIR__, "..", "data", "pi-rpc-models.json")
Base.include_dependency(metadatapath)
const metadata = Base.OncePerProcess{Vector{Dict{String, Any}}}() do
    JSON3.read(read(metadatapath), Vector{Dict{String, Any}})
end
# The bundled catalog's IDs are ASCII; match Pi's punctuation order when listing them.
const punctuation = Dict(char => Char(index) for (index, char) in enumerate(" _-,;:!?.()[]{}@*/&#%`^+<=>|~\$"))

catalog() = JSON3.read(read(path), Vector{Model})

function configjson(bytes)
    text = replace(String(bytes), Regex("^\ufeff") => "")
    text = replace(text, r"(\"(?:\\.|[^\"\\])*\")|//[^\n]*" => s"\1")
    replace(text, r"(\"(?:\\.|[^\"\\])*\")|,(?=\s*[}\]])" => s"\1")
end

function load(configpath::AbstractString)
    models = catalog()
    isfile(configpath) || return Registry(models, Dict{String, Any}())
    bytes = read(configpath)
    try
        config = JSON3.read(configjson(bytes), Dict{String, Any})
        providers = Dict{String, Any}(config["providers"])
        foldl(applyprovider!, pairs(providers); init=Registry(models, providers))
    catch
        InvalidConfig()
    end
end

catalog(configpath::AbstractString) = catalog(load(configpath))
catalog(registry::Registry) = registry.models
catalog(invalid::InvalidConfig) = invalid

applyprovider!(invalid::InvalidConfig, pair) = invalid
function applyprovider!(registry::Registry, pair)
    name, settings = pair
    applyprovider!(registry, name, settings, validprovider(name, settings, registry.models))
end
applyprovider!(registry, name, settings, invalid::InvalidConfig) = invalid
function applyprovider!(registry, name, settings, ::ValidConfig)
    overlay!(registry.models, name, settings)
    registry
end

validprovider(name, settings, models) = InvalidConfig()
function validprovider(name, settings::AbstractDict, models)
    inherited = any(model -> model.provider == name, models)
    definitions = foldl((result, entry) -> combine(result, validdefinition(last(entry), settings, inherited | (first(entry) > 1))), enumerate(get(settings, "models", [])); init=ValidConfig())
    overrides = foldl((result, model) -> combine(result, validmodel(model)), values(get(settings, "modelOverrides", Dict())); init=ValidConfig())
    combine(validauth(get(settings, "authHeader", nothing)), definitions, overrides)
end
validauth(::Nothing) = ValidConfig()
validauth(::Bool) = ValidConfig()
validauth(value) = InvalidConfig()
validdefinition(model, settings, inherited) = InvalidConfig()
function validdefinition(model::AbstractDict, settings, inherited)
    combine(validid(get(model, "id", nothing)), validmodel(model), validdefinitioncost(model), validroute(get(model, "api", get(settings, "api", nothing)), inherited), validroute(get(model, "baseUrl", get(settings, "baseUrl", nothing)), inherited))
end
validid(value) = InvalidConfig()
validid(value::AbstractString) = check(!isempty(value))
validroute(::Nothing, inherited) = check(inherited)
validroute(value::AbstractString, inherited) = check(!isempty(value))
validroute(value, inherited) = InvalidConfig()
validmodel(model) = InvalidConfig()
function validmodel(model::AbstractDict)
    combine(validtokens(get(model, "contextWindow", nothing)), validtokens(get(model, "maxTokens", nothing)), validinput(get(model, "input", nothing)), validreasoning(get(model, "reasoning", false)), validmodelcost(model))
end
const costfields = ("input", "output", "cacheRead", "cacheWrite")
validmodelcost(model) = haskey(model, "cost") ? validcost(model["cost"]) : ValidConfig()
validdefinitioncost(model) = haskey(model, "cost") ? costcomplete(model["cost"]) : ValidConfig()
costcomplete(value) = InvalidConfig()
costcomplete(value::AbstractDict) = check(all(key -> haskey(value, key), costfields))
validcost(value) = InvalidConfig()
function validcost(value::AbstractDict)
    fields = foldl((result, key) -> combine(result, optionalrate(value, key)), costfields; init=ValidConfig())
    combine(fields, optionaltiers(value))
end
optionalrate(value, key) = haskey(value, key) ? validrate(value[key]) : ValidConfig()
validrate(value) = InvalidConfig()
validrate(::Bool) = InvalidConfig()
validrate(value::Real) = check(isfinite(value))
optionaltiers(value) = haskey(value, "tiers") ? validtiers(value["tiers"]) : ValidConfig()
validtiers(value) = InvalidConfig()
validtiers(value::AbstractVector) = foldl((result, tier) -> combine(result, validtier(tier)), value; init=ValidConfig())
validtier(value) = InvalidConfig()
validtier(value::AbstractDict) = combine(costcomplete(value), validcost(value), validrate(get(value, "inputTokensAbove", nothing)))
validreasoning(value) = InvalidConfig()
validreasoning(::Bool) = ValidConfig()
validtokens(::Nothing) = ValidConfig()
validtokens(::Bool) = InvalidConfig()
validtokens(value::Integer) = check(value > 0)
validtokens(value) = InvalidConfig()
validinput(::Nothing) = ValidConfig()
validinput(value::AbstractVector) = check(all(item -> item in ("text", "image"), value))
validinput(value) = InvalidConfig()

function overlay!(models, provider, settings)
    for definition in get(settings, "models", [])
        existing = filter(model -> model.provider == provider, models)
        index = findfirst(model -> model.provider == provider && model.id == definition["id"], models)
        defaults = findmodel(model -> model.id == definition["id"], existing)
        defaults = modeldefaults(defaults, existing, get(definition, "api", get(settings, "api", "")))
        model = custommodel(provider, definition, settings, defaults)
        upsert!(models, index, model)
    end
    overrides = get(settings, "modelOverrides", Dict())
    for index in eachindex(models)
        model = models[index]
        model.provider == provider || continue
        models[index] = override(model, get(overrides, model.id, Dict()))
    end
    models
end

modeldefaults(model::Model, existing, api) = model
function modeldefaults(::Nothing, existing, api::AbstractString)
    matching = findmodel(model -> model.api == api, existing)
    modeldefaults(matching, existing)
end
modeldefaults(model::Model, existing) = model
function modeldefaults(::Nothing, existing)
    modeldefaults(findmodel(model -> model.api == "openai-completions", existing), existing, nothing)
end
modeldefaults(::Nothing, existing, ::Nothing) = isempty(existing) ? nothing : first(existing)
defaultapi(::Nothing) = ""
defaultapi(model::Model) = model.api

function custommodel(provider, definition, settings, defaults)
    id = String(definition["id"])
    Model(String(provider), id, String(get(definition, "name", id)), String(get(definition, "api", get(settings, "api", defaultapi(defaults)))), Int(get(definition, "contextWindow", 128000)), Int(get(definition, "maxTokens", 16384)), Bool(get(definition, "reasoning", false)), "image" in get(definition, "input", ["text"]))
end
upsert!(models, ::Nothing, model) = push!(models, model)
upsert!(models, index::Integer, model) = (models[index] = model)
function override(model::Model, fields)
    Model(model.provider, model.id, String(get(fields, "name", model.name)), model.api, Int(get(fields, "contextWindow", model.context)), Int(get(fields, "maxTokens", model.maxoutput)), Bool(get(fields, "reasoning", model.reasoning)), images(fields, model.images))
end
images(fields, fallback) = haskey(fields, "input") ? "image" in fields["input"] : fallback
function collation(text)
    primary = String([get(punctuation, char, char) for char in lowercase(text)])
    case = String([isuppercase(char) ? '1' : '0' for char in text])
    (primary, case, text)
end
pool(models, ::Nothing) = models
function pool(models, provider::AbstractString)
    name = lowercase(provider)
    filter(model -> lowercase(model.provider) == name, models)
end
item(items, ::Nothing) = nothing
item(items, index::Integer) = items[index]
findmodel(f, models) = item(models, findfirst(f, models))

function prefix(text, models)
    result = nothing
    for index in eachindex(text)
        text[index] == '/' || continue
        name = strip(text[firstindex(text):prevind(text, index)])
        rest = strip(text[nextind(text, index):end])
        isempty(rest) && continue
        name = lowercase(name)
        model = findmodel(m -> lowercase(strip(m.provider)) == name, models)
        result = prefix(result, model, rest)
    end
    result
end
prefix(previous, ::Nothing, rest) = previous
prefix(previous, model::Model, rest) = (model.provider, String(rest))

suffix(text) = suffix(text, findlast(==(':'), text))
suffix(text, ::Nothing) = nothing
function suffix(text, index::Integer)
    level = String(text[nextind(text, index):end])
    level in levels || return nothing
    Suffix(String(text[firstindex(text):prevind(text, index)]), level)
end

withthinking(result::Unmatched, level) = result
withthinking(result::Resolved, level) = Resolved(result.model, level)
withthinking(result::Ambiguous, level) = Ambiguous(result.models, result.usable, level)

function choose(models, usable)
    isempty(models) && return Unmatched(nothing)
    length(Set(model.provider for model in models)) == 1 && return Resolved(first(models), nothing)
    configured = filter(model -> model.provider in usable, models)
    length(configured) == 1 && return Resolved(only(configured), nothing)
    Ambiguous(models, length(configured), nothing)
end

choose(raw, ::Nothing, usable) = choose(raw, usable)
function choose(raw, named::Model, usable)
    others = filter(model -> model !== named, raw)
    candidates = [named; others]
    length(Set(model.provider for model in candidates)) == 1 && return Resolved(named, nothing)
    named.provider in usable && return Resolved(named, nothing)
    configured = filter(model -> model.provider in usable, others)
    length(configured) == 1 && return Resolved(only(configured), nothing)
    isempty(configured) && return Resolved(named, nothing)
    Ambiguous(candidates, length(configured), nothing)
end

matchtext(text, model) = occursin(text, lowercase(model.id)) || occursin(text, lowercase(model.name))
alias(model) = !occursin(r"-\d{8}$", model.id) || endswith(model.id, "-latest")

function best(models)
    isempty(models) && return nothing
    aliases = filter(alias, models)
    candidates = isempty(aliases) ? models : aliases
    argmax(model -> collation(model.id), candidates)
end

named(text::AbstractString, models, ::Nothing) = nothing
function named(text::AbstractString, models, pair::Tuple{String, String})
    provider, id = pair
    candidates = filter(model -> model.provider == provider, models)
    name = lowercase(id)
    exact = findmodel(model -> lowercase(model.id) == name, candidates)
    named(text, candidates, exact, id)
end
named(text, candidates, exact::Model, id) = exact
function named(text, candidates, ::Nothing, id)
    name = lowercase(text)
    literal = findmodel(model -> lowercase(model.id) == name, candidates)
    named(candidates, literal, id)
end
named(candidates::AbstractVector, literal::Model, id) = literal
function named(candidates::AbstractVector, ::Nothing, id)
    name = lowercase(id)
    best(filter(model -> matchtext(name, model), candidates))
end

function fuzzy(text, models, usable)
    name = lowercase(text)
    matcheset = filter(model -> matchtext(name, model), models)
    isempty(matcheset) && return Unmatched(nothing)
    configured = length(Set(model.provider for model in matcheset)) > 1 ? filter(model -> model.provider in usable, matcheset) : Model[]
    candidates = isempty(configured) ? matcheset : configured
    fuzzy(best(candidates), candidates, configured)
end
fuzzy(::Nothing, candidates, configured) = Unmatched(nothing)
function fuzzy(winner::Model, candidates, configured)
    tied = filter(model -> model.id == winner.id, candidates)
    length(Set(model.provider for model in tied)) == 1 && return Resolved(winner, nothing)
    Ambiguous(tied, isempty(configured) ? 0 : length(tied), nothing)
end

function search(text, models, usable)
    name = lowercase(text)
    raw = filter(model -> lowercase(model.id) == name, models)
    selected = choose(raw, named(text, models, prefix(text, models)), usable)
    search(selected, text, models, usable)
end
search(result::Union{Resolved, Ambiguous}, text, models, usable) = result
search(::Unmatched, text, models, usable) = searchfuzzy(fuzzy(text, models, usable), text, models, usable)
searchfuzzy(result::Union{Resolved, Ambiguous}, text, models, usable) = result
searchfuzzy(::Unmatched, text, models, usable) = searchsuffix(suffix(text), models, usable)
searchsuffix(::Nothing, models, usable) = Unmatched(nothing)
searchsuffix(part::Suffix, models, usable) = withthinking(search(part.base, models, usable), part.thinking)

target(models::AbstractVector, ::Nothing, text) = target(models, prefix(text, models))
target(models::AbstractVector, provider::AbstractString, text) = target(models, provider, text, prefix(text, models))
target(models::AbstractVector, ::Nothing) = nothing
target(models::AbstractVector, pair::Tuple{String, String}) = target(first(pool(models, pair[1])), pair[2])
target(models::AbstractVector, provider, text, ::Nothing) = target(item(models, isempty(models) ? nothing : firstindex(models)), text)
target(models::AbstractVector, provider, text, pair::Tuple{String, String}) = target(item(models, isempty(models) ? nothing : firstindex(models)), pair[2])
target(::Nothing, text) = nothing
target(model::Model, text) = target(model, text, suffix(text))
target(model::Model, text, ::Nothing) = Target(model.provider, String(text), nothing)
target(model::Model, text, part::Suffix) = Target(model.provider, part.base, part.thinking)

resolve(result::Union{Resolved, Ambiguous}, models, provider, text) = result
resolve(::Unmatched, models, provider, text) = Unmatched(target(models, provider, text))
function resolve(text, models, usable; provider=nothing)
    text = String(strip(text))
    isempty(text) && return Unmatched(nothing)
    candidates = pool(models, provider)
    resolve(search(text, candidates, usable), candidates, provider, text)
end

function subsequence(query, text)
    pending = iterate(query)
    for char in text
        pending = advance(pending, query, char)
    end
    finished(pending)
end
advance(::Nothing, query, char) = nothing
advance(pending::Tuple, query, char) = char == pending[1] ? iterate(query, pending[2]) : pending
finished(::Nothing) = true
finished(::Tuple) = false

function variants(token)
    matchresult = match(r"^([a-z]+)([0-9]+)$", token)
    variants(token, matchresult)
end
variants(token, result::RegexMatch) = (token, result.captures[2] * result.captures[1])
variants(token, ::Nothing) = variants(token, match(r"^([0-9]+)([a-z]+)$", token), nothing)
variants(token, result::RegexMatch, unused) = (token, result.captures[2] * result.captures[1])
variants(token, ::Nothing, unused) = (token,)

function filtered(models, query)
    tokens = filter(!isempty, split(lowercase(strip(query)), r"[\s/]+"))
    filter(models) do model
        text = lowercase(model.provider * " " * model.id)
        all(token -> any(variant -> subsequence(variant, text), variants(token)), tokens)
    end
end

function token(value, scale, unit)
    amount = value % scale == 0 ? string(div(value, scale)) : decimal(value / scale)
    amount * unit
end
function decimal(number)
    tenths = round(BigInt, Rational{BigInt}(number) * 10, RoundNearestTiesAway)
    string(div(tenths, 10), ".", mod(tenths, 10))
end
token(value) = value >= 1_000_000 ? token(value, 1_000_000, "M") : value >= 1_000 ? token(value, 1_000, "K") : string(value)
const yesno = Dict(true => "yes", false => "no")
columns(model) = (model.provider, model.id, token(model.context), token(model.maxoutput), yesno[model.reasoning], yesno[model.images])

function list(io, models, query)
    isempty(models) && return println(io, "No models available. Configure an API key for a supported provider.")
    selected = filtered(models, query)
    isempty(selected) && return println(io, "No models matching \"", query, "\"")
    sort!(selected; by=model -> (collation(model.provider), collation(model.id)))
    rows = columns.(selected)
    header = ("provider", "model", "context", "max-out", "thinking", "images")
    widths = ntuple(index -> max(length(header[index]), maximum(length(row[index]) for row in rows)), length(header))
    for row in Iterators.flatten(((header,), rows))
        println(io, join((rpad(row[index], widths[index]) for index in eachindex(row)), "  "))
    end
    nothing
end

end
