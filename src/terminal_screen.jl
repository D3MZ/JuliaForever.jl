import Unicode

abstract type Mode end
struct FullscreenMode <: Mode
    provider::String
end
FullscreenMode() = FullscreenMode("")
struct RegularMode <: Mode
    provider::String
end
RegularMode() = RegularMode("")
withprovider(::FullscreenMode, name) = FullscreenMode(name)
withprovider(::RegularMode, name) = RegularMode(name)
abstract type View end
struct Regular <: View
    provider::String
end
Regular() = Regular("")
abstract type Detail end
struct Collapsed <: Detail end
struct Expanded <: Detail end
toggle(::Collapsed) = Expanded()
toggle(::Expanded) = Collapsed()
abstract type FrameState end
struct Unpainted <: FrameState end
struct Painted <: FrameState end

abstract type Block end
abstract type TextRole end
struct UserText <: TextRole end
struct AssistantText <: TextRole end
struct DiagnosticText <: TextRole end
struct CommandText <: TextRole end
const TextRoles = Union{UserText, AssistantText, DiagnosticText, CommandText}
mutable struct TextBlock <: Block
    role::TextRoles
    parts::Vector{String}
    width::Int
    count::Int
    lines::Vector{String}
end
TextBlock(role, parts) = TextBlock(role, parts, 0, -1, String[])
mutable struct ToolBlock <: Block
    id::String
    name::String
    arguments::String
    result::String
    status::String
end

mutable struct Fullscreen <: View
    blocks::Vector{Union{TextBlock, ToolBlock}}
    tools::Dict{String, ToolBlock}
    detail::Union{Collapsed, Expanded}
    top::Int
    size::Tuple{Int, Int}
    timer::Union{Nothing, Timer}
    frame::Union{Unpainted, Painted}
    name::String
    provider::String
end
Fullscreen(provider="") = Fullscreen(Union{TextBlock, ToolBlock}[], Dict{String, ToolBlock}(), Collapsed(), 0, (0, 0), nothing, Unpainted(), "session", provider)

createview(mode::RegularMode, output) = Regular(mode.provider)
createview(mode::FullscreenMode, output::IO) = Regular(mode.provider)
createview(mode::FullscreenMode, output::Base.TTY) = Fullscreen(mode.provider)
intro!(::Regular, output) = println(output, "Julia Forever — Enter sends, Alt+Enter follows up, Esc interrupts, /exit quits")
intro!(::Fullscreen, output) = nothing

struct EditorOutput{R, O<:IO} <: IO
    reference::R
    physical::O
end
Base.isopen(output::EditorOutput) = isopen(output.physical)
Base.displaysize(output::EditorOutput) = displaysize(output.physical)
Base.get(output::EditorOutput, key, default) = get(output.physical, key, default)
Base.unsafe_write(output::EditorOutput, pointer::Ptr{UInt8}, count::UInt) = (prime!(output.reference[]); count)
Base.write(output::EditorOutput, byte::UInt8) = (prime!(output.reference[]); 1)
Base.flush(output::EditorOutput) = paint!(output.reference[])
editoroutput(::Regular, reference, physical) = physical
editoroutput(::Fullscreen, reference, physical) = EditorOutput(reference, physical)

struct ScreenOutput{S, R<:TextRole} <: IO
    session::S
    role::R
end
Base.isopen(output::ScreenOutput) = isopen(output.session.physical)
Base.flush(::ScreenOutput) = nothing
Base.write(output::ScreenOutput, byte::UInt8) = (write(output, [byte]); 1)
function Base.unsafe_write(output::ScreenOutput, pointer::Ptr{UInt8}, count::UInt)
    session = output.session
    text = unsafe_string(pointer, Int(count))
    lock(session.editor.state.line_modify_lock) do
        record!(session.view, output.role, text)
        paint!(session)
    end
    count
end

record!(::Regular, role, text) = nothing
function record!(screen::Fullscreen, role, text)
    isempty(text) && return nothing
    record!(screen.blocks, role, text, isempty(screen.blocks) ? nothing : last(screen.blocks))
end
record!(blocks, role, text, last) = push!(blocks, TextBlock(role, [text]))
record!(blocks, role, text, last::TextBlock) = record!(blocks, role, text, last, last.role)
record!(blocks, role::TextRole, text, last::TextBlock, previous::TextRole) = push!(blocks, TextBlock(role, [text]))
record!(blocks, role::R, text, last::TextBlock, previous::R) where {R<:TextRole} = push!(last.parts, text)
mark!(::Regular) = 0
function mark!(screen::Fullscreen)
    push!(screen.blocks, TextBlock(CommandText(), String[]))
    length(screen.blocks)
end
aftercommand!(::Regular, previous, agent, mark, terminal) = nothing
function aftercommand!(screen::Fullscreen, previous, agent, mark, terminal)
    if previous === agent
        deleteat!(screen.blocks, mark)
    else
        tail = Union{TextBlock, ToolBlock}[]
        for block in screen.blocks[mark + 1:end]
            diagnostic!(tail, block)
        end
        load!(screen, agent, terminal)
        append!(screen.blocks, tail)
    end
    nothing
end
diagnostic!(tail, ::Block) = nothing
diagnostic!(tail, block::TextBlock) = diagnostic!(tail, block, block.role)
diagnostic!(tail, block, ::TextRole) = nothing
diagnostic!(tail, block, ::DiagnosticText) = push!(tail, block)

function load!(screen::Fullscreen, agent, terminal)
    empty!(screen.blocks)
    empty!(screen.tools)
    screen.top = 0
    for message in agent.state.messages
        replay!(screen, message, terminal)
    end
    nothing
end
replay!(screen, message, terminal) = nothing
replay!(screen, message::JuliaForever.Conversation.RawMessage, terminal) = get(replayroles, get(message.value, "role", ""), replayignore!)(screen, message.value, terminal)
replay!(screen, message::Union{JuliaForever.Conversation.User, JuliaForever.Conversation.ImageUser}, terminal) = replaytext!(screen, UserText(), "> ", message.content)
replay!(screen, message::JuliaForever.Conversation.Summary, terminal) = replaytext!(screen, DiagnosticText(), "[summary] ", message.content)
function replay!(screen, message::JuliaForever.Conversation.Assistant, terminal)
    replaytext!(screen, AssistantText(), "", message.content)
    for call in message.calls
        block = ToolBlock(call.id, JuliaForever.redact(terminal, something(call.name, "unknown")), JuliaForever.redact(terminal, something(call.arguments, "")), "", "pending")
        screen.tools[call.id] = block
        push!(screen.blocks, block)
    end
    nothing
end
function replay!(screen, message::JuliaForever.Conversation.ToolMessage, terminal)
    replayresult!(screen, get(screen.tools, message.id, nothing), message, terminal)
end
function replayresult!(screen, ::Nothing, message, terminal)
    block = ToolBlock(message.id, "tool", "", "", "pending")
    push!(screen.blocks, block)
    replayresult!(screen, block, message, terminal)
end
function replayresult!(screen, block::ToolBlock, message, terminal)
    block.result = JuliaForever.redact(terminal, message.content)
    block.status = ("ok", "error")[Int(message.iserror) + 1]
    nothing
end
replayignore!(screen, message, terminal) = nothing
replayuser!(screen, message, terminal) = replaytext!(screen, UserText(), "> ", get(message, "content", nothing))
replayassistant!(screen, message, terminal) = replaytext!(screen, AssistantText(), "", get(message, "content", nothing))
replaytext!(screen, role, prefix, value) = nothing
replaytext!(screen, role, prefix, value::AbstractString) = record!(screen, role, prefix * value * "\n")
function replaytool!(screen, message, terminal)
    text = get(message, "content", "")
    replaytoolcontent!(screen, terminal, text)
end
replaytoolcontent!(screen, terminal, value) = nothing
function replaytoolcontent!(screen, terminal, value::AbstractString)
    push!(screen.blocks, ToolBlock("", "tool", "", JuliaForever.redact(terminal, value), "complete"))
end
const replayroles = Dict("user" => replayuser!, "assistant" => replayassistant!, "tool" => replaytool!)

viewkeys(::Regular, reference) = Dict{Any, Any}()
function viewkeys(::Fullscreen, reference)
    Dict{Any, Any}(
        "\e[5~" => (state, args...) -> pagecompletion!(reference[], state, -1),
        "\e[6~" => (state, args...) -> pagecompletion!(reference[], state, 1),
        "\e[1;5H" => (state, args...) -> top!(reference[]),
        "\e[1;5F" => (state, args...) -> bottom!(reference[]),
        "^O" => (state, args...) -> detail!(reference[]),
        "^L" => (state, args...) -> modelkey!(reference[], state, reference[].activity),
    )
end

modelkey!(session, state, ::Busy) = :ok
function modelkey!(session, state, ::Available)
    session.draft = LineEdit.input_string(state)
    LineEdit.replace_line(state, "/model")
    TerminalEditor.commitcommand!(state)
    session.visibility = Hidden()
    :done
end

function scroll!(session, direction)
    screen = session.view
    rows, cols = displaysize(session.physical)
    rows, cols = max(rows, 3), max(cols, 2)
    width = cols - 1
    _, _, _, _, _, height = viewport(session, width, rows)
    all = transcript(screen, width)
    bottom = max(1, length(all) - height + 1)
    top = iszero(screen.top) ? bottom : screen.top
    screen.top = clamp(top + direction * max(1, height - 4), 1, bottom)
    screen.top == bottom && (screen.top = 0)
    paint!(session)
    :ok
end
function top!(session)
    session.view.top = 1
    paint!(session)
    :ok
end
function bottom!(session)
    session.view.top = 0
    paint!(session)
    :ok
end
function detail!(session)
    session.view.detail = toggle(session.view.detail)
    paint!(session)
    :ok
end

function clean(text)
    text = replace(text, r"\e\][^\a]*(?:\a|\e\\)" => "", r"\e\[[0-?]*[ -/]*[@-~]" => "")
    text = replace(text, "\r\n" => "\n", '\r' => '\n', '\t' => "    ")
    replace(text, r"[\x00-\x08\x0b-\x1f\x7f-\x9f]" => "")
end

function wrap(text, width::Int)
    result = String[]
    line = IOBuffer()
    cells = 0
    for cluster in Unicode.graphemes(clean(text))
        if cluster == "\n"
            push!(result, String(take!(line)))
            cells = 0
        else
            size = textwidth(cluster)
            if cells > 0 && cells + size > width
                push!(result, String(take!(line)))
                cells = 0
            end
            if size <= width
                print(line, cluster)
                cells += size
            end
        end
    end
    push!(result, String(take!(line)))
    result
end

function blocklines(block::TextBlock, detail::Detail, width)
    if block.width != width || block.count != length(block.parts)
        block.lines = wrap(join(block.parts), width)
        block.width = width
        block.count = length(block.parts)
    end
    block.lines
end
function blocklines(block::ToolBlock, detail::Detail, width)
    lines = wrap("[tool] $(block.name): $(block.status)", width)
    append!(lines, details(block, detail, width))
    lines
end
details(block::ToolBlock, ::Collapsed, width) = String[]
function details(block::ToolBlock, ::Expanded, width)
    wrap("  arguments: " * block.arguments * "\n  output: " * block.result, width)
end
function transcript(screen::Fullscreen, width)
    lines = String[]
    for block in screen.blocks
        append!(lines, blocklines(block, screen.detail, width))
    end
    lines
end

modelname(provider) = string(nameof(typeof(provider)))
modelname(provider::Union{JuliaForever.OpenAI, JuliaForever.OpenAIResponses, JuliaForever.Anthropic, JuliaForever.Google}) = provider.model
activityname(::Available) = "ready"
activityname(::Busy) = "working"

function editorlines(session, width, height)
    state = session.editor.state
    buffer = LineEdit.buffer(state)
    prefix = String(copy(buffer.data[1:position(buffer)]))
    lines = wrap("> " * LineEdit.input_string(state), width)
    before = wrap("> " * prefix, width)
    cursor = length(before)
    count = min(length(lines), max(1, height ÷ 3))
    firstline = clamp(cursor - count + 1, 1, max(1, length(lines) - count + 1))
    lines[firstline:firstline + count - 1], cursor - firstline + 1, min(width + 1, textwidth(last(before)) + 1)
end

function viewport(session, width, rows)
    synccompletion!(session, session.editor.state)
    editor, cursorrow, cursorcol = editorlines(session, width, rows)
    menu = completionlines(session, width, max(0, min(5, rows - length(editor) - 2)))
    queued = reduce(vcat, (wrap(line, width) for line in queuelines(session)); init=String[])
    queued = last(queued, min(length(queued), max(0, rows - length(editor) - length(menu) - 2)))
    height = max(1, rows - length(editor) - length(queued) - length(menu) - 1)
    editor, cursorrow, cursorcol, queued, menu, height
end

paint!(::Nothing) = nothing
prime!(::Nothing) = nothing
prime!(session) = prime!(session, session.view, session.view.frame)
prime!(session, screen::Fullscreen, ::Painted) = nothing
function prime!(session, screen::Fullscreen, ::Unpainted)
    screen.frame = Painted()
    paint!(session)
end
paint!(session) = paint!(session, session.visibility)
paint!(session, ::Hidden) = nothing
function paint!(session, ::Visible)
    screen = session.view
    paint!(session, screen)
end
paint!(session, ::Regular) = nothing
function paint!(session, screen::Fullscreen)
    rows, cols = displaysize(session.physical)
    rows, cols = max(rows, 3), max(cols, 2)
    screen.size = (rows, cols)
    width = cols - 1
    editor, cursorrow, cursorcol, queued, menu, height = viewport(session, width, rows)
    all = transcript(screen, width)
    bottom = max(1, length(all) - height + 1)
    top = iszero(screen.top) ? bottom : clamp(screen.top, 1, bottom)
    visible = all[top:min(length(all), top + height - 1)]
    out = IOBuffer()
    print(out, "\e[?25l\e[H\e[2J")
    for (row, line) in enumerate(visible)
        print(out, "\e[", row, ";1H", line)
    end
    statusrow = rows - length(editor) - length(menu)
    for (index, line) in enumerate(queued)
        print(out, "\e[", statusrow - length(queued) + index - 1, ";1H", line)
    end
    status = "$(modelname(session.agent.provider)) | $(activityname(session.activity)) | $(screen.name) | $(basename(pwd()))"
    print(out, "\e[", statusrow, ";1H", first(wrap(status, width)))
    for (index, line) in enumerate(editor)
        print(out, "\e[", statusrow + index, ";1H", line)
    end
    for (index, line) in enumerate(menu)
        print(out, "\e[", statusrow + length(editor) + index, ";1H", line)
    end
    print(out, "\e[", statusrow + cursorrow, ";", cursorcol, "H\e[?25h")
    write(session.physical, take!(out))
    flush(session.physical)
    nothing
end

start!(session) = start!(session, session.view)
start!(session, ::Regular) = nothing
function start!(session, screen::Fullscreen)
    load!(screen, session.agent, session.terminal)
    sessionname!(session)
    print(session.physical, "\e[?1049h\e[?2004h")
    flush(session.physical)
    screen.size = displaysize(session.physical)
    screen.timer = Timer(0.2; interval=0.2) do _
        lock(session.editor.state.line_modify_lock) do
            displaysize(session.physical) == screen.size || paint!(session)
        end
    end
end
finish!(session) = finish!(session, session.view)
finish!(session, ::Regular) = nothing
function finish!(session, screen::Fullscreen)
    closetimer(screen.timer)
    print(session.physical, "\e[?2004l\e[?25h\e[?1049l")
    flush(session.physical)
    nothing
end
closetimer(::Nothing) = nothing
closetimer(timer::Timer) = close(timer)

sessionname!(session) = sessionname!(session, session.view)
sessionname!(session, ::Regular) = nothing
function sessionname!(session, screen::Fullscreen)
    screen.name = sessionlabel(JuliaForever.SessionCatalog.sessionname(session.agent.history))
    nothing
end
sessionlabel(::Nothing) = "session"
sessionlabel(::JuliaForever.History.Rejected) = "session"
sessionlabel(name::AbstractString) = String(name)

event!(session, event) = event!(session, session.view, event)
event!(session, ::Regular, event) = redraw!(session)
function event!(session, screen::Fullscreen, event)
    lock(session.editor.state.line_modify_lock) do
        get(screenevents, event.type, ignoreevent!)(session, event)
        paint!(session)
    end
end
ignoreevent!(session, event) = nothing
messagestart!(session, event) = get(startroles, get(event.message, "role", ""), replayignore!)(session.view, event.message, session.terminal)
const startroles = Dict("user" => replayuser!)
function toolstart!(session, event)
    name = JuliaForever.redact(session.terminal, event.tool_name)
    arguments = JuliaForever.redact(session.terminal, JuliaForever.JSON3.write(event.args))
    block = ToolBlock(string(event.tool_call_id), name, arguments, "", "running")
    session.view.tools[block.id] = block
    push!(session.view.blocks, block)
    nothing
end
toolupdate!(session, event) = toolupdate!(session, get(session.view.tools, string(event.tool_call_id), nothing), event)
toolupdate!(session, ::Nothing, event) = nothing
toolupdate!(session, block::ToolBlock, event) = (block.result = JuliaForever.redact(session.terminal, event.partial_result.text); nothing)
toolend!(session, event) = toolend!(session, get(session.view.tools, string(event.tool_call_id), nothing), event)
toolend!(session, ::Nothing, event) = nothing
function toolend!(session, block::ToolBlock, event)
    block.result = JuliaForever.redact(session.terminal, event.result.text)
    block.status = toolstatus(event.result)
    nothing
end
toolstatus(::JuliaForever.ToolSuccess) = "ok"
toolstatus(::JuliaForever.ToolFailure) = "error"
const screenevents = Dict(:message_start => messagestart!, :tool_execution_start => toolstart!, :tool_execution_update => toolupdate!, :tool_execution_end => toolend!)

JuliaForever.render!(terminal::JuliaForever.Terminal{O, E}, event::JuliaForever.ToolStarted) where {O<:ScreenOutput, E<:ScreenOutput} = nothing
JuliaForever.render!(terminal::JuliaForever.Terminal{O, E}, event::JuliaForever.ToolUpdated) where {O<:ScreenOutput, E<:ScreenOutput} = nothing
JuliaForever.render!(terminal::JuliaForever.Terminal{O, E}, event::JuliaForever.ToolEnded) where {O<:ScreenOutput, E<:ScreenOutput} = nothing
