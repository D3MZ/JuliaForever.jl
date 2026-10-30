module Completion

import ..JuliaForever

struct Item
    name::String
    description::String
end

const builtins = Item[
    Item("model", "Select a model"),
    Item("tree", "Navigate the session tree"),
    Item("name", "Set or show the session name"),
    Item("fork", "Fork from a previous message"),
    Item("clone", "Duplicate the current session"),
    Item("new", "Start a new session"),
    Item("compact", "Compact the current context"),
    Item("resume", "Resume a different session"),
    Item("reload", "Reload skills"),
    Item("export", "Export the session as HTML or JSONL"),
    Item("session", "Show session information and statistics"),
    Item("exit", "Exit the session"),
]

function commands(templates::AbstractDict)
    [builtins; [Item(name, "Prompt template") for name in sort!(collect(keys(templates)))]]
end

function commands(resources::JuliaForever.Skills.Resources)
    [commands(resources.templates); [Item("skill:" * skill.name, skill.description) for skill in resources.skills]]
end

alignment(query, text) = foldl((positions, unit) -> align!(positions, text, unit), query; init=Int[])
align!(::Nothing, text, unit) = nothing
function align!(positions::Vector{Int}, text, unit)
    start = get(positions, length(positions), 0) + 1
    align!(positions, findnext(==(unit), text, start))
end
align!(positions, ::Nothing) = nothing
align!(positions, index::Int) = (push!(positions, index); positions)

function positionscore(positions, text)
    score = 0.0
    previous = 0
    consecutive = 0
    for index in positions
        if index == previous + 1
            consecutive += 1
            score -= consecutive * 5
        else
            consecutive = 0
            previous > 0 && (score += (index - previous - 1) * 2)
        end
        (index == 1 || isspace(Char(text[index - 1])) || Char(text[index - 1]) in ('-', '_', '.', '/', ':')) && (score -= 10)
        score += (index - 1) * 0.1
        previous = index
    end
    score
end

rawscore(query::AbstractString, text::AbstractString) = rawscore(transcode(UInt16, lowercase(query)), transcode(UInt16, lowercase(text)))
rawscore(query::Vector{UInt16}, text::Vector{UInt16}) = rawscore(query, text, alignment(query, text))
rawscore(query, text, ::Nothing) = nothing
function rawscore(query, text, positions::Vector{Int})
    result = positionscore(positions, text)
    count = length(query)
    for start in 1:length(text) - count + 1
        view(text, start:start + count - 1) == query || continue
        result = min(result, positionscore(start:start + count - 1, text))
    end
    query == text && (result -= 100)
    result
end

swap(token) = swap(match(r"\A([a-z]+)([0-9]+)\z", token), token)
swap(match::RegexMatch, token) = string(match[2], match[1])
swap(::Nothing, token) = swapdigits(match(r"\A([0-9]+)([a-z]+)\z", token))
swapdigits(::Nothing) = nothing
swapdigits(match::RegexMatch) = string(match[2], match[1])

tokenscore(token, text) = tokenscore(rawscore(token, text), token, text)
tokenscore(score::Float64, token, text) = score
tokenscore(::Nothing, token, text) = fallback(swap(lowercase(token)), text)
fallback(::Nothing, text) = nothing
fallback(token::AbstractString, text) = penalty(rawscore(token, text))
penalty(::Nothing) = nothing
penalty(score::Float64) = score + 5

addscore(::Nothing, token, text) = nothing
addscore(total::Float64, token, text) = addscore(total, tokenscore(token, text))
addscore(total::Float64, ::Nothing) = nothing
addscore(total::Float64, score::Float64) = total + score
score(query, text) = foldl((total, token) -> addscore(total, token, text), split(strip(query), r"[\s/]+"; keepempty=false); init=0.0)

record!(ranked, index, ::Nothing) = ranked
record!(ranked, index, value::Float64) = push!(ranked, (value, index))
function rank(items, query, indices, text)
    ranked = Tuple{Float64, Int}[]
    for index in indices
        record!(ranked, index, score(query, text(items[index])))
    end
    sort!(ranked)
    [index for (_, index) in ranked]
end

bare(item::Item) = chopprefix(item.name, "skill:")
full(item::Item) = item.name
function suggest(items::Vector{Item}, query::AbstractString)
    first = rank(items, query, eachindex(items), bare)
    used = Set(first)
    remaining = (index for index in eachindex(items) if startswith(items[index].name, "skill:") && !(index in used))
    second = rank(items, query, remaining, full)
    items[[first; second]]
end

modeltext(model::JuliaForever.Models.Model) = model.id * " " * model.provider * " " * model.provider * "/" * model.id * " " * model.provider * " " * model.id * " " * model.name
suggestmodels(models::Vector{JuliaForever.Models.Model}, query::AbstractString) = models[rank(models, query, eachindex(models), modeltext)]
modelvalue(model::JuliaForever.Models.Model) = model.provider * "/" * model.id

abstract type State end
struct Closed <: State end
struct Dismissed <: State
    prefix::String
end
mutable struct Menu <: State
    prefix::String
    items::Vector{Item}
    index::Int
end
mutable struct ModelMenu <: State
    before::String
    text::String
    prefix::String
    items::Vector{JuliaForever.Models.Model}
    index::Int
end
struct DismissedModel <: State
    before::String
    text::String
end

const pattern = r"\A[^\S\r\n]*(/[^ \r\n]*)\z"
prefix(text::AbstractString) = prefix(match(pattern, text))
prefix(::Nothing) = nothing
prefix(found::RegexMatch) = String(found[1])
const modelpattern = r"\A[^\S\r\n]*/model ([^\r\n]*)\z"
modelprefix(text::AbstractString) = modelprefix(match(modelpattern, text))
modelprefix(::Nothing) = nothing
modelprefix(found::RegexMatch) = String(found[1])

update(state::State, ::Nothing, resources) = Closed()
update(::Closed, prefix::String, resources) = open(prefix, resources)
update(state::Dismissed, prefix::String, resources) = state.prefix == prefix ? state : open(prefix, resources)
update(state::Menu, prefix::String, resources) = state.prefix == prefix ? state : open(prefix, resources)
function open(prefix, resources)
    items = suggest(commands(resources), chopprefix(prefix, "/"))
    isempty(items) ? Closed() : Menu(prefix, items, 1)
end

dismiss(state::State) = state
dismiss(menu::Menu) = Dismissed(menu.prefix)
dismiss(menu::ModelMenu) = DismissedModel(menu.before, menu.text)
move!(menu::Menu, offset::Int) = (menu.index = mod1(menu.index + offset, length(menu.items)); nothing)
page!(menu::Menu, offset::Int) = (menu.index = clamp(menu.index + offset, 1, length(menu.items)); nothing)
move!(menu::ModelMenu, offset::Int) = (menu.index = mod1(menu.index + offset, length(menu.items)); nothing)
page!(menu::ModelMenu, offset::Int) = (menu.index = clamp(menu.index + offset, 1, length(menu.items)); nothing)

include("terminal_files.jl")

end
