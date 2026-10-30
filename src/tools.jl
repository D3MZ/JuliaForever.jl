abstract type Tool end

struct Read <: Tool
    cwd::String
end

struct Write <: Tool
    cwd::String
end

struct Edit <: Tool
    cwd::String
end

struct Image
    mime::String
    data::String
end

Base.isequal(a::Image, b::Image) = isequal((a.mime, a.data), (b.mime, b.data))
Base.hash(image::Image, h::UInt) = hash((image.mime, image.data), hash(Image, h))

abstract type ToolResult end

struct ToolSuccess <: ToolResult
    text::String
    image::Union{Nothing, Image}
end

struct ToolFailure <: ToolResult
    text::String
    image::Union{Nothing, Image}
end

ToolSuccess(text) = ToolSuccess(text, nothing)
ToolFailure(text) = ToolFailure(text, nothing)
ToolResult(text) = ToolSuccess(text)
ToolResult(text, iserror::Bool) = ToolResult(text, iserror, nothing)
ToolResult(text, iserror::Bool, image) = iserror ? ToolFailure(text, image) : ToolSuccess(text, image)

iserror(::ToolSuccess) = false
iserror(::ToolFailure) = true
Base.getproperty(result::ToolResult, name::Symbol) = name === :iserror ? iserror(result) : getfield(result, name)
Base.propertynames(::ToolResult, private::Bool=false) = (:text, :iserror, :image)

content(result::ToolSuccess) = result.text
content(result::ToolFailure) = "Error: " * result.text
status(::ToolSuccess) = :ok
status(::ToolFailure) = :error

# Return from the boundary only for an operating-system failure; other exceptions propagate.
function attempt(f)
    depth = length(current_exceptions())
    try
        f()
    finally
        for failure in toolfailures(current_exceptions(), depth)
            return failure
        end
    end
end

toolfailures(exceptions, depth) = length(exceptions) > depth ? toolfailures(last(exceptions).exception) : ()
toolfailures(exception::Union{SystemError, Base.IOError}) = (ToolFailure(sprint(showerror, exception)),)
toolfailures(exception) = ()

path(tool::Tool, name) = normpath(joinpath(tool.cwd, expanduser(name)))

mutable struct Mutation
    waiters::Channel{Tuple{Task, Channel{Nothing}}}
    owner::Union{Task, Nothing}
    depth::Int
    users::Int
end

const mutationguard = ReentrantLock()
const mutations = Dict{String, Mutation}()

function mutationkey(destination::AbstractString)
    parts = splitpath(abspath(destination))
    current = popfirst!(parts)
    links = 0
    while !isempty(parts)
        part = popfirst!(parts)
        part == "." && continue
        if part == ".."
            current = dirname(current)
            continue
        end
        next = joinpath(current, part)
        if islink(next)
            links += 1
            links > 256 && return realpath(destination)
            target = readlink(next)
            expanded = splitpath(target)
            isabspath(target) && (current = popfirst!(expanded))
            prepend!(parts, expanded)
        else
            current = ispath(next) ? realpath(next) : next
        end
    end
    current
end

function resume!(entry::Mutation)
    entry.owner = nothing
    while isready(entry.waiters)
        task, signal = take!(entry.waiters)
        isopen(signal) || continue
        entry.owner = task
        entry.depth = 1
        put!(signal, nothing)
        break
    end
end

function acquire!(entry::Mutation, task::Task, ::Nothing)
    entry.owner = task
    entry.depth += 1
    nothing
end

function acquire!(entry::Mutation, task::Task, owner::Task)
    owner === task && return acquire!(entry, task, nothing)
    signal = Channel{Nothing}(1)
    put!(entry.waiters, (task, signal))
    signal
end

await(::Nothing) = nothing
await(signal::Channel{Nothing}) = take!(signal)

function mutate(f, destination::AbstractString)
    task = current_task()
    key, entry, signal = lock(mutationguard) do
        key = mutationkey(destination)
        entry = get!(() -> Mutation(Channel{Tuple{Task, Channel{Nothing}}}(Inf), nothing, 0, 0), mutations, key)
        signal = acquire!(entry, task, entry.owner)
        entry.users += 1
        key, entry, signal
    end
    try
        await(signal)
        f()
    finally
        lock(mutationguard) do
            if entry.owner === task
                entry.depth -= 1
                entry.depth == 0 && resume!(entry)
            else
                close(signal)
            end
            entry.users -= 1
            entry.users == 0 && delete!(mutations, key)
        end
    end
end

function execute(tool::Write, args)
    destination = path(tool, args.path)
    mutate(destination) do
        mkpath(dirname(destination))
        write(destination, args.content)
        ToolResult("Successfully wrote to $(args.path)")
    end
end

const imagelimit = 10 * 1024 * 1024
const pngsignature = UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
# Candidate first bytes for the signatures recognized by imageformat.
const imageheads = (0x89, 0xff, 0x47, 0x52, 0x42)

prefix(bytes, signature) = length(bytes) >= length(signature) && @view(bytes[1:length(signature)]) == signature

little(bytes, start, count) = foldl((n, byte) -> 256 * n + Int(byte), Iterators.reverse(@view(bytes[start:start+count-1])); init=0)

function bmp(bytes)
    length(bytes) >= 26 && prefix(bytes, codeunits("BM")) || return false
    size = little(bytes, 3, 4)
    offset = little(bytes, 11, 4)
    header = little(bytes, 15, 4)
    (size == 0 || size >= 26 && offset < size) && offset >= 14 + header || return false
    if header == 12
        planes, bits = little(bytes, 23, 2), little(bytes, 25, 2)
    elseif 40 <= header <= 124 && length(bytes) >= 30
        planes, bits = little(bytes, 27, 2), little(bytes, 29, 2)
    else
        return false
    end
    planes == 1 && bits in (1, 4, 8, 16, 24, 32)
end

function imageformat(bytes)
    prefix(bytes, pngsignature) && return MIME"image/png"()
    prefix(bytes, UInt8[0xff, 0xd8, 0xff]) && return length(bytes) >= 4 && bytes[4] == 0xf7 ? MIME"image/jls"() : MIME"image/jpeg"()
    (prefix(bytes, codeunits("GIF87a")) || prefix(bytes, codeunits("GIF89a"))) && return MIME"image/gif"()
    (length(bytes) >= 12 && prefix(bytes, codeunits("RIFF")) && @view(bytes[9:12]) == codeunits("WEBP")) && return MIME"image/webp"()
    bmp(bytes) && return MIME"image/bmp"()
    MIME"text/plain"()
end

function pngproblem(bytes)
    length(bytes) >= 33 || return "PNG structure is not supported"
    bytes[9:16] == UInt8[0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52] || return "PNG structure is not supported"
    offset = 9
    while offset + 7 <= length(bytes)
        size = foldl((n, byte) -> n * 256 + Int(byte), @view(bytes[offset:offset+3]); init=0)
        stop = offset + size + 11
        stop <= length(bytes) || return "PNG structure is not supported"
        kind = @view bytes[offset+4:offset+7]
        kind == codeunits("acTL") && return "Animated PNG is not supported"
        kind == codeunits("IDAT") && return nothing
        offset = stop + 1
    end
    "PNG structure is not supported"
end

imageproblem(::MIME"image/png", bytes) = pngproblem(bytes)
imageproblem(::MIME"image/jpeg", bytes) = nothing

function readimage(io, format::Union{MIME"image/png", MIME"image/jpeg"}, bytes)
    append!(bytes, read(io, imagelimit + 1 - length(bytes)))
    length(bytes) <= imagelimit || return ToolResult("Image exceeds the 10 MiB limit", true)
    imagefile(format, bytes, imageproblem(format, bytes))
end

readimage(io, ::MIME, bytes) = ToolResult("Image format is not supported", true)

function imagefile(format::MIME, bytes, ::Nothing)
    mime = string(format)
    ToolResult("Read image file [$mime]", false, Image(mime, base64encode(bytes)))
end

imagefile(::MIME, bytes, problem::String) = ToolResult(problem, true)

function readfile(io)
    if !eof(io) && peek(io, UInt8) in imageheads
        bytes = read(io, 32)
        return readfile(io, bytes, imageformat(bytes))
    end
    read(io, String)
end

readfile(io, bytes, ::MIME"text/plain") = String(bytes) * read(io, String)
readfile(io, bytes, format::MIME) = readimage(io, format, bytes)

execute(tool::Read, args) = readresult(open(readfile, path(tool, args.path)), args)
readresult(result::ToolResult, args) = result

function readresult(content::String, args)
    if !haskey(args, :offset) && !haskey(args, :limit) && ncodeunits(content) <= 51200 && count(==('\n'), content) + (!isempty(content) && !endswith(content, '\n')) <= 2000
        return ToolResult(content)
    end
    lines = split(content, '\n'; keepempty=true)
    offset = max(1, get(args, :offset, 1))
    offset > length(lines) && return ToolFailure("Offset $offset is beyond end of file ($(length(lines)) lines total)")
    limit = get(args, :limit, length(lines))
    stop = min(length(lines), offset + limit - 1)
    content = join(lines[offset:stop], '\n')
    readresult(truncate(content, lines, offset, args.path), content, lines, stop, args)
end

readresult(output::String, content, lines, stop, args) = ToolResult(output)
function readresult(::Nothing, content, lines, stop, args)
    remaining = length(lines) - stop
    remaining > 0 && haskey(args, :limit) && return ToolResult("$content\n\n[$remaining more lines in file. Use offset=$(stop + 1) to continue.]")
    ToolResult(content)
end

function truncate(content, lines, offset, name)
    selected = split(content, '\n'; keepempty=true)
    endswith(content, '\n') && pop!(selected)
    isempty(content) && empty!(selected)
    length(selected) <= 2000 && ncodeunits(content) <= 51200 && return nothing
    size = ncodeunits(first(selected))
    if size > 51200
        label = size < 1024 * 1024 ? "$(round(size / 1024; digits=1))KB" : "$(round(size / (1024 * 1024); digits=1))MB"
        return "[Line $offset is $label, exceeds 50.0KB limit. Use bash: sed -n '$(offset)p' $name | head -c 51200]"
    end
    output = SubString{String}[]
    bytes = 0
    for line in selected
        length(output) == 2000 && break
        nextbytes = bytes + ncodeunits(line) + !isempty(output)
        nextbytes > 51200 && break
        push!(output, line)
        bytes = nextbytes
    end
    lastline = offset + length(output) - 1
    limit = length(output) == 2000 ? "" : " (50.0KB limit)"
    "$(join(output, '\n'))\n\n[Showing lines $offset-$lastline of $(length(lines))$limit. Use offset=$(lastline + 1) to continue.]"
end

normalize(text) = replace(text, "\r\n" => "\n", "\r" => "\n")

function fuzzy(text)
    lines = replace.(split(Unicode.normalize(normalize(text), :NFKC), '\n'; keepempty=true), r"[\t\x0b\x0c \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+$" => "")
    replace(join(lines, '\n'), r"[\u2018\u2019\u201a\u201b]" => "'", r"[\u201c\u201d\u201e\u201f]" => "\"", r"[\u2010-\u2015\u2212]" => "-", r"[\u00a0\u2002-\u200a\u202f\u205f\u3000]" => " ")
end

duplicate(text, content) = duplicate(text, content, findfirst(text, content))
duplicate(text, content, ::Nothing) = false
duplicate(text, content, match) = duplicate(findnext(text, content, nextind(content, first(match))))
duplicate(::Nothing) = false
duplicate(match) = true

function apply(content, edits, offset=0)
    for edit in Iterators.reverse(edits)
        start = first(edit.range) - offset
        stop = last(edit.range) - offset
        content = string(content[begin:prevind(content, start)], edit.text, content[nextind(content, stop):end])
    end
    content
end

function overlay(original, base, edits)
    original_lines = collect(eachline(IOBuffer(original); keep=true))
    base_lines = collect(eachline(IOBuffer(base); keep=true))
    length(original_lines) == length(base_lines) || return nothing
    ends = cumsum(ncodeunits.(base_lines))
    spans = [(start=searchsortedfirst(ends, first(edit.range)), stop=searchsortedfirst(ends, last(edit.range))) for edit in edits]
    output = IOBuffer()
    nextline = 1
    index = 1
    while index <= length(edits)
        start = spans[index].start
        stop = spans[index].stop
        lastedit = index
        while lastedit < length(edits) && spans[lastedit + 1].start <= stop
            lastedit += 1
            stop = max(stop, spans[lastedit].stop)
        end
        write(output, join(original_lines[nextline:start-1]))
        offset = start == 1 ? 0 : ends[start-1]
        write(output, apply(join(base_lines[start:stop]), @view(edits[index:lastedit]), offset))
        nextline = stop + 1
        index = lastedit + 1
    end
    write(output, join(original_lines[nextline:end]))
    String(take!(output))
end

function execute(tool::Edit, args)
    destination = path(tool, args.path)
    mutate(destination) do
        edit(destination, args)
    end
end

function edit(destination, args)
    original = read(destination, String)
    bom = startswith(original, '\ufeff') ? "\ufeff" : ""
    originalcontent = normalize(chopprefix(original, bom))
    ending = occursin(r"^[^\n]*\r\n", original) ? "\r\n" : "\n"
    isempty(args.edits) && return ToolFailure("No edits provided")
    requested = [(old=normalize(edit.oldText), text=normalize(edit.newText), fuzzy=fuzzy(edit.oldText)) for edit in args.edits]
    any(edit -> isempty(edit.old), requested) && return ToolFailure("Edit text must not be empty")
    comparable = fuzzy(originalcontent)
    for edit in requested
        duplicate(edit.old, originalcontent) && return ToolFailure("Edit text must match exactly once")
        if isempty(edit.fuzzy)
            (isempty(comparable) && !isnothing(findfirst(edit.old, originalcontent))) || return ToolFailure("Edit text must match exactly once")
        else
            duplicate(edit.fuzzy, comparable) && return ToolFailure("Edit text must match exactly once")
        end
    end
    strategy = foldl(editstrategy, requested; init=ExactEdit(originalcontent, comparable))
    base = editbase(strategy)
    edits = foldl((matches, edit) -> editmatches(matches, edit, base), requested; init=NamedTuple{(:range, :text), Tuple{UnitRange{Int}, String}}[])
    context = (; destination, bom, ending, args, strategy)
    editprepared(context, edits)
end

struct ExactEdit
    original::String
    comparable::String
end
struct FuzzyEdit
    original::String
    comparable::String
end
editstrategy(strategy::FuzzyEdit, edit) = strategy
editstrategy(strategy::ExactEdit, edit::NamedTuple) = editstrategy(strategy, findfirst(edit.old, strategy.original))
editstrategy(strategy::ExactEdit, match::UnitRange) = strategy
editstrategy(strategy::ExactEdit, ::Nothing) = FuzzyEdit(strategy.original, strategy.comparable)
editbase(strategy::ExactEdit) = strategy.original
editbase(strategy::FuzzyEdit) = strategy.comparable

editmatches(failure::ToolFailure, edit, base) = failure
editmatches(matches::Vector, edit, base) = editmatch!(matches, edit, editmatch(edit, base, findfirst(edit.old, base)))
editmatch(edit, base, match::UnitRange) = match
function editmatch(edit, base, ::Nothing)
    isempty(edit.fuzzy) && return nothing
    findfirst(edit.fuzzy, base)
end
editmatch!(matches, edit, ::Nothing) = ToolFailure("Edit text must match exactly once")
editmatch!(matches, edit, match::UnitRange) = push!(matches, (; range=match, text=edit.text))

editprepared(context, failure::ToolFailure) = failure
function editprepared(context, edits::Vector)
    sort!(edits; by=x -> first(x.range))
    all(i -> last(edits[i-1].range) < first(edits[i].range), 2:length(edits)) || return ToolFailure("Edit ranges overlap")
    content = editapply(context.strategy, edits)
    editwrite(context, edits, content)
end
editapply(strategy::ExactEdit, edits) = apply(strategy.original, edits)
editapply(strategy::FuzzyEdit, edits) = overlay(strategy.original, strategy.comparable, edits)
editwrite(context, edits, ::Nothing) = ToolFailure("Edit lines could not be preserved")
function editwrite(context, edits, content::String)
    content == context.strategy.original && return ToolFailure("No changes made")
    write(context.destination, context.bom * replace(content, "\n" => context.ending))
    ToolResult("Successfully replaced $(length(edits)) block(s) in $(context.args.path).")
end
