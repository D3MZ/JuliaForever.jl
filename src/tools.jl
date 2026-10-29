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

function execute(tool::Write, args)
    destination = path(tool, args.path)
    mkpath(dirname(destination))
    write(destination, args.content)
    ToolResult("Successfully wrote to $(args.path)")
end

function execute(tool::Read, args)
    lines = split(read(path(tool, args.path), String), '\n'; keepempty=true)
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

function execute(tool::Edit, args)
    destination = path(tool, args.path)
    original = read(destination, String)
    bom = startswith(original, '\ufeff') ? "\ufeff" : ""
    content = normalize(chopprefix(original, bom))
    ending = occursin("\r\n", original) ? "\r\n" : "\n"
    matches = [findall(normalize(edit.oldText), content) for edit in args.edits]
    isempty(matches) && return ToolResult("No edits provided", true)
    all(m -> length(m) == 1, matches) || return ToolResult("Edit text must match exactly once", true)
    edits = sort([(range=only(match), text=normalize(edit.newText)) for (match, edit) in zip(matches, args.edits)]; by=x -> first(x.range))
    all(i -> last(edits[i-1].range) < first(edits[i].range), 2:length(edits)) || return ToolResult("Edit ranges overlap", true)
    for edit in Iterators.reverse(edits)
        content = string(content[begin:prevind(content, first(edit.range))], edit.text, content[nextind(content, last(edit.range)):end])
    end
    write(destination, bom * replace(content, "\n" => ending))
    ToolResult("Successfully replaced $(length(edits)) block(s) in $(args.path).")
end
