struct ToolNamespace
    name::String
    description::String
    instructions::String
end
ToolNamespace(name::AbstractString; description="", instructions="") = ToolNamespace(String(name), String(description), String(instructions))

struct ToolSet <: AbstractDict{String, Tool}
    registry::Dict{String, Tool}
    direct::Vector{String}
    deferred::Vector{String}
    loaded::Vector{String}
    namespaces::Dict{String, ToolNamespace}
    lock::ReentrantLock
end

struct ToolSearch <: Tool
    tools::ToolSet
end

struct ToolLoaded <: ToolResult
    text::String
    loaded::Vector{String}
    image::Nothing
end
struct ToolDiscovery{T<:ToolResult} <: ToolResult
    result::T
    loaded::Vector{String}
    text::String
    image::Union{Nothing, Image}
end
ToolDiscovery(result::ToolResult, loaded::Vector{String}) = ToolDiscovery(result, loaded, result.text, result.image)
visible(result::ToolResult) = result
visible(result::Terminate) = visible(result.result)
visible(result::ToolDiscovery) = result.result
iserror(result::ToolDiscovery) = iserror(result.result)
content(result::ToolDiscovery) = content(result.result)
status(result::ToolDiscovery) = status(result.result)
loaded(result::ToolDiscovery) = copy(result.loaded)

ToolLoaded(text, loaded) = ToolLoaded(text, loaded, nothing)
iserror(::ToolLoaded) = false
content(result::ToolLoaded) = result.text
status(::ToolLoaded) = :ok
loaded(::ToolResult) = String[]
loaded(result::Terminate) = loaded(result.result)
loaded(result::ToolLoaded) = copy(result.loaded)

"Create an ordered model tool set with a `tool_search` tool and deferred, searchable tools. Agents start with a fresh set and restore exposure from their own history."
function ToolSet(direct::AbstractVector, deferred::AbstractVector; namespaces=Dict{String, ToolNamespace}())
    direct, deferred = Tool[direct...], Tool[deferred...]
    tools = [direct; deferred]
    names = [name(tool) for tool in tools]
    counts = Dict{String, Int}()
    for toolname in [names; "tool_search"]
        counts[toolname] = get(counts, toolname, 0) + 1
    end
    duplicates = unique([toolname for toolname in [names; "tool_search"] if counts[toolname] > 1])
    isempty(duplicates) || return ToolFailure("Duplicate tool names: $(join(duplicates, ", "))")
    registry = Dict{String, Tool}(name(tool) => tool for tool in tools)
    set = ToolSet(registry, [name.(direct); "tool_search"], name.(deferred), String[], Dict{String, ToolNamespace}(namespaces), ReentrantLock())
    registry["tool_search"] = ToolSearch(set)
    set
end

function fresh(tools::ToolSet)
    lock(tools.lock) do
        direct = Tool[tools.registry[n] for n in tools.direct if n != "tool_search"]
        deferred = Tool[tools.registry[n] for n in tools.deferred]
        ToolSet(direct, deferred; namespaces=copy(tools.namespaces))
    end
end
fresh(tools) = tools

function offered(tools::ToolSet)
    lock(tools.lock) do
        Pair{String, Tool}[n => tools.registry[n] for n in [tools.direct; tools.loaded] if haskey(tools.registry, n)]
    end
end
Base.length(tools::ToolSet) = length(offered(tools))
Base.getindex(tools::ToolSet, key::AbstractString) = Dict(offered(tools))[String(key)]
Base.get(tools::ToolSet, key, default) = get(Dict(offered(tools)), key, default)
Base.get(f::Union{Function, Type}, tools::ToolSet, key) = get(f, Dict(offered(tools)), key)
Base.IteratorSize(::Type{ToolSet}) = Base.SizeUnknown()
Base.IteratorSize(::Type{Base.ValueIterator{ToolSet}}) = Base.SizeUnknown()
Base.IteratorSize(::Type{Base.KeySet{String, ToolSet}}) = Base.SizeUnknown()
Base.iterate(tools::ToolSet) = iterate(tools, (offered(tools), 1))
function Base.iterate(::ToolSet, state::Tuple{Vector{Pair{String, Tool}}, Int})
    items, index = state
    index > length(items) && return nothing
    items[index], (items, index + 1)
end

"Expose named tools in order; unknown names are retained for later registration."
function expose!(tools::ToolSet, names)
    lock(tools.lock) do
        added, unknown, duplicates = String[], String[], String[]
        for value in names
            toolname = String(value)
            if toolname in tools.direct || toolname in tools.loaded
                push!(duplicates, toolname)
            else
                push!(tools.loaded, toolname)
                push!(haskey(tools.registry, toolname) ? added : unknown, toolname)
            end
        end
        (; loaded=added, unknown, duplicates)
    end
end

"Register a deferred tool; an earlier exposure of its name takes effect immediately."
function register!(tools::ToolSet, tool::Tool; namespace=ToolNamespace(""))
    lock(tools.lock) do
        toolname = name(tool)
        haskey(tools.registry, toolname) && return ToolFailure("Duplicate tool name: $toolname")
        tools.registry[toolname] = tool
        push!(tools.deferred, toolname)
        tools.namespaces[toolname] = namespace
        ToolSuccess("Registered $toolname")
    end
end

"Remove a deferred tool while retaining its exposure for a later registration."
function unregister!(tools::ToolSet, toolname::AbstractString)
    lock(tools.lock) do
        toolname in tools.deferred || return ToolFailure("Unknown deferred tool: $toolname")
        delete!(tools.registry, toolname)
        delete!(tools.namespaces, toolname)
        filter!(!=(toolname), tools.deferred)
        ToolSuccess("Unregistered $toolname")
    end
end

name(::ToolSearch) = "tool_search"
description(::ToolSearch) = "# Tool discovery\n\nSearches over deferred tool metadata with BM25 and exposes matching tools for the next model call.\n\nSome of the tools, such as tools of MCP servers, may not have been provided to you upfront, and you should use this tool (`tool_search`) to search for the required tools. For MCP tool discovery, always use `tool_search`."
schema(::ToolSearch) = Dict("type" => "object", "properties" => Dict("query" => Dict("type" => "string", "description" => "Search query for deferred tools."), "limit" => Dict("type" => "number", "description" => "Maximum number of tools to return. Defaults to 8.")), "required" => ["query"])

const toolstopwords = Set(["a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "in", "is", "it", "of", "on", "or", "that", "the", "this", "to", "with"])

function stemtool(term::AbstractString)
    length(term) > 4 && endswith(term, "ies") && return String(chop(term; tail=3)) * "y"
    length(term) > 4 && occursin(r"(ches|shes|sses|xes|zes)$", term) && return String(chop(term; tail=2))
    length(term) > 3 && endswith(term, "s") && !endswith(term, "ss") && return String(chop(term; tail=1))
    String(term)
end

function toolterms(text::AbstractString)
    spaced = replace(text, r"([a-z0-9])([A-Z])" => s"\1 \2")
    spaced = replace(spaced, r"([A-Z]+)([A-Z][a-z])" => s"\1 \2")
    [stemtool(term) for term in split(lowercase(spaced), r"[^a-z0-9]+") if !isempty(term) && term ∉ toolstopwords]
end

tooltext!(parts, value) = nothing
tooltext!(parts, value::AbstractString) = push!(parts, String(value))
schemafields!(parts, value) = nothing
function schemafields!(parts, value::Union{AbstractDict, NamedTuple})
    for (key, item) in pairs(value)
        push!(parts, string(key))
        schematext!(parts, item)
    end
end
schemavariants!(parts, value) = nothing
schemavariants!(parts, value::Union{AbstractVector, Tuple}) = foreach(item -> schematext!(parts, item), value)
schemaget(value::AbstractDict, key) = get(value, key, get(value, Symbol(key), nothing))
schemaget(value::NamedTuple, key) = get(value, Symbol(key), nothing)
schematext!(parts, value) = nothing
function schematext!(parts, value::Union{AbstractDict, NamedTuple})
    tooltext!(parts, schemaget(value, "description"))
    schemafields!(parts, schemaget(value, "properties"))
    schematext!(parts, schemaget(value, "items"))
    foreach(key -> schemavariants!(parts, schemaget(value, key)), ("anyOf", "oneOf", "allOf"))
    nothing
end

struct ToolDocument
    name::String
    text::String
end
function document(tool::Tool, namespace::ToolNamespace)
    toolname = name(tool)
    parts = String[toolname, replace(toolname, "_" => " "), description(tool)]
    schematext!(parts, schema(tool))
    append!(parts, (namespace.name, namespace.description, namespace.instructions))
    ToolDocument(toolname, join(filter(part -> !isempty(strip(part)), parts), " "))
end

function termcounts(text::AbstractString)
    counts = Dict{String, Int}()
    for term in toolterms(text)
        counts[term] = get(counts, term, 0) + 1
    end
    counts
end

normalizedtool(name::AbstractString) = replace(lowercase(strip(name)), r"[^a-z0-9_$]" => "_")
namedtool(query::AbstractString, name::AbstractString) = normalizedtool(name) == query || endswith(normalizedtool(name), "__" * query)

function ranktools(query::AbstractString, documents::Vector{ToolDocument}, limit::Integer)
    terms = unique(toolterms(query))
    (isempty(terms) || isempty(documents) || limit <= 0) && return String[]
    counts = termcounts.([document.text for document in documents])
    lengths = [sum(values(count); init=0) for count in counts]
    average = sum(lengths) / length(lengths)
    average == 0 && (average = 1.0)
    frequencies = Dict(term => count(count -> haskey(count, term), counts) for term in terms)
    weights = Dict(term => log(1 + (length(documents) - frequencies[term] + 0.5) / (frequencies[term] + 0.5)) for term in terms)
    exact = normalizedtool(query)
    scored = Tuple{Bool, Float64, Int}[]
    for index in eachindex(documents)
        norm = 1.2 * (0.25 + 0.75 * lengths[index] / average)
        score = sum((weights[term] * (get(counts[index], term, 0) * 2.2) / (get(counts[index], term, 0) + norm) for term in terms); init=0.0)
        score > 0 && push!(scored, (namedtool(exact, documents[index].name), score, index))
    end
    sort!(scored; by=item -> (!item[1], -item[2], item[3]))
    [documents[item[3]].name for item in Iterators.take(scored, limit)]
end

function candidates(tools::ToolSet)
    lock(tools.lock) do
        [(tools.registry[n], get(tools.namespaces, n, ToolNamespace(""))) for n in tools.deferred if n ∉ tools.loaded]
    end
end

searchargument(args::NamedTuple, key::Symbol, default) = get(args, key, default)
searchargument(args::AbstractDict, key::Symbol, default) = get(args, key, get(args, string(key), default))
searchargument(args, key::Symbol, default) = default

function search(search::ToolSearch, args)
    query = searchargument(args, :query, nothing)
    limit = searchargument(args, :limit, 8)
    searchtool(search.tools, query, limit)
end
execute(tool::ToolSearch, args) = expose_result!(tool.tools, search(tool, args))
expose_result!(tools::ToolSet, result::ToolResult) = result
expose_result!(tools::ToolSet, result::ToolLoaded) = (expose!(tools, result.loaded); result)
searchtool(tools, query, limit) = ToolFailure("query must be a string")
function searchtool(tools, query::AbstractString, limit)
    isempty(strip(query)) && return ToolFailure("query must not be empty")
    searchlimit(tools, query, limit)
end
searchlimit(tools, query, limit) = ToolFailure("limit must be a positive integer")
searchlimit(tools, query, limit::Bool) = ToolFailure("limit must be a positive integer")
function searchlimit(tools, query, limit::Real)
    (isfinite(limit) && isinteger(limit) && limit > 0) || return ToolFailure("limit must be a positive integer")
    found = candidates(tools)
    matches = ranktools(query, [document(tool, namespace) for (tool, namespace) in found], Int(min(limit, length(found))))
    descriptions = Dict(name(tool) => description(tool) for (tool, _) in found)
    searchresult(matches, descriptions)
end
searchresult(matches, descriptions) = ToolLoaded(searchmessage(matches, descriptions), matches)
function searchmessage(matches, descriptions)
    isempty(matches) && return "No matching tools found."
    label = length(matches) == 1 ? "tool" : "tools"
    lines = ["- $n: $(first(split(strip(descriptions[n]), r"\r?\n"; keepempty=true)))" for n in matches]
    "Loaded $(length(matches)) $label. They are available from your next call:\n" * join(lines, "\n")
end
