module Instructions

const names = ("AGENTS.override.md", "AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD")

function file(dir)
    for name in names
        path = joinpath(dir, name)
        isfile(path) || continue
        content = String(chopprefix(read(path, String), "\ufeff"))
        return (; path, content)
    end
    nothing
end

function gitpaths(cwd)
    dir = cwd
    while true
        path = joinpath(dir, ".git")
        if isfile(path)
            content = strip(read(path, String))
            if startswith(content, "gitdir: ")
                gitdir = abspath(joinpath(dir, strip(content[9:end])))
                ispath(joinpath(gitdir, "HEAD")) || return nothing
                common = joinpath(gitdir, "commondir")
                return (; root=dir, common=ispath(common) ? abspath(joinpath(gitdir, strip(read(common, String)))) : gitdir)
            end
        elseif isdir(path)
            ispath(joinpath(path, "HEAD")) || return nothing
            return (; root=dir, common=path)
        end
        parent = dirname(dir)
        parent == dir && return nothing
        dir = parent
    end
end

canonical(path) = ispath(path) ? realpath(path) : path

shadow(cwd::AbstractString) = shadow(gitpaths(cwd))
shadow(::Nothing) = nothing

function shadow(git::NamedTuple)
    common = canonical(git.common)
    worktree = canonical(git.root)
    main = dirname(common)
    startswith(worktree, joinpath(main, "")) || return nothing
    canonical(joinpath(main, ".git")) == common || return nothing
    shadow(main, file(worktree))
end

shadow(main, ::Nothing) = nothing
shadow(main, context::NamedTuple) = joinpath(main, basename(context.path))

load!(files, seen, ::Nothing) = nothing
load!(files, seen, dir::AbstractString) = load!(files, seen, file(abspath(expanduser(dir))))

function load!(files, seen, context::NamedTuple)
    push!(files, context)
    push!(seen, context.path)
    nothing
end

shadowed(::Nothing, dir, context) = false
shadowed(path::AbstractString, dir, context) = joinpath(canonical(dir), basename(context.path)) == path
load!(files, seen, dir, ::Nothing, shadow) = nothing

function load!(files, seen, dir, context::NamedTuple, shadow)
    shadowed(shadow, dir, context) && return nothing
    context.path in seen && return nothing
    load!(files, seen, context)
end

"""
    load(cwd=pwd(); agentdir=nothing)

Read instruction files from an optional agent directory and `cwd`'s ancestors.
Return `(path, content)` named tuples in global-then-root-to-leaf order.
See `docs/instructions.md` for precedence and compatibility boundaries.
"""
function load(cwd=pwd(); agentdir=nothing)
    cwd = abspath(expanduser(cwd))
    files = NamedTuple{(:path, :content), Tuple{String, String}}[]
    seen = Set{String}()
    load!(files, seen, agentdir)
    ancestors = similar(files, 0)
    shadowed = shadow(cwd)
    dir = cwd
    while true
        load!(ancestors, seen, dir, file(dir), shadowed)
        parent = dirname(dir)
        parent == dir && break
        dir = parent
    end
    append!(files, Iterators.reverse(ancestors))
end

"""Render loaded files as a project-context section, or return `nothing` when empty."""
function render(files)
    isempty(files) && return nothing
    sections = ["<project_instructions path=\"$(file.path)\">\n$(file.content)\n</project_instructions>" for file in files]
    "<project_context>\nProject-specific instructions and guidelines:\n\n$(join(sections, "\n\n"))\n</project_context>"
end

end
