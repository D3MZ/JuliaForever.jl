struct Find <: Tool
    cwd::String
end

struct Grep <: Tool
    cwd::String
end

struct FoldedPattern
    text::String
    folded::String
    ascii::String
end

# Separators keep full-fold expansions inside their original character boundaries.
const foldescapes = Dict('\0' => "\x01\x02", '\x01' => "\x01\x01")

# Memoize only after a longer line contains several non-ASCII characters.
mutable struct FoldCache
    seen::Int
    values::Dict{Char, String}
end
FoldCache() = FoldCache(0, Dict{Char, String}())

foldliteral(text::AbstractString) = foldliteral(text, ncodeunits(text) < 128 ? nothing : FoldCache())
function foldliteral(text::AbstractString, cache)
    output = IOBuffer()
    for character in text
        write(output, '\0')
        if !isvalid(character)
            # This sequence cannot occur in a folded valid character.
            write(output, "\x01\x03")
        elseif isascii(character)
            write(output, get(foldescapes, character, lowercase(character)))
        else
            writefolded!(output, cache, character)
        end
    end
    write(output, '\0')
    String(take!(output))
end

writefolded!(output, ::Nothing, character::Char) = write(output, Unicode.normalize(string(character); casefold=true, compose=false))
function writefolded!(output, cache::FoldCache, character::Char)
    cache.seen += 1
    cache.seen < 8 && return writefolded!(output, nothing, character)
    # Titlecase characters are neither lowercase nor uppercase, but have lowercase mappings.
    if islowercase(character) || isuppercase(character) || lowercase(character) != character
        folded = get!(cache.values, character) do
            Unicode.normalize(string(character); casefold=true, compose=false)
        end
        return write(output, folded)
    end
    write(output, character)
end

function Base.occursin(pattern::FoldedPattern, line::AbstractString)
    isascii(pattern.text) && isascii(line) && return occursin(pattern.ascii, lowercase(line))
    occursin(pattern.folded, foldliteral(line))
end
literalpattern(pattern) = pattern
foldedpattern(pattern) = FoldedPattern(String(pattern), foldliteral(pattern), lowercase(pattern))
regexpattern(pattern) = Regex(pattern, "")
caselesspattern(pattern) = Regex(pattern, "i")
const searchpatterns = Dict((true, false) => literalpattern, (true, true) => foldedpattern, (false, false) => regexpattern, (false, true) => caselesspattern)
searchpattern(pattern, literal::Bool, ignorecase::Bool) = searchpatterns[(literal, ignorecase)](pattern)

name(::Find) = "find"
name(::Grep) = "grep"

schema(::Find) = Dict("type" => "object", "properties" => Dict("pattern" => Dict("type" => "string"), "path" => Dict("type" => "string"), "limit" => Dict("type" => "number")), "required" => ["pattern"])
schema(::Grep) = Dict("type" => "object", "properties" => Dict("pattern" => Dict("type" => "string"), "path" => Dict("type" => "string"), "glob" => Dict("type" => "string"), "ignoreCase" => Dict("type" => "boolean"), "literal" => Dict("type" => "boolean"), "context" => Dict("type" => "number"), "limit" => Dict("type" => "number")), "required" => ["pattern"])

description(::Find) = "Find files and directories by glob pattern, respecting ignore files. Output is limited to 1000 results or 50KB."
description(::Grep) = "Search file contents for a regex or literal pattern, respecting ignore files. Output is limited to 100 matches or 50KB."

unixfileurl(uri) = HTTP.unescapeuri(uri.path)
function windowsfileurl(uri)
    path = HTTP.unescapeuri(uri.path)
    !isempty(uri.host) && lowercase(uri.host) != "localhost" && return "//$(uri.host)$path"
    occursin(r"^/[A-Za-z]:/", path) && return path[2:end]
    path
end
const fileurlreaders = Dict(false => unixfileurl, true => windowsfileurl)
fileurlpath(name, windows::Bool=Sys.iswindows()) = fileurlreaders[windows](HTTP.URI(name))

function searchpath(tool, name)
    name = isempty(name) ? "." : name
    name = replace(name, r"[\u00a0\u2000-\u200a\u202f\u205f\u3000]" => " ")
    name = chopprefix(name, "@")
    startswith(name, "file://") && (name = fileurlpath(name))
    abspath(path(tool, name))
end

globclass!(out, chars, i, ::Nothing) = (print(out, "\\["); i)
function globclass!(out, chars, i, stop::Integer)
    part = String(chars[(i + 1):(stop - 1)])
    startswith(part, '!') && (part = "^" * part[nextind(part, firstindex(part)):end])
    print(out, "[", part, "]")
    stop
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
            i = globclass!(out, chars, i, findnext(==(']'), chars, i + 1))
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

rootglob(source) = source
anyglob(source) = "(?:.*/)?" * source
caseflags(pattern) = ""
smartflags(pattern) = any(isuppercase, pattern) ? "" : "i"
const globprefixes = Dict(false => rootglob, true => anyglob)
const globcases = Dict(false => caseflags, true => smartflags)
glob(pattern; smartcase::Bool=false, anywhere::Bool=false) = glob(pattern, globprefixes[anywhere], globcases[smartcase])
glob(pattern, scope, flags) = Regex("^" * scope(globsource(pattern)) * "\$", flags(pattern))

posix(path) = Sys.iswindows() ? replace(path, '\\' => '/') : path

abstract type SearchEntry end
struct SearchFile{P<:AbstractString} <: SearchEntry
    path::P
end
struct SearchDirectory{P<:AbstractString} <: SearchEntry
    path::P
end
const searchentries = Dict(false => SearchFile, true => SearchDirectory)
searchentry(path, directory::Bool) = searchentries[directory](path)

abstract type IgnoreRule end

struct GitRule{P} <: IgnoreRule
    base::String
    pattern::P
end

struct FileRule{P} <: IgnoreRule
    base::String
    pattern::P
end

struct DirectoryPattern
    regex::Regex
end
struct IgnorePattern{P}
    pattern::P
end
struct IncludePattern{P}
    pattern::P
end
const ignorescopes = Dict(true => DirectoryPattern, false => identity)
const ignoreactions = Dict(true => IncludePattern, false => IgnorePattern)

matchesignore(pattern::Regex, relative, entry::SearchEntry) = occursin(pattern, relative)
matchesignore(pattern::DirectoryPattern, relative, ::SearchFile) = false
matchesignore(pattern::DirectoryPattern, relative, ::SearchDirectory) = occursin(pattern.regex, relative)
ignorevalue(previous, pattern::IgnorePattern, relative, entry) = matchesignore(pattern.pattern, relative, entry) ? true : previous
ignorevalue(previous, pattern::IncludePattern, relative, entry) = matchesignore(pattern.pattern, relative, entry) ? false : previous

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
        action = ignoreactions[startswith(line, '!')]
        line = chopprefix(line, "!")
        isempty(line) && continue
        scope = ignorescopes[endswith(line, '/')]
        line = chopsuffix(line, "/")
        anchored = startswith(line, '/')
        line = chopprefix(line, "/")
        isempty(line) && continue
        pattern = scope(glob(line, globprefixes[!anchored && !occursin('/', line)], caseflags))
        push!(result, T(base, action(pattern)))
    end
    result
end

ignorevalue(value, rule::IgnoreRule, entry, ::Type{T}) where {T <: IgnoreRule} = value
function ignorevalue(value, rule::T, entry, ::Type{T}) where {T <: IgnoreRule}
    relative = posix(relpath(entry.path, rule.base))
    startswith(relative, "../") && return value
    ignorevalue(value, rule.pattern, relative, entry)
end

function ignored(kind::Type{T}, rules, entry, value) where {T <: IgnoreRule}
    for rule in rules
        value = ignorevalue(value, rule, entry, kind)
    end
    value
end

# .ignore rules take precedence over .gitignore, even across directory levels.
ignored(rules, target, directory::Bool) = ignored(rules, searchentry(target, directory))
ignored(rules, entry::SearchEntry) = ignored(FileRule, rules, entry, ignored(GitRule, rules, entry, false))

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
            item = searchentry(target, isdir(target) && !islink(target))
            skipentry(ruleset, item, whitelist) && continue
            visit(item) || return false
            walkentry(walk, item, ruleset, inside) || return false
        end
        true
    end
    walk(root, inherited, inside)
end
skipentry(rules, entry::SearchDirectory, whitelist) = ignored(rules, entry)
skipentry(rules, entry::SearchFile, whitelist) = ignored(rules, entry) && !whitelist(entry.path)
walkentry(walk, entry::SearchDirectory, rules, inside) = walk(entry.path, rules, inside)
walkentry(walk, entry::SearchFile, rules, inside) = true

function findresult(lines, limit)
    isempty(lines) && return ToolResult("No files found matching pattern")
    bounded = head(lines)
    notices = String[]
    length(lines) >= limit && push!(notices, "$limit results limit reached. Use limit=$(limit * 2) for more, or refine pattern")
    headnotice!(notices, bounded)
    output = headtext(bounded)
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
        glob(pattern, globprefixes[occursin('/', pattern) && !startswith(pattern, '/')], smartflags)
    catch exception
        return ToolFailure(sprint(showerror, exception))
    end
    found = String[]
    walksearch(root, tool) do entry
        target = entry.path
        relative = posix(relpath(target, root))
        candidate = occursin('/', pattern) ? (startswith(pattern, '/') ? posix(target) : relative) : basename(target)
        if occursin(regex, candidate)
            push!(found, findpath(entry, relative))
            limit > 0 && length(found) >= limit && return false
        end
        true
    end
    findresult(found, limit)
end
findpath(::SearchDirectory, relative) = relative * "/"
findpath(::SearchFile, relative) = rstrip(relative)

struct ShortenedLine
    text::String
end

linetext(line::AbstractString) = line
linetext(line::ShortenedLine) = line.text
linenotice!(notices, ::AbstractString) = nothing
linenotice!(notices, ::ShortenedLine) = push!(notices, "Some lines truncated to 500 chars. Use read tool to see full lines")

function shortline(line)
    units = transcode(UInt16, line)
    length(units) <= 500 && return line
    units = units[1:500]
    # Julia strings cannot encode an unpaired UTF-16 surrogate.
    0xd800 <= units[end] <= 0xdbff && (units[end] = 0xfffd)
    ShortenedLine(String(transcode(UInt8, units)) * "... [truncated]")
end

struct GlobFilter
    pattern::String
    regex::Regex
end

struct ExcludedGlob
    filter::GlobFilter
end

function globfilter(raw::AbstractString)
    pattern = chopprefix(raw, "!")
    isempty(pattern) && return nothing
    filter = GlobFilter(pattern, glob(pattern, rootglob, caseflags))
    (identity, ExcludedGlob)[Int(startswith(raw, "!")) + 1](filter)
end

globtarget(filter::GlobFilter, target) = occursin('/', filter.pattern) ? posix(target) : basename(target)
selectglob(::Nothing, target) = true
selectglob(filter::GlobFilter, target) = occursin(filter.regex, globtarget(filter, target))
selectglob(filter::ExcludedGlob, target) = !selectglob(filter.filter, target)
whitelistglob(::Union{Nothing, ExcludedGlob}, target) = false
whitelistglob(filter::GlobFilter, target) = selectglob(filter, target)

function decoded(bytes)
    text = String(copy(bytes))
    isvalid(text) && return text
    out = IOBuffer()
    i = 1
    while i <= length(bytes)
        b = bytes[i]
        size = b < 0x80 ? 1 : 0xc2 <= b <= 0xdf ? 2 : 0xe0 <= b <= 0xef ? 3 : 0xf0 <= b <= 0xf4 ? 4 : 0
        if size == 0
            print(out, '�')
            i += 1
            continue
        end
        j = i + 1
        while j < i + size && j <= length(bytes)
            c = bytes[j]
            low = j == i + 1 && b == 0xe0 ? 0xa0 : j == i + 1 && b == 0xf0 ? 0x90 : 0x80
            high = j == i + 1 && b == 0xed ? 0x9f : j == i + 1 && b == 0xf4 ? 0x8f : 0xbf
            low <= c <= high || break
            j += 1
        end
        if j == i + size
            write(out, @view bytes[i:j-1])
        else
            print(out, '�')
        end
        i = j
    end
    String(take!(out))
end

originallines!(cache, original, raw, rawlines) = originallines!(cache, original, raw, rawlines, cache[])
originallines!(cache, original, raw, rawlines, cached::Vector) = cached
function originallines!(cache, original, raw, rawlines, ::Nothing)
    lines = original === raw && isvalid(raw) ? rawlines : split(replace(decoded(codeunits(original)), "\r\n" => "\n"), '\n'; keepempty=true)
    cache[] = lines
    lines
end

function binaryprefix(bytes, nul)
    # A binary read is discarded; incomplete lines carry over as the buffer grows.
    capacity = 65536
    position = 0
    consumed = 0
    while position < nul
        retained = position - consumed
        retained == capacity && (capacity *= 3)
        stop = min(length(bytes), position + capacity - retained)
        nul <= stop && return consumed
        consumed = lineprefix(consumed, position, findprev(==(0x0a), bytes, stop))
        position = stop
    end
    consumed
end
lineprefix(consumed, position, ::Nothing) = consumed
lineprefix(consumed, position, lastline::Int) = lastline > position ? lastline : consumed

binarycontent!(bytes, ::SearchDirectory, nul) = resize!(bytes, binaryprefix(bytes, nul))
binarycontent!(bytes, ::SearchFile, nul) = replace!(bytes, 0x00 => 0x0a)
function searchcontent(bytes, root, ::Nothing)
    raw = String(bytes)
    raw, raw
end
function searchcontent(bytes, root, nul::Int)
    original = String(copy(bytes))
    binarycontent!(bytes, root, nul)
    original, String(bytes)
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
    filter = try
        globfilter(get(args, :glob, ""))
    catch exception
        return ToolFailure(sprint(showerror, exception))
    end
    output = String[]
    count = 0
    linenotices = Set{String}()
    rootentry = searchentry(root, isdir(root))
    visit(::SearchDirectory) = true
    function visit(entry::SearchFile)
        target = entry.path
        isfile(target) || return true
        relative = searchrelative(rootentry, target)
        selectglob(filter, target) || return true
        bytes = read(target)
        originalraw, raw = searchcontent(bytes, rootentry, findfirst(==(0x00), bytes))
        isempty(raw) && return true
        rawlines = split(replace(raw, "\r\n" => "\n"), '\n'; keepempty=true)
        original_lines = Ref{Union{Nothing,Vector{SubString{String}}}}(nothing)
        lastmatch = length(rawlines) - endswith(raw, '\n')
        for number in 1:lastmatch
            line = rawlines[number]
            occursin(regex, line) || continue
            count += 1
            displaylines = context > 0 || !isvalid(line) ? originallines!(original_lines, originalraw, raw, rawlines) : rawlines
            lastline = context > 0 ? min(length(displaylines), number + context) : number
            for n in max(1, number - context):lastline
                shown = shortline(replace(get(displaylines, n, ""), '\r' => ""))
                linenotice!(linenotices, shown)
                text = linetext(shown)
                push!(output, n == number ? "$relative:$n: $text" : "$relative-$n- $text")
            end
            count >= limit && return false
        end
        true
    end
    whitelist = target -> whitelistglob(filter, target)
    visitroot(visit, rootentry, tool, whitelist)
    isempty(output) && return ToolResult("No matches found")
    # Match limits count matches, not context rows.
    bounded = head(output)
    notices = String[]
    count >= limit && push!(notices, "$limit matches limit reached. Use limit=$(limit * 2) for more, or refine pattern")
    headnotice!(notices, bounded)
    text = headtext(bounded)
    append!(notices, linenotices)
    !isempty(notices) && (text *= "\n\n[$(join(notices, ". "))]")
    ToolResult(text)
end
searchrelative(root::SearchDirectory, target) = posix(relpath(target, root.path))
searchrelative(root::SearchFile, target) = basename(target)
visitroot(visit, root::SearchDirectory, tool, whitelist) = walksearch(visit, root.path, tool; whitelist)
visitroot(visit, root::SearchFile, tool, whitelist) = visit(root)
