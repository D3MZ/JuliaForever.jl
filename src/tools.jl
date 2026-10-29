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

struct ToolResult
    text::String
    iserror::Bool
    image::Union{Nothing, Image}
end

ToolResult(text, iserror=false) = ToolResult(text, iserror, nothing)

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
    prefix(bytes, pngsignature) && return :png
    prefix(bytes, UInt8[0xff, 0xd8, 0xff]) && return length(bytes) >= 4 && bytes[4] == 0xf7 ? :unsupported : :jpeg
    (prefix(bytes, codeunits("GIF87a")) || prefix(bytes, codeunits("GIF89a"))) && return :unsupported
    (length(bytes) >= 12 && prefix(bytes, codeunits("RIFF")) && @view(bytes[9:12]) == codeunits("WEBP")) && return :unsupported
    bmp(bytes) && return :unsupported
    :text
end

function pngformat(bytes)
    length(bytes) >= 33 || return :invalid
    bytes[9:16] == UInt8[0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52] || return :invalid
    offset = 9
    while offset + 7 <= length(bytes)
        size = foldl((n, byte) -> n * 256 + Int(byte), @view(bytes[offset:offset+3]); init=0)
        stop = offset + size + 11
        stop <= length(bytes) || return :invalid
        kind = @view bytes[offset+4:offset+7]
        kind == codeunits("acTL") && return :animated
        kind == codeunits("IDAT") && return :static
        offset = stop + 1
    end
    :invalid
end

function readimage(io, format, bytes)
    format == :unsupported && return ToolResult("Image format is not supported", true)
    append!(bytes, read(io, imagelimit + 1 - length(bytes)))
    length(bytes) <= imagelimit || return ToolResult("Image exceeds the 10 MiB limit", true)
    if format == :png
        kind = pngformat(bytes)
        kind == :animated && return ToolResult("Animated PNG is not supported", true)
        kind == :invalid && return ToolResult("PNG structure is not supported", true)
    end
    mime = format == :png ? "image/png" : "image/jpeg"
    ToolResult("Read image file [$mime]", false, Image(mime, base64encode(bytes)))
end

function readfile(io)
    if !eof(io) && peek(io, UInt8) in imageheads
        bytes = read(io, 32)
        format = imageformat(bytes)
        format == :text && return String(bytes) * read(io, String)
        return readimage(io, format, bytes)
    end
    read(io, String)
end

function execute(tool::Read, args)
    content = open(readfile, path(tool, args.path))
    content isa ToolResult && return content
    if !haskey(args, :offset) && !haskey(args, :limit) && ncodeunits(content) <= 51200 && count(==('\n'), content) + (!isempty(content) && !endswith(content, '\n')) <= 2000
        return ToolResult(content)
    end
    lines = split(content, '\n'; keepempty=true)
    offset = max(1, get(args, :offset, 1))
    offset > length(lines) && return ToolResult("Offset $offset is beyond end of file ($(length(lines)) lines total)", true)
    limit = get(args, :limit, length(lines))
    stop = min(length(lines), offset + limit - 1)
    content = join(lines[offset:stop], '\n')
    output = truncate(content, lines, offset, args.path)
    !isnothing(output) && return ToolResult(output)
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

function duplicate(text, content)
    match = findfirst(text, content)
    !isnothing(match) && !isnothing(findnext(text, content, nextind(content, first(match))))
end

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
    isempty(args.edits) && return ToolResult("No edits provided", true)
    requested = [(old=normalize(edit.oldText), text=normalize(edit.newText), fuzzy=fuzzy(edit.oldText)) for edit in args.edits]
    any(edit -> isempty(edit.old), requested) && return ToolResult("Edit text must not be empty", true)
    comparable = fuzzy(originalcontent)
    for edit in requested
        duplicate(edit.old, originalcontent) && return ToolResult("Edit text must match exactly once", true)
        if isempty(edit.fuzzy)
            (isempty(comparable) && !isnothing(findfirst(edit.old, originalcontent))) || return ToolResult("Edit text must match exactly once", true)
        else
            duplicate(edit.fuzzy, comparable) && return ToolResult("Edit text must match exactly once", true)
        end
    end
    usedfuzzy = any(edit -> isnothing(findfirst(edit.old, originalcontent)), requested)
    base = usedfuzzy ? comparable : originalcontent
    edits = NamedTuple{(:range, :text), Tuple{UnitRange{Int}, String}}[]
    for edit in requested
        match = findfirst(edit.old, base)
        isnothing(match) && !isempty(edit.fuzzy) && (match = findfirst(edit.fuzzy, base))
        isnothing(match) && return ToolResult("Edit text must match exactly once", true)
        push!(edits, (; range=match, text=edit.text))
    end
    sort!(edits; by=x -> first(x.range))
    all(i -> last(edits[i-1].range) < first(edits[i].range), 2:length(edits)) || return ToolResult("Edit ranges overlap", true)
    content = usedfuzzy ? overlay(originalcontent, base, edits) : apply(base, edits)
    isnothing(content) && return ToolResult("Edit lines could not be preserved", true)
    content == originalcontent && return ToolResult("No changes made", true)
    write(destination, bom * replace(content, "\n" => ending))
    ToolResult("Successfully replaced $(length(edits)) block(s) in $(args.path).")
end
