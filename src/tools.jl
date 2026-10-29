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

struct ToolResult
    text::String
    iserror::Bool
end

ToolResult(text) = ToolResult(text, false)

path(tool::Tool, name) = normpath(joinpath(tool.cwd, expanduser(name)))

mutable struct Mutation
    condition::Threads.Condition
    waiters::Vector{Task}
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

function mutate(f, destination::AbstractString)
    task = current_task()
    key, entry, queued = lock(mutationguard) do
        key = mutationkey(destination)
        entry = get!(() -> Mutation(Threads.Condition(mutationguard), Task[], nothing, 0, 0), mutations, key)
        queued = entry.owner !== task
        queued && push!(entry.waiters, task)
        entry.users += 1
        key, entry, queued
    end
    acquired = false
    try
        lock(mutationguard) do
            while queued && (!isnothing(entry.owner) || first(entry.waiters) !== task)
                wait(entry.condition)
            end
            if queued
                popfirst!(entry.waiters)
                entry.owner = task
            end
            entry.depth += 1
            acquired = true
        end
        f()
    finally
        lock(mutationguard) do
            if acquired
                entry.depth -= 1
                entry.depth == 0 && (entry.owner = nothing)
            elseif queued
                filter!(waiter -> waiter !== task, entry.waiters)
            end
            entry.users -= 1
            if entry.users == 0
                delete!(mutations, key)
            else
                notify(entry.condition; all=true)
            end
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

function execute(tool::Read, args)
    content = read(path(tool, args.path), String)
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
