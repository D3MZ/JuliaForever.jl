module Skills

import YAML
using ..Prompts: frontmatter
import ..JuliaForever: FileRule, ignored, rules

struct Automatic end
struct Explicit end

struct Skill
    name::String
    description::String
    path::String
    dir::String
    invocation::Union{Automatic, Explicit}
end

struct PiDirectory end
struct AgentsDirectory end

header(::Nothing) = nothing

function header(match::RegexMatch)
    text = String(something(match[1], ""))
    text = chop(text; head=min(1, length(text)), tail=0)
    try
        YAML.load(text)
    catch
        nothing
    end
end

function header(text::AbstractString)
    normalized = replace(String(chopprefix(text, "\ufeff")), "\r\n" => "\n", '\r' => '\n')
    header(match(frontmatter, normalized))
end

skillname(name, fallback) = fallback
skillname(name::AbstractString, fallback) = isempty(name) ? fallback : String(name)
invocation(value) = Automatic()
invocation(value::Bool) = (Automatic(), Explicit())[1 + value]
disabled(::Automatic) = false
disabled(::Explicit) = true
visible(::Automatic) = true
visible(::Explicit) = false

skill(path, fields) = nothing
skill(path, fields::AbstractDict) = skill(path, fields, get(fields, "description", nothing))
skill(path, fields, description) = nothing

function skill(path, fields, description::AbstractString)
    isempty(strip(description)) && return nothing
    dir = dirname(path)
    name = skillname(get(fields, "name", nothing), basename(dir))::String
    mode = invocation(get(fields, "disable-model-invocation", false))::Union{Automatic, Explicit}
    Skill(name, String(description), path, dir, mode)
end

skillfile(path)::Union{Nothing, Skill} = skill(path, header(read(path, String)))

add!(skills, names, paths, ::Nothing) = nothing

function add!(skills, names, paths, skill::Skill)
    path = realpath(skill.path)
    path in paths && return nothing
    if skill.name in names
        @warn "Skill name collision; keeping the first" name=skill.name path=skill.path
        return nothing
    end
    push!(paths, path)
    push!(names, skill.name)
    push!(skills, skill)
    nothing
end

markdown(::PiDirectory, root) = root
markdown(::AgentsDirectory, root) = !root

function scan!(skills, names, paths, active, dir, mode, root=true, inherited=FileRule[])
    isdir(dir) || return nothing
    canonical = realpath(dir)
    canonical in active && return nothing
    push!(active, canonical)
    ruleset = copy(inherited)
    for filename in (".gitignore", ".ignore", ".fdignore")
        append!(ruleset, rules(joinpath(dir, filename), FileRule))
    end
    path = joinpath(dir, "SKILL.md")
    if isfile(path) && !ignored(ruleset, path, false)
        add!(skills, names, paths, skillfile(path))
    else
        for entry in readdir(dir)
            startswith(entry, ".") && continue
            entry == "node_modules" && continue
            child = joinpath(dir, entry)
            if isdir(child)
                ignored(ruleset, child, true) && continue
                scan!(skills, names, paths, active, child, mode, false, ruleset)
            elseif isfile(child) && endswith(entry, ".md") && markdown(mode, root)
                ignored(ruleset, child, false) && continue
                add!(skills, names, paths, skillfile(child))
            end
        end
    end
    delete!(active, canonical)
    nothing
end

function roots(cwd, home, agentdir)
    result = Tuple{String, Union{PiDirectory, AgentsDirectory}}[]
    push!(result, (joinpath(cwd, ".pi", "skills"), PiDirectory()))
    useragents = joinpath(home, ".agents", "skills")
    dir = cwd
    while true
        path = joinpath(dir, ".agents", "skills")
        path == useragents || push!(result, (path, AgentsDirectory()))
        ispath(joinpath(dir, ".git")) && break
        parent = dirname(dir)
        parent == dir && break
        dir = parent
    end
    push!(result, (joinpath(agentdir, "skills"), PiDirectory()))
    push!(result, (useragents, AgentsDirectory()))
    result
end

function load(cwd=pwd(); home=homedir(), agentdir=get(ENV, "PI_CODING_AGENT_DIR", joinpath(home, ".pi", "agent")))
    cwd, home, agentdir = abspath.(expanduser.((cwd, home, agentdir)))
    skills = Skill[]
    names = Set{String}()
    paths = Set{String}()
    active = Set{String}()
    for (dir, mode) in roots(cwd, home, agentdir)
        scan!(skills, names, paths, active, dir, mode)
    end
    skills
end

escape(text) = replace(text, "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "\"" => "&quot;", "'" => "&apos;")

function render(skills)
    available = filter(skill -> visible(skill.invocation), skills)
    isempty(available) && return nothing
    lines = ["<skills>", "The following skills provide specialized instructions for specific tasks.", "Use the read tool to load a skill's file when the task matches its description.", "When a skill file references a relative path, resolve it against the skill directory (parent of SKILL.md / dirname of the path) and use that absolute path in tool commands.", "", "<available_skills>"]
    for skill in available
        append!(lines, ["  <skill>", "    <name>$(escape(skill.name))</name>", "    <description>$(escape(skill.description))</description>", "    <location>$(escape(skill.path))</location>", "  </skill>"])
    end
    append!(lines, ["</available_skills>", "</skills>"])
    join(lines, "\n")
end

appendprompt!(messages, ::Nothing) = nothing
appendprompt!(messages, content::AbstractString) = push!(messages, Dict("role" => "system", "content" => content))

end
