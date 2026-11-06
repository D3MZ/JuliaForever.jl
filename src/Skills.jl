module Skills

using JSON
using YAML

@kwdef struct Skill
    id::String
    name::String
    description::String
    path::String
    source::String
    instructions::String
    order::Int = typemax(Int)
    tools::Union{Nothing,Vector{Pair{String,Vector{String}}}} = nothing
end

root() = normpath(joinpath(@__DIR__, "..", "skills"))

function expected_tools(value)
    value isa AbstractString || error("metadata.expected-tools must be a JSON string")
    data = JSON.parse(value)
    data isa AbstractDict || error("metadata.expected-tools must be a JSON object")
    result = Pair{String,Vector{String}}[]
    for (name, parameters) in data
        name isa AbstractString && occursin(r"^[A-Za-z][A-Za-z0-9_]*$", name) ||
            error("Invalid expected tool name")
        parameters isa AbstractVector && all(p -> p isa AbstractString, parameters) ||
            error("Expected tool parameters must be strings")
        names = String.(parameters)
        allunique(names) || error("Expected tool parameters must be unique")
        push!(result, String(name) => names)
    end
    sort!(result; by=first)
end

function load_skill(path::AbstractString)
    source = read(path, String)
    parts = match(r"\A(?:\ufeff)?---[ \t]*\r?\n(.*?)\r?\n---[ \t]*(?:\r?\n|\z)(.*)\z"s, source)
    parts === nothing && error("SKILL.md needs YAML front matter")
    data = YAML.load(parts.captures[1])
    data isa AbstractDict || error("Skill front matter must be a mapping")
    id, description = get(data, "name", nothing), get(data, "description", nothing)
    id isa AbstractString && ncodeunits(id) <= 64 &&
        occursin(r"^[a-z0-9]+(?:-[a-z0-9]+)*$", id) || error("Invalid skill name")
    description isa AbstractString && !isempty(strip(description)) || error("Skill description is required")
    instructions = String(strip(parts.captures[2]))
    isempty(instructions) && error("Skill instructions are required")
    metadata = get(data, "metadata", Dict())
    metadata isa AbstractDict || error("Skill metadata must be a mapping")
    display = get(metadata, "display-name", titlecase(replace(id, '-' => ' ')))
    display isa AbstractString && !isempty(strip(display)) || error("Invalid skill display name")
    order = tryparse(Int, string(get(metadata, "order", "")))
    tools = haskey(metadata, "expected-tools") ? expected_tools(metadata["expected-tools"]) : nothing
    Skill(id=String(id), name=replace(String(strip(display)), '\n' => ' '),
          description=String(strip(description)), path=abspath(path), source=source,
          instructions=instructions, order=something(order, typemax(Int)), tools=tools)
end

function discover(directory::AbstractString=root())
    skills, errors, seen = Skill[], String[], Set{String}()
    isdir(directory) || return (skills=skills, errors=["Skills directory not found: $directory"])
    for (parent, _, files) in walkdir(directory)
        "SKILL.md" in files || continue
        path = joinpath(parent, "SKILL.md")
        try
            skill = load_skill(path)
            skill.id in seen && error("Duplicate skill name: $(skill.id)")
            push!(seen, skill.id)
            push!(skills, skill)
        catch error
            push!(errors, "$(relpath(path, directory)): $(sprint(showerror, error))")
        end
    end
    sort!(skills; by=s -> (s.order, lowercase(s.name), s.id))
    (skills=skills, errors=errors)
end

end
