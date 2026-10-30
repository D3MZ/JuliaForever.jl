module ToolSelection

import ..JuliaForever: Tool, Read, Write, Edit, Bash, PowerShell, Ls, Find, Grep, CodeMode, Extensions, name

abstract type Baseline end
struct Defaults <: Baseline end
struct NoBuiltin <: Baseline end
struct NoTools <: Baseline end
baseline(::Baseline, selected::NoTools) = selected
baseline(::NoTools, ::NoBuiltin) = NoTools()
baseline(::Baseline, selected::NoBuiltin) = selected

abstract type Entry end
struct Pattern <: Entry
    text::String
end
abstract type Change <: Entry end
struct Add <: Change
    text::String
end
struct Remove <: Change
    text::String
end
const actions = Dict("+" => Add, "-" => Remove)
entry(text) = entry(text, match(r"^([+-])(.*)$"s, text))
entry(text, ::Nothing) = Pattern(text)
entry(text, found::RegexMatch) = actions[found[1]](found[2])

abstract type Rule end
struct Inherit <: Rule end
struct Allow <: Rule
    patterns::Vector{Regex}
end
struct Changes <: Rule
    entries::Vector{Union{Add, Remove}}
end
struct Invalid <: Rule
    message::String
end
assign(::Rule, rule::Rule) = rule
assign(invalid::Invalid, ::Rule) = invalid

function list(text)
    String[strip(part) for part in split(text, ',') if !isempty(strip(part))]
end

function pattern(text)
    parts = split(text, '*'; keepempty=true)
    escaped = [replace(part, r"([\\.^$|?+()\[\]{}])" => s"\\\1") for part in parts]
    Regex(string("^", join(escaped, ".*"), '$'))
end
patterns(text) = pattern.(list(text))

function entries(text)
    plain = String[]
    changes = Union{Add, Remove}[]
    for value in list(text)
        add!(plain, changes, entry(value))
    end
    rules(plain, changes)
end
add!(plain, changes, value::Pattern) = push!(plain, value.text)
add!(plain, changes, value::Change) = push!(changes, value)

function rules(plain, changes)
    isempty(changes) && return Allow(pattern.(plain))
    isempty(plain) || return Invalid("tool names cannot be mixed with +name or -name entries")
    any(change -> occursin('*', change.text), changes) && return Invalid("+name and -name entries take exact tool names, not patterns")
    Changes(changes)
end

const Builtin = Union{Read, Write, Edit, Bash, PowerShell, Ls, Find, Grep}
const DefaultBuiltin = Union{Read, Write, Edit, Bash}
const OtherBuiltin = Union{PowerShell, Ls, Find, Grep}

default(::Defaults, tool::DefaultBuiltin) = (tool,)
default(::Defaults, tool::OtherBuiltin) = ()
default(::Defaults, tool::Tool) = (tool,)
default(::NoBuiltin, tool::Builtin) = ()
default(::NoBuiltin, tool::Tool) = (tool,)
default(::NoTools, tool::Tool) = ()

names(::Defaults) = Set(["read", "bash", "edit", "write"])
names(::Union{NoBuiltin, NoTools}) = Set{String}()
function modify!(selected, change::Add)
    isempty(change.text) || push!(selected, change.text)
    selected
end
modify!(selected, change::Remove) = (delete!(selected, change.text); selected)

function selected(tools, base::Baseline, ::Inherit)
    result = Tool[]
    foreach(tool -> append!(result, default(base, tool)), tools)
    result
end

function selected(tools, base::Baseline, rule::Allow)
    filter(tool -> any(regex -> occursin(regex, name(tool)), rule.patterns), tools)
end

function selected(tools, base::Baseline, rule::Changes)
    wanted = foldl(modify!, rule.entries; init=names(base))
    result = Tool[]
    for tool in tools
        changed!(result, base, tool, wanted)
    end
    result
end
changed!(result, ::Union{Defaults, NoBuiltin}, tool::Builtin, wanted) = name(tool) in wanted ? push!(result, tool) : result
changed!(result, ::Union{Defaults, NoBuiltin}, tool::Tool, wanted) = push!(result, tool)
changed!(result, ::NoTools, tool::Tool, wanted) = name(tool) in wanted ? push!(result, tool) : result

function select(snapshot::Extensions.Snapshot, base::Baseline, rule::Rule, excluded::Vector{Regex})
    active = selected(Extensions.tools(snapshot), base, rule)
    filter!(tool -> !any(regex -> occursin(regex, name(tool)), excluded), active)
    nested = Tool[]
    foreach(tool -> nested!(nested, tool), active)
    active = Tool[bind(tool, nested) for tool in active]
    Extensions.Snapshot(Tuple(active), snapshot.hooks)
end
nested!(nested, tool::Tool) = push!(nested, tool)
nested!(nested, ::CodeMode) = nested
bind(tool::Tool, nested) = tool
bind(::CodeMode, nested) = CodeMode(nested)

end
