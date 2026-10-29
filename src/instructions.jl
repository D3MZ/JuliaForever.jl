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

function shadow(cwd)
    git = gitpaths(cwd)
    isnothing(git) && return nothing
    common = canonical(git.common)
    worktree = canonical(git.root)
    main = dirname(common)
    startswith(worktree, joinpath(main, "")) || return nothing
    canonical(joinpath(main, ".git")) == common || return nothing
    context = file(worktree)
    isnothing(context) ? nothing : joinpath(main, basename(context.path))
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
    if !isnothing(agentdir)
        globalfile = file(abspath(expanduser(agentdir)))
        if !isnothing(globalfile)
            push!(files, globalfile)
            push!(seen, globalfile.path)
        end
    end
    ancestors = similar(files, 0)
    shadowed = shadow(cwd)
    dir = cwd
    while true
        context = file(dir)
        if !isnothing(context) && (isnothing(shadowed) || joinpath(canonical(dir), basename(context.path)) != shadowed) && !(context.path in seen)
            push!(ancestors, context)
            push!(seen, context.path)
        end
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
