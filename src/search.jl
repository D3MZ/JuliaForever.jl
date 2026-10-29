struct Find <: Tool
    cwd::String
end

struct Grep <: Tool
    cwd::String
end

name(::Find) = "find"
name(::Grep) = "grep"

schema(::Find) = Dict("type" => "object", "properties" => Dict("pattern" => Dict("type" => "string"), "path" => Dict("type" => "string"), "limit" => Dict("type" => "number")), "required" => ["pattern"])
schema(::Grep) = Dict("type" => "object", "properties" => Dict("pattern" => Dict("type" => "string"), "path" => Dict("type" => "string"), "glob" => Dict("type" => "string"), "ignoreCase" => Dict("type" => "boolean"), "literal" => Dict("type" => "boolean"), "context" => Dict("type" => "number"), "limit" => Dict("type" => "number")), "required" => ["pattern"])

description(::Find) = "Find files and directories by glob pattern, respecting ignore files. Output is limited to 1000 results or 50KB."
description(::Grep) = "Search file contents for a regex or literal pattern, respecting ignore files. Output is limited to 100 matches or 50KB."

function searchpath(tool, name)
    name = isempty(name) ? "." : name
    name = replace(name, r"[\u00a0\u2000-\u200a\u202f\u205f\u3000]" => " ")
    name = chopprefix(name, "@")
    startswith(name, "file://") && (name = HTTP.unescapeuri(HTTP.URI(name).path))
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

struct IgnoreRule
    base::String
    regex::Regex
    directory::Bool
    negate::Bool
    git::Bool
end

function rules(file, git; base=dirname(file))
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
        push!(result, IgnoreRule(base, glob(line; anywhere=!anchored && !occursin('/', line)), directory, negate, git))
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

function initialrules(root, findmode)
    dirs = ancestors(root)
    repo = findlast(dir -> ispath(joinpath(dir, ".git")), [dirs; root])
    result = IgnoreRule[]
    for (i, dir) in enumerate(dirs)
        if ispath(joinpath(dir, ".git"))
            filter!(rule -> !rule.git, result)
            append!(result, rules(joinpath(dir, ".git", "info", "exclude"), true; base=dir))
        end
        (findmode || (!isnothing(repo) && i >= repo)) && append!(result, rules(joinpath(dir, ".gitignore"), true))
        append!(result, rules(joinpath(dir, ".ignore"), false))
    end
    result, findmode || !isnothing(repo)
end

function walksearch(visit, root, findmode; whitelist=(target -> false))
    inherited, inside = initialrules(root, findmode)
    function walk(dir, inherited, inside)
        ruleset = copy(inherited)
        if ispath(joinpath(dir, ".git"))
            filter!(rule -> !rule.git, ruleset)
            append!(ruleset, rules(joinpath(dir, ".git", "info", "exclude"), true; base=dir))
            inside = true
        end
        (findmode || inside) && append!(ruleset, rules(joinpath(dir, ".gitignore"), true))
        append!(ruleset, rules(joinpath(dir, ".ignore"), false))
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
    isdir(root) || return ToolResult("[fd error]: Search path '$root' is not a directory.\n[fd error]: No valid search paths given.", true)
    limit = Int(get(args, :limit, 1000))
    limit >= 0 || return ToolResult("Invalid result limit: $limit", true)
    pattern = args.pattern
    regex = try
        glob(pattern; smartcase=true, anywhere=occursin('/', pattern) && !startswith(pattern, '/'))
    catch exception
        return ToolResult(sprint(showerror, exception), true)
    end
    found = String[]
    walksearch(root, true) do target, directory
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
    ispath(root) || return ToolResult("Path not found: $root", true)
    limit = max(1, Int(get(args, :limit, 100)))
    context = max(0, Int(get(args, :context, 0)))
    pattern = args.pattern
    literal = get(args, :literal, false)
    ignorecase = get(args, :ignoreCase, false)
    regex = try
        literal ? nothing : Regex(pattern, ignorecase ? "i" : "")
    catch exception
        return ToolResult(sprint(showerror, exception), true)
    end
    filterpattern = get(args, :glob, "")
    exclude = startswith(filterpattern, "!")
    exclude && (filterpattern = chopprefix(filterpattern, "!"))
    filterregex = try
        isempty(filterpattern) ? nothing : glob(filterpattern)
    catch exception
        return ToolResult(sprint(showerror, exception), true)
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
            matched = literal ? occursin(ignorecase ? lowercase(pattern) : pattern, ignorecase ? lowercase(line) : line) : occursin(regex, line)
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
    directory ? walksearch(visit, root, false; whitelist) : visit(root, false)
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
