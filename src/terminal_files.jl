abstract type FileKind end
struct File <: FileKind end
struct Directory <: FileKind end
abstract type FileRequest end
struct Automatic <: FileRequest end
struct Forced <: FileRequest end
struct Explicit <: FileRequest end
abstract type SearchState end
struct Searching <: SearchState end
struct Stopped <: SearchState end
const requests = Dict(false => Automatic(), true => Forced())
const searchstates = Dict(false => Stopped(), true => Searching())

struct PathItem{K<:FileKind}
    value::String
    label::String
    description::String
    kind::K
end

const PathItems = Vector{Union{PathItem{File}, PathItem{Directory}}}
const filekinds = Dict(false => File(), true => Directory())

struct Files
    prefix::String
    items::PathItems
end

const wrappers = Dict('(' => ')', '[' => ']', '{' => '}', '<' => '>', '`' => '`')
const punctuation = Set("，．：；！？（）［］｛｝“”‘’…—")
separator(c::Char) = isspace(c) || c in punctuation || ('\u3000' <= c <= '\u303f' && ispunct(c))
delimiter(c::Char) = separator(c) || c in ('"', '\'', '=')

function tokenstart(text, index)
    current = index
    while current > firstindex(text)
        previous = prevind(text, current)
        haskey(wrappers, text[previous]) || return delimiter(text[previous])
        current = previous
    end
    true
end

function quotedprefix(text)
    quotes = findall(==('"'), text)
    iseven(length(quotes)) && return nothing
    index = last(quotes)
    if index > firstindex(text) && text[prevind(text, index)] == '@'
        index = prevind(text, index)
    end
    tokenstart(text, index) ? String(text[index:end]) : nothing
end

function unquotedprefix(text)
    index = findlast(delimiter, text)
    token = tokenafter(text, index)
    while !isempty(token) && haskey(wrappers, first(token))
        closer = wrappers[first(token)]
        rest = token[nextind(token, firstindex(token)):end]
        occursin(closer, rest) && break
        token = rest
    end
    token
end
tokenafter(text, ::Nothing) = String(text)
tokenafter(text, index::Int) = String(text[nextind(text, index):end])

function atprefix(text)
    line = last(split(text, '\n'))
    quoted = quotedprefix(line)
    atquoted(quoted, line)
end
atquoted(prefix::AbstractString, line) = startswith(prefix, "@\"") ? String(prefix) : atquoted(nothing, line)
function atquoted(::Nothing, line)
    token = unquotedprefix(line)
    startswith(token, "@") ? token : nothing
end

function pathprefix(text, force)
    line = last(split(text, '\n'))
    prefix = quotedprefix(line)
    pathprefix(prefix, line, force)
end
pathprefix(prefix::AbstractString, line, request) = String(prefix)
pathprefix(::Nothing, line, request) = pathcandidate(unquotedprefix(line), line, request)
pathcandidate(token::AbstractString, line, ::Union{Forced, Explicit}) = token
function pathcandidate(token::AbstractString, line, ::Automatic)
    (occursin('/', token) || startswith(token, '.') || startswith(token, "~/") || (isempty(token) && !isempty(line) && separator(last(line)))) ? token : nothing
end

abstract type PathStyle end
struct Attached <: PathStyle end
struct Ordinary <: PathStyle end
abstract type Quoting end
struct Quoted <: Quoting end
struct Unquoted <: Quoting end
const quotings = Dict(false => Unquoted(), true => Quoted())
pathstyle(prefix) = startswith(prefix, '@') ? Attached() : Ordinary()
rawprefix(prefix, ::Attached) = chopprefix(prefix, "@")
rawprefix(prefix, ::Ordinary) = prefix
unquote(raw, ::Quoted) = chopprefix(raw, "\"")
unquote(raw, ::Unquoted) = raw

function pathparts(prefix)
    style = pathstyle(prefix)
    raw = rawprefix(prefix, style)
    quoted = quotings[startswith(raw, '"')]
    raw = unquote(raw, quoted)
    (; style, raw, quoted)
end

value(path, style::PathStyle, quoted::Quoting) = quotedvalue(pathmark(style), path, quoting(path, quoted))
quoting(path, ::Quoted) = Quoted()
quoting(path, ::Unquoted) = quotings[any(separator, path)]
quotedvalue(prefix, path, ::Quoted) = prefix * "\"" * path * "\""
quotedvalue(prefix, path, ::Unquoted) = prefix * path
pathmark(::Attached) = "@"
pathmark(::Ordinary) = ""
pathitem(path, name, description, style, quoted, kind::FileKind) = PathItem(value(path * pathsuffix(kind), style, quoted), name * pathsuffix(kind), description, kind)
pathsuffix(::File) = ""
pathsuffix(::Directory) = "/"
pathorder(::PathItem{File}) = 1
pathorder(::PathItem{Directory}) = 0

function expandhome(path, home)
    path == "~" && return home
    startswith(path, "~/") ? joinpath(home, path[3:end]) : path
end

function directoryparts(raw, root, home)
    expanded = expandhome(raw, home)
    if isempty(raw) || raw == "~" || endswith(raw, '/')
        dir = isempty(expanded) ? root : abspath(root, expanded)
        display = raw == "~" ? "~/" : raw
        return dir, display, ""
    end
    display, file = directoryprefix(raw, findlast(==('/'), raw))
    dir = isempty(display) ? root : abspath(root, expandhome(display, home))
    dir, display, file
end
directoryprefix(raw, ::Nothing) = ("", raw)
directoryprefix(raw, slash::Int) = (raw[firstindex(raw):slash], raw[nextind(raw, slash):end])

function direct(prefix, root, home)
    parts = pathparts(prefix)
    dir, display, query = directoryparts(parts.raw, root, home)
    entries = JuliaForever.attempt(() -> readdir(dir))
    direct(entries, dir, display, query, parts)
end
direct(::JuliaForever.ToolFailure, dir, display, query, parts) = PathItems()
function direct(entries::Vector{String}, dir, display, query, parts)
    items = PathItems()
    for name in entries
        startswith(lowercase(name), lowercase(query)) || continue
        kind = filekinds[isdir(joinpath(dir, name))]
        push!(items, pathitem(display * name, name, "", parts.style, parts.quoted, kind))
    end
    sort!(items; by=item -> (pathorder(item), lowercase(item.label), item.label))
end

struct Entry{K<:FileKind}
    path::String
    kind::K
end
const Entries = Vector{Union{Entry{File}, Entry{Directory}}}

function searchrules(root)
    inherited, inside = JuliaForever.initialrules(root, JuliaForever.Grep(root))
    for dir in JuliaForever.ancestors(root)
        append!(inherited, JuliaForever.rules(joinpath(dir, ".fdignore"), JuliaForever.FileRule))
    end
    inherited, inside
end

function scanrules(dir, inherited, inside)
    rules = copy(inherited)
    if ispath(joinpath(dir, ".git"))
        JuliaForever.cleargit!(rules)
        append!(rules, JuliaForever.rules(joinpath(dir, ".git", "info", "exclude"), JuliaForever.GitRule; base=dir))
        inside = dir
    end
    JuliaForever.gitignore!(rules, dir, JuliaForever.Grep(dir), inside)
    append!(rules, JuliaForever.rules(joinpath(dir, ".ignore"), JuliaForever.FileRule))
    append!(rules, JuliaForever.rules(joinpath(dir, ".fdignore"), JuliaForever.FileRule))
    (; rules, inside, names=readdir(dir), canonical=realpath(dir))
end

function matchesquery(path, query)
    target = occursin('/', query) ? path : basename(path)
    any(isuppercase, query) ? occursin(query, target) : occursin(lowercase(query), lowercase(target))
end

function scan!(entries, root, dir, inherited, inside, query, active, ancestors)
    scan!(entries, root, dir, inherited, inside, query, active, ancestors, active())
end
scan!(entries, root, dir, inherited, inside, query, active, ancestors, ::Stopped) = nothing
function scan!(entries, root, dir, inherited, inside, query, active, ancestors, ::Searching)
    state = JuliaForever.attempt(() -> scanrules(dir, inherited, inside))
    scan!(entries, root, dir, query, active, ancestors, state)
end
scan!(entries, root, dir, query, active, ancestors, ::JuliaForever.ToolFailure) = nothing
function scan!(entries, root, dir, query, active, ancestors, state::NamedTuple)
    state.canonical in ancestors && return
    push!(ancestors, state.canonical)
    directories = String[]
    for (index, name) in enumerate(state.names)
        index % 64 == 0 && yield()
        scanentry!(entries, directories, root, dir, name, query, state.rules, active())
    end
    for target in directories
        length(entries) >= 100 && break
        yield()
        scan!(entries, root, target, state.rules, state.inside, query, active, ancestors)
    end
    delete!(ancestors, state.canonical)
    nothing
end

scanentry!(entries, directories, root, dir, name, query, rules, ::Stopped) = nothing
function scanentry!(entries, directories, root, dir, name, query, rules, ::Searching)
    name == ".git" && return
    target = joinpath(dir, name)
    kind = entrykinds[(isdir(target), isfile(target))]
    scanentry!(entries, directories, root, target, query, rules, kind)
end
scanentry!(entries, directories, root, target, query, rules, ::Nothing) = nothing
function scanentry!(entries, directories, root, target, query, rules, kind::FileKind)
    directory = folder(kind)
    JuliaForever.ignored(rules, target, directory) && return
    relative = JuliaForever.posix(relpath(target, root))
    if matchesquery(relative, query) && length(entries) < 100
        push!(entries, Entry(relative, kind))
    end
    scanfolder!(directories, target, kind)
end
folder(::File) = false
folder(::Directory) = true
scanfolder!(directories, target, ::File) = nothing
scanfolder!(directories, target, ::Directory) = push!(directories, target)
const entrykinds = Dict((false, false) => nothing, (false, true) => File(), (true, false) => Directory(), (true, true) => Directory())

function entryscore(entry, query)
    isempty(query) && return 1
    name = lowercase(basename(entry.path))
    query = lowercase(query)
    result = name == query ? 100 : startswith(name, query) ? 80 : occursin(query, name) ? 50 : occursin(query, lowercase(entry.path)) ? 30 : 0
    result + directorybonus(entry.kind, result)
end
directorybonus(::File, score) = 0
directorybonus(::Directory, score) = score > 0 ? 10 : 0

function scoped(raw, root, home)
    slash = findlast(==('/'), raw)
    scoped(raw, root, home, slash)
end
scoped(raw, root, home, ::Nothing) = (root, raw, "")
function scoped(raw, root, home, slash::Int)
    display = raw[firstindex(raw):slash]
    dir = abspath(root, expandhome(display, home))
    scoped(raw, root, slash, display, dir, filekinds[isdir(dir)])
end
scoped(raw, root, slash, display, dir, ::Directory) = (dir, raw[nextind(raw, slash):end], display)
scoped(raw, root, slash, display, dir, ::File) = (root, raw, "")

function fuzzy(prefix, root, home, active)
    parts = pathparts(prefix)
    dir, query, display = scoped(parts.raw, root, home)
    state = JuliaForever.attempt(() -> searchrules(dir))
    fuzzy(state, dir, query, display, parts, active)
end
fuzzy(::JuliaForever.ToolFailure, dir, query, display, parts, active) = PathItems()
function fuzzy(state::Tuple, dir, query, display, parts, active)
    entries = Entries()
    scan!(entries, dir, dir, state[1], state[2], query, active, Set{String}())
    filter!(entry -> entryscore(entry, query) > 0, entries)
    sort!(entries; by=entry -> (-entryscore(entry, query), length(split(entry.path, '/')), length(transcode(UInt16, entry.path * pathsuffix(entry.kind))), lowercase(entry.path), entry.path))
    items = PathItems()
    for entry in Iterators.take(entries, 20)
        path = display * entry.path
        push!(items, pathitem(path, basename(entry.path), path, parts.style, parts.quoted, entry.kind))
    end
    items
end

function files(before, root; force=false, home=homedir(), active=() -> Searching())
    prefix = atprefix(before)
    files(prefix, before, root, requests[force], home, active)
end
function files(prefix::AbstractString, before, root, request::FileRequest, home, active)
    items = fuzzy(prefix, root, home, active)
    isempty(items) ? nothing : Files(prefix, items)
end
function files(::Nothing, before, root, request::FileRequest, home, active)
    prefix = pathprefix(before, request)
    directfiles(prefix, root, home)
end
directfiles(::Nothing, root, home) = nothing
function directfiles(prefix::AbstractString, root, home)
    items = direct(prefix, root, home)
    isempty(items) ? nothing : Files(prefix, items)
end

completiontail(::Ordinary, item::PathItem) = ""
completiontail(::Attached, ::PathItem{Directory}) = ""
completiontail(::Attached, ::PathItem{File}) = " "
cursoradjust(::PathItem{File}) = 0
cursoradjust(item::PathItem{Directory}) = endswith(item.value, '"') ? 1 : 0

function apply(before, after, prefix, item::PathItem)
    count = ncodeunits(before) - ncodeunits(prefix)
    leading = String(Vector{UInt8}(codeunits(before)[1:count]))
    parts = pathparts(prefix)
    remaining = remainingtext(after, item, parts.quoted)
    tail = completiontail(pathstyle(prefix), item)
    text = leading * item.value * tail * remaining
    cursor = ncodeunits(leading) + ncodeunits(item.value) + ncodeunits(tail) - cursoradjust(item)
    text, cursor
end
remainingtext(after, item, ::Unquoted) = after
remainingtext(after, item, ::Quoted) = endswith(item.value, '"') && startswith(after, '"') ? after[nextind(after, firstindex(after)):end] : after

forced(::Automatic) = false
forced(::Union{Forced, Explicit}) = true
followup(::Automatic) = Automatic()
followup(::Union{Forced, Explicit}) = Forced()
delay(::Automatic) = sleep(0.02)
delay(::Union{Forced, Explicit}) = nothing

mutable struct PendingFiles{R<:FileRequest} <: State
    before::String
    text::String
    request::R
end

mutable struct FileMenu{R<:FileRequest} <: State
    before::String
    text::String
    prefix::String
    items::PathItems
    index::Int
    request::R
end

struct DismissedFiles <: State
    before::String
    text::String
end

dismiss(state::Union{PendingFiles, FileMenu}) = DismissedFiles(state.before, state.text)
move!(menu::FileMenu, offset::Int) = (menu.index = mod1(menu.index + offset, length(menu.items)); nothing)
page!(menu::FileMenu, offset::Int) = (menu.index = clamp(menu.index + offset, 1, length(menu.items)); nothing)
