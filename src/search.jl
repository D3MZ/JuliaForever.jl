struct Find <: Tool
    cwd::String
end

struct Grep <: Tool
    cwd::String
end

struct FoldedPattern
    text::String
end

Base.occursin(pattern::FoldedPattern, line::AbstractString) = occursin(pattern.text, lowercase(line))

function searchpattern(pattern, literal::Bool, ignorecase::Bool)
    literal && return ignorecase ? FoldedPattern(lowercase(pattern)) : pattern
    Regex(pattern, ignorecase ? "i" : "")
end

name(::Find) = "find"
name(::Grep) = "grep"

schema(::Find) = Dict("type" => "object", "properties" => Dict("pattern" => Dict("type" => "string"), "path" => Dict("type" => "string"), "limit" => Dict("type" => "number")), "required" => ["pattern"])
schema(::Grep) = Dict("type" => "object", "properties" => Dict("pattern" => Dict("type" => "string"), "path" => Dict("type" => "string"), "glob" => Dict("type" => "string"), "ignoreCase" => Dict("type" => "boolean"), "literal" => Dict("type" => "boolean"), "context" => Dict("type" => "number"), "limit" => Dict("type" => "number")), "required" => ["pattern"])

description(::Find) = "Find files and directories by glob pattern, respecting ignore files. Output is limited to 1000 results or 50KB."
description(::Grep) = "Search file contents for a regex or literal pattern, respecting ignore files. Output is limited to 100 matches or 50KB."

function fileurlpath(name, windows=Sys.iswindows())
    uri = HTTP.URI(name)
    path = HTTP.unescapeuri(uri.path)
    windows && !isempty(uri.host) && lowercase(uri.host) != "localhost" && return "//$(uri.host)$path"
    windows && occursin(r"^/[A-Za-z]:/", path) && return path[2:end]
    path
end

function searchpath(tool, name)
    name = isempty(name) ? "." : name
    name = replace(name, r"[\u00a0\u2000-\u200a\u202f\u205f\u3000]" => " ")
    name = chopprefix(name, "@")
    startswith(name, "file://") && (name = fileurlpath(name))
    abspath(path(tool, name))
end

# Convert the common glob syntax to a regular expression without invoking another tool.
function globsource(pattern)
    chars = collect(pattern)
    out = IOBuffer()
    i = 1
    while i <= length(chars)
        c = chars[i]
        if c == '*'
            if i < length(chars) && chars[i + 1] == '*'
                i += 1
                if i < length(chars) && chars[i + 1] == '/'
                    print(out, "(?:.*/)?")
                    i += 1
                else
                    print(out, ".*")
                end
            else
                print(out, "[^/]*")
            end
        elseif c == '?'
            print(out, "[^/]")
        elseif c == '['
            stop = findnext(==(']'), chars, i + 1)
            if isnothing(stop)
                print(out, "\\[")
            else
                part = String(chars[(i + 1):(stop - 1)])
                startswith(part, '!') && (part = "^" * part[nextind(part, firstindex(part)):end])
                print(out, "[", part, "]")
                i = stop
            end
        elseif c == '{'
            print(out, "(?:")
        elseif c == '}'
            print(out, ")")
        elseif c == ',' && '{' in chars[1:i-1] && '}' in chars[i+1:end]
            print(out, "|")
        elseif c in ('.', '+', '(', ')', '|', '^', '$', '\\')
            print(out, '\\', c)
        else
            print(out, c)
        end
        i += 1
    end
    String(take!(out))
end

function glob(pattern; smartcase=false, anywhere=false)
    source = globsource(pattern)
    prefix = anywhere ? "(?:.*/)?" : ""
    Regex("^" * prefix * source * "\$", smartcase && !any(isuppercase, pattern) ? "i" : "")
end

posix(path) = Sys.iswindows() ? replace(path, '\\' => '/') : path

abstract type IgnoreRule end

struct GitRule <: IgnoreRule
    base::String
    regex::Regex
    directory::Bool
    negate::Bool
end

struct FileRule <: IgnoreRule
    base::String
    regex::Regex
    directory::Bool
    negate::Bool
end

function cleargit!(rules)
    kept = 0
    for rule in rules
        kept = cleargit!(rules, kept, rule)
    end
    resize!(rules, kept)
end
cleargit!(rules, kept, ::GitRule) = kept
cleargit!(rules, kept, rule::FileRule) = (rules[kept + 1] = rule; kept + 1)

function rules(file, ::Type{T}; base=dirname(file)) where {T <: IgnoreRule}
    isfile(file) || return IgnoreRule[]
    result = IgnoreRule[]
    for line in eachline(file)
        line = rstrip(line)
        (isempty(line) || startswith(line, '#')) && continue
        negate = startswith(line, '!')
        negate && (line = chopprefix(line, "!"))
        isempty(line) && continue
        directory = endswith(line, '/')
        directory && (line = chop(line))
        anchored = startswith(line, '/')
        anchored && (line = chopprefix(line, "/"))
        isempty(line) && continue
        push!(result, T(base, glob(line; anywhere=!anchored && !occursin('/', line)), directory, negate))
    end
    result
end

function ignored(rules, target, directory)
    value = false
    for rule in rules
        rule.directory && !directory && continue
        relative = posix(relpath(target, rule.base))
        startswith(relative, "../") && continue
        occursin(rule.regex, relative) && (value = !rule.negate)
    end
    value
end

function ancestors(root)
    dirs = String[]
    current = dirname(root)
    while true
        pushfirst!(dirs, current)
        parent = dirname(current)
        parent == current && break
        current = parent
    end
    dirs
end

gitignore!(result, dir, ::Find, repo) = append!(result, rules(joinpath(dir, ".gitignore"), GitRule))
gitignore!(result, dir, ::Grep, ::Nothing) = nothing
gitignore!(result, dir, ::Grep, repo::AbstractString) = append!(result, rules(joinpath(dir, ".gitignore"), GitRule))
reposcope(::Nothing, dirs, i) = nothing
reposcope(repo::Integer, dirs, i) = i >= repo ? dirs[repo] : nothing

function initialrules(root, tool::Union{Find, Grep})
    dirs = ancestors(root)
    locations = [dirs; root]
    repo = findlast(dir -> ispath(joinpath(dir, ".git")), locations)
    result = IgnoreRule[]
    for (i, dir) in enumerate(dirs)
        if ispath(joinpath(dir, ".git"))
            cleargit!(result)
            append!(result, rules(joinpath(dir, ".git", "info", "exclude"), GitRule; base=dir))
        end
        gitignore!(result, dir, tool, reposcope(repo, locations, i))
        append!(result, rules(joinpath(dir, ".ignore"), FileRule))
    end
    result, reposcope(repo, locations, length(locations))
end

function walksearch(visit, root, tool::Union{Find, Grep}; whitelist=(target -> false))
    inherited, inside = initialrules(root, tool)
    function walk(dir, inherited, inside)
        ruleset = copy(inherited)
        if ispath(joinpath(dir, ".git"))
            cleargit!(ruleset)
            append!(ruleset, rules(joinpath(dir, ".git", "info", "exclude"), GitRule; base=dir))
            inside = dir
        end
        gitignore!(ruleset, dir, tool, inside)
        append!(ruleset, rules(joinpath(dir, ".ignore"), FileRule))
        for entry in readdir(dir)
            entry == ".git" && continue
            target = joinpath(dir, entry)
            directory = isdir(target) && !islink(target)
            ignored(ruleset, target, directory) && (directory || !whitelist(target)) && continue
            visit(target, directory) || return false
            directory && !walk(target, ruleset, inside) && return false
        end
        true
    end
    walk(root, inherited, inside)
end

function searchresult(lines, limit, label; truncatedlines=false)
    isempty(lines) && return ToolResult(label == "results" ? "No files found matching pattern" : "No matches found")
    output, truncated = head(lines)
    notices = String[]
    length(lines) >= limit && push!(notices, "$limit $label limit reached. Use limit=$(limit * 2) for more, or refine pattern")
    truncated && push!(notices, "50.0KB limit reached")
    truncatedlines && push!(notices, "Some lines truncated to 500 chars. Use read tool to see full lines")
    !isempty(notices) && (output *= "\n\n[$(join(notices, ". "))]")
    ToolResult(output)
end

function execute(tool::Find, args)
    root = searchpath(tool, get(args, :path, "."))
    isdir(root) || return ToolFailure("[fd error]: Search path '$root' is not a directory.\n[fd error]: No valid search paths given.")
    limit = Int(get(args, :limit, 1000))
    limit >= 0 || return ToolFailure("Invalid result limit: $limit")
    pattern = args.pattern
    regex = try
        glob(pattern; smartcase=true, anywhere=occursin('/', pattern) && !startswith(pattern, '/'))
    catch exception
        return ToolFailure(sprint(showerror, exception))
    end
    found = String[]
    walksearch(root, tool) do target, directory
        relative = posix(relpath(target, root))
        candidate = occursin('/', pattern) ? (startswith(pattern, '/') ? posix(target) : relative) : basename(target)
        if occursin(regex, candidate)
            push!(found, directory ? relative * "/" : rstrip(relative))
            limit > 0 && length(found) >= limit && return false
        end
        true
    end
    searchresult(found, limit, "results")
end

function shortline(line)
    units = transcode(UInt16, line)
    length(units) <= 500 && return line, false
    units = units[1:500]
    # Julia strings cannot encode an unpaired UTF-16 surrogate.
    0xd800 <= units[end] <= 0xdbff && (units[end] = 0xfffd)
    String(transcode(UInt8, units)) * "... [truncated]", true
end

function execute(tool::Grep, args)
    root = searchpath(tool, get(args, :path, "."))
    ispath(root) || return ToolFailure("Path not found: $root")
    limit = max(1, Int(get(args, :limit, 100)))
    context = max(0, Int(get(args, :context, 0)))
    regex = try
        searchpattern(args.pattern, get(args, :literal, false), get(args, :ignoreCase, false))
    catch exception
        return ToolFailure(sprint(showerror, exception))
    end
    filterpattern = get(args, :glob, "")
    exclude = startswith(filterpattern, "!")
    exclude && (filterpattern = chopprefix(filterpattern, "!"))
    filterregex = try
        isempty(filterpattern) ? nothing : glob(filterpattern)
    catch exception
        return ToolFailure(sprint(showerror, exception))
    end
    output = String[]
    count = 0
    truncatedlines = false
    directory = isdir(root)
    function selected(target)
        isnothing(filterregex) && return true
        candidate = occursin('/', filterpattern) ? posix(target) : basename(target)
        occursin(filterregex, candidate) != exclude
    end
    function visit(target, isdirectory)
        isdirectory && return true
        isfile(target) || return true
        relative = directory ? posix(relpath(target, root)) : basename(target)
        selected(target) || return true
        bytes = read(target)
        0x00 in bytes && return true
        text = String(bytes)
        isvalid(text) || return true
        isempty(text) && return true
        lines = split(replace(text, "\r\n" => "\n"), '\n'; keepempty=true)
        lastmatch = length(lines) - endswith(text, '\n')
        for number in 1:lastmatch
            line = lines[number]
            matched = occursin(regex, line)
            matched || continue
            count += 1
            for n in max(1, number - context):min(length(lines), number + context)
                shown, shortened = shortline(replace(lines[n], '\r' => ""))
                truncatedlines |= shortened
                push!(output, n == number ? "$relative:$n: $shown" : "$relative-$n- $shown")
            end
            count >= limit && return false
        end
        true
    end
    whitelist = target -> !isnothing(filterregex) && !exclude && selected(target)
    directory ? walksearch(visit, root, tool; whitelist) : visit(root, false)
    isempty(output) && return ToolResult("No matches found")
    # Match limits count matches, not context rows.
    limited = count >= limit
    text, truncated = head(output)
    notices = String[]
    limited && push!(notices, "$limit matches limit reached. Use limit=$(limit * 2) for more, or refine pattern")
    truncated && push!(notices, "50.0KB limit reached")
    truncatedlines && push!(notices, "Some lines truncated to 500 chars. Use read tool to see full lines")
    !isempty(notices) && (text *= "\n\n[$(join(notices, ". "))]")
    ToolResult(text)
end
