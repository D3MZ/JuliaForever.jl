module LiveTerminal

import ..JuliaForever
import ..JuliaForever: TerminalEditor
const LineEdit = TerminalEditor.LineEdit
const Terminals = TerminalEditor.REPL.Terminals

abstract type Activity end
struct Available <: Activity end
struct Busy <: Activity end
abstract type Visibility end
struct Visible <: Visibility end
struct Hidden <: Visibility end
abstract type Submission end
struct Send <: Submission end
struct Follow <: Submission end
abstract type EscapeInput end
struct EscapeSequence <: EscapeInput end
struct EscapeAlone <: EscapeInput end
const escapewaits = Dict(:ok => EscapeSequence(), :timed_out => EscapeAlone())
abstract type Outcome end
struct Completed <: Outcome end
struct Interrupted <: Outcome end
struct Failed <: Outcome
    status::Int
end
const outcomes = Dict(0 => Completed(), 130 => Interrupted())
include("terminal_screen.jl")
include("terminal_completion.jl")

struct Deferred{M<:Submission}
    text::String
    mode::M
end

struct DeferredQueue
    steering::Channel{String}
    followups::Channel{String}
    display::Vector{Deferred}
end
DeferredQueue() = DeferredQueue(Channel{String}(Inf), Channel{String}(Inf), Deferred[])
channel(queue::DeferredQueue, ::Send) = queue.steering
channel(queue::DeferredQueue, ::Follow) = queue.followups
Base.isempty(queue::DeferredQueue) = !isready(queue.steering) && !isready(queue.followups)

function defer!(queue::DeferredQueue, text, mode::Submission)
    put!(channel(queue, mode), text)
    push!(queue.display, Deferred(text, mode))
    nothing
end

matches(::Deferred, ::Submission) = false
matches(::Deferred{T}, ::T) where {T<:Submission} = true

function next!(queue::DeferredQueue)
    mode = isready(queue.steering) ? Send() : Follow()
    text = take!(channel(queue, mode))
    index = findfirst(item -> matches(item, mode), queue.display)
    deleteat!(queue.display, index)
    text
end

function drain!(channel::Channel, target)
    while isready(channel)
        push!(target, take!(channel))
    end
    nothing
end

function collect!(queue::DeferredQueue, queued::NamedTuple)
    drain!(queue.steering, queued.steering)
    drain!(queue.followups, queued.followups)
    empty!(queue.display)
    [queued.steering; queued.followups]
end

function Base.empty!(queue::DeferredQueue)
    collect!(queue, (; steering=String[], followups=String[]))
    queue
end

mutable struct Session{V<:View, T}
    editor::TerminalEditor.Editor
    physical::IO
    agent::JuliaForever.Agent
    terminal::JuliaForever.Terminal
    templates::T
    completion::Union{Completion.Closed, Completion.Dismissed, Completion.Menu}
    extensions::Union{Nothing, JuliaForever.Extensions.Snapshot}
    activity::Activity
    visibility::Visibility
    task::Union{Nothing, Task}
    partial::String
    area::Union{Nothing, LineEdit.InputAreaState}
    deferred::DeferredQueue
    draft::String
    status::Int
    view::V
end

struct Output <: IO
    session::Session
end

function output! end
Base.isopen(::Output) = true
Base.flush(output::Output) = flush(output.session.physical)
function Base.unsafe_write(output::Output, pointer::Ptr{UInt8}, count::UInt)
    output!(output.session, unsafe_string(pointer, Int(count)))
    count
end

function Session(editor, terminal, agent, templates, extensions, view::View)
    session = Session(editor, terminal.diagnostics, agent, terminal, templates, Completion.Closed(), extensions, Available(), Visible(), nothing, "", nothing, DeferredQueue(), "", 0, view)
    session.terminal = maketerminal(session, terminal, view)
    session
end
maketerminal(session, terminal, ::Regular) = JuliaForever.Terminal(output(session, terminal.output), Output(session), terminal.secrets)
maketerminal(session, terminal, ::Fullscreen) = JuliaForever.Terminal(ScreenOutput(session, AssistantText()), ScreenOutput(session, DiagnosticText()), terminal.secrets)
include("terminal_completion_ui.jl")
output(session, stream::IO) = stream
output(session, stream::Base.TTY) = output(session.physical, session, stream)
output(physical::IO, session, stream::Base.TTY) = stream
output(physical::Base.TTY, session, stream::Base.TTY) = Output(session)

function queues(session)
    lock(session.agent.lock) do
        (; steering=session.agent.state.steering, followups=session.agent.state.followups)
    end
end

function queuelines(session)
    queued = queues(session)
    [ ["Steering: " * replace(text, '\n' => ' ') for text in queued.steering];
      ["Follow-up: " * replace(text, '\n' => ' ') for text in queued.followups];
      [label(item) for item in session.deferred.display] ]
end

cleararea!(session, ::Nothing) = nothing
function cleararea!(session, area::LineEdit.InputAreaState)
    Terminals.cmove_up(session.editor.terminal, 1)
    LineEdit._clear_input_area(session.editor.terminal, area)
end

function redraw!(session, prefix="")
    lock(session.editor.state.line_modify_lock) do
        redraw!(session, session.view, session.visibility, prefix)
    end
end
redraw!(session, ::Regular, visibility, prefix) = redraw!(session, visibility, prefix)
redraw!(session, screen::Fullscreen, ::Visible, prefix) = (record!(screen, DiagnosticText(), prefix); paint!(session))
redraw!(session, screen::Fullscreen, ::Hidden, prefix) = (record!(screen, DiagnosticText(), prefix); nothing)
redraw!(session, ::Hidden, prefix) = (print(session.physical, prefix); flush(session.physical))

function redraw!(session, ::Visible, prefix)
    terminal = session.editor.terminal
    state = session.editor.state
    LineEdit.clear_input_area(LineEdit.state(state))
    cleararea!(session, session.area)
    print(terminal, prefix)
    lines = String[]
    isempty(session.partial) || push!(lines, session.partial)
    append!(lines, queuelines(session))
    append!(lines, completionlines(session, max(1, last(displaysize(session.physical)) - 1), 5))
    area = join(lines, "\n")
    if isempty(area)
        session.area = nothing
    else
        buffer = IOBuffer(area)
        seekend(buffer)
        session.area = LineEdit.refresh_multi_line(terminal, buffer, LineEdit.InputAreaState(0, 0), "")
        println(terminal)
    end
    LineEdit.refresh_line(state)
    flush(terminal)
end

function output!(session, text)
    lock(session.editor.state.line_modify_lock) do
        output!(session, session.visibility, text)
    end
end

function output!(session, ::Visible, text)
    data = session.partial * text
    index = findlast(==('\n'), data)
    output!(session, data, index)
end
output!(session, data::AbstractString, ::Nothing) = (session.partial = data; redraw!(session))
function output!(session, data::AbstractString, index::Int)
    session.partial = data[nextind(data, index):end]
    redraw!(session, data[1:index])
end
output!(session, ::Hidden, text) = (print(session.physical, text); flush(session.physical))

enqueue!(agent, text, ::Send) = JuliaForever.steer!(agent, text)
enqueue!(agent, text, ::Follow) = JuliaForever.followup!(agent, text)
label(item::Deferred{Send}) = "Steering: " * replace(item.text, '\n' => ' ')
label(item::Deferred{Follow}) = "Follow-up: " * replace(item.text, '\n' => ' ')

function queue!(session::Session, text, mode::Submission)
    lock(session.agent.lock) do
        queue!(session, text, mode, session.agent.turn, session.agent.state.phase)
    end
end
defer!(session, text, mode) = defer!(session.deferred, text, mode)
queue!(session, text, mode, ::Union{JuliaForever.Idle, JuliaForever.Cancelled}, phase) = defer!(session, text, mode)
queue!(session, text, mode, ::JuliaForever.Running, ::JuliaForever.Conversation.Phase) = enqueue!(session.agent, text, mode)
queue!(session, text, mode, ::JuliaForever.Running, ::Union{JuliaForever.Conversation.CompletePhase, JuliaForever.Conversation.IncompletePhase, JuliaForever.Conversation.CancelledPhase}) = defer!(session, text, mode)

function remember!(session, state)
    LineEdit.add_history(state)
    TerminalEditor.remember!(session.editor)
end

function launch!(session, text)
    session.activity = Busy()
    session.task = Threads.@spawn begin
        result = Ref{Union{Nothing, Int}}(nothing)
        try
            result[] = JuliaForever.run!(session.terminal, session.agent, text, session.extensions; on_agent_event=event -> event!(session, event))
        finally
            lock(session.editor.state.line_modify_lock) do
                completed!(session, result[])
                redraw!(session)
            end
        end
    end
    nothing
end

completed!(session, ::Nothing) = (session.activity = Available())
completed!(session, status::Int) = completed!(session, get(outcomes, status, Failed(status)))
function completed!(session, ::Union{Completed, Interrupted})
    session.activity = Available()
    continue!(session)
end
function completed!(session, failed::Failed)
    session.status = max(session.status, failed.status)
    session.activity = Available()
    restore!(session, session.editor.state, JuliaForever.dequeue!(session.agent))
end

function continue!(session)
    isempty(session.deferred) && return nothing
    launch!(session, next!(session.deferred))
end

waittask(::Nothing) = nothing
waittask(task::Task) = wait(task)

continuation!(state, ::Follow) = false
function continuation!(state, ::Send)
    buffer = LineEdit.buffer(state)
    if position(buffer) > 0 && buffer.data[position(buffer)] == UInt8('\\')
        LineEdit.edit_backspace(state)
        LineEdit.edit_insert_newline(state, 0)
        return true
    end
    false
end

send!(session, state, mode::Submission) = sendcompletion!(session, state, mode, synccompletion!(session, state))
sendcompletion!(session, state, mode::Submission, completion::Completion.State) = sendinput!(session, state, mode)
function sendcompletion!(session, state, ::Send, completion::Completion.Menu)
    applycompletion!(session, state, completion)
    sendinput!(session, state, Send())
end

function sendinput!(session, state, mode::Submission)
    continuation!(state, mode) && return :ok
    text = String(strip(LineEdit.input_string(state)))
    isempty(text) && return :ok
    LineEdit.replace_line(state, text)
    send!(session, state, mode, text, session.activity, JuliaForever.terminalcommand(text))
end

function send!(session, state, mode, text, ::Available, ::Nothing)
    waittask(session.task)
    LineEdit.commit_line(state)
    LineEdit.reset_state(state)
    TerminalEditor.remember!(session.editor)
    LineEdit.refresh_line(state)
    launch!(session, JuliaForever.Prompts.expand(text, session.templates))
    :ok
end

function send!(session, state, mode, text, ::Available, command::JuliaForever.TerminalCommand)
    waittask(session.task)
    LineEdit.commit_line(state)
    session.visibility = Hidden()
    :done
end

function send!(session, state, mode, text, ::Busy, ::Nothing)
    queued!(session, state, queue!(session, JuliaForever.Prompts.expand(text, session.templates), mode))
end

function send!(session, state, mode, text, ::Busy, ::JuliaForever.ExitCommand)
    empty!(session.deferred)
    JuliaForever.cancel!(session.agent)
    LineEdit.commit_line(state)
    session.area = nothing
    session.partial = ""
    session.visibility = Hidden()
    :done
end
function send!(session, state, mode, text, ::Busy, ::JuliaForever.ReloadCommand)
    remember!(session, state)
    LineEdit.replace_line(state, "")
    redraw!(session, "Wait for the current response to finish before reloading.\n")
    :ok
end
send!(session, state, mode, text, ::Busy, command::JuliaForever.TerminalCommand) = command!(session, state)
send!(session, state, mode, text, ::Available, command::Union{JuliaForever.ShowName, JuliaForever.SetName}) = (waittask(session.task); inline!(session, state, command))
send!(session, state, mode, text, ::Busy, command::Union{JuliaForever.ShowName, JuliaForever.SetName}) = inline!(session, state, command)

function inline!(session, state, command)
    remember!(session, state)
    LineEdit.replace_line(state, "")
    diagnostics = IOBuffer()
    terminal = JuliaForever.Terminal(session.terminal.output, diagnostics, session.terminal.secrets)
    _, _, result = JuliaForever.command!(command, terminal, session.agent, session.agent.history, session.editor.terminal.in_stream, "", session.extensions)
    session.status = max(session.status, result)
    sessionname!(session)
    redraw!(session, String(take!(diagnostics)))
    :ok
end

function command!(session, state)
    queued = lock(session.agent.lock) do
        queued = JuliaForever.dequeue!(session.agent)
        JuliaForever.cancel!(session.agent)
        queued
    end
    draft!(session, queued)
    LineEdit.commit_line(state)
    session.area = nothing
    session.partial = ""
    session.visibility = Hidden()
    :done
end

draft!(session, rejected::JuliaForever.History.Rejected) = JuliaForever.result!(session.terminal, rejected)
draft!(session, queued::NamedTuple) = (session.draft = join(collect!(session, queued), "\n\n"))

function queued!(session, state, ::Nothing)
    remember!(session, state)
    LineEdit.replace_line(state, "")
    redraw!(session)
    :ok
end
function queued!(session, state, rejected::JuliaForever.History.Rejected)
    JuliaForever.result!(session.terminal, rejected)
    :ok
end

collect!(session, queued::NamedTuple) = collect!(session.deferred, queued)

function restore!(session, state, queued::NamedTuple)
    text = LineEdit.input_string(state)
    parts = [collect!(session, queued); [text]]
    LineEdit.replace_line(state, join(filter(part -> !isempty(strip(part)), parts), "\n\n"))
    redraw!(session)
    :ok
end
function restore!(session, state, rejected::JuliaForever.History.Rejected)
    JuliaForever.result!(session.terminal, rejected)
    :ok
end

dequeue!(session, state) = restore!(session, state, JuliaForever.dequeue!(session.agent))
abort!(session, state, ::Available) = :ok
function abort!(session, state, ::Busy)
    queued = lock(session.agent.lock) do
        queued = JuliaForever.dequeue!(session.agent)
        JuliaForever.cancel!(session.agent)
        queued
    end
    restore!(session, state, queued)
end

clear!(session, state) = clear!(session, state, get(TerminalEditor.clearstates, state.last_action, TerminalEditor.OtherAction()))
clear!(session, state, ::TerminalEditor.OtherAction) = clearinput!(session, state)
function clear!(session, state, ::TerminalEditor.PreviousClear)
    isempty(LineEdit.input_string(state)) && return :abort
    clearinput!(session, state)
end

function clearinput!(session, state)
    LineEdit.replace_line(state, "")
    LineEdit.set_action!(state, :clear)
    redraw!(session)
    :ok
end

function escape!(session, state, data, escapes, keymap)
    input = session.editor.terminal.in_stream
    Base.start_reading(input)
    received = get(escapewaits, timedwait(() -> bytesavailable(input) > 0, 0.04; pollint=0.005), EscapeAlone())
    escape!(session, state, data, escapes, keymap, received)
end
escape!(session, state, data, escapes, keymap, ::EscapeSequence) = LineEdit.match_input(escapes, state, LineEdit.terminal(state), Char['\e'], keymap)(state, data)
escape!(session, state, data, escapes, keymap, ::EscapeAlone) = escapecompletion!(session, state, synccompletion!(session, state))

function createeditor(input, terminal, reference, view::View)
    extra = Dict{Any, Any}(
        "*" => (state, data, text) -> insertcompletion!(reference[], state, text),
        '\t' => (state, args...) -> tabcompletion!(reference[], state),
        "\e[A" => (state, args...) -> upcompletion!(reference[], state),
        "\e[B" => (state, args...) -> downcompletion!(reference[], state),
        "\e[D" => (state, args...) -> editcompletion!(reference[], state, TerminalEditor.left!),
        "\e[C" => (state, args...) -> editcompletion!(reference[], state, TerminalEditor.right!),
        "^B" => (state, args...) -> editcompletion!(reference[], state, TerminalEditor.left!),
        "^F" => (state, args...) -> editcompletion!(reference[], state, TerminalEditor.right!),
        '\b' => (state, args...) -> editcompletion!(reference[], state, TerminalEditor.backspace!),
        '\x7f' => (state, args...) -> editcompletion!(reference[], state, TerminalEditor.backspace!),
        "\e[3~" => (state, args...) -> editcompletion!(reference[], state, TerminalEditor.forward!),
        '\n' => (state, args...) -> editcompletion!(reference[], state, TerminalEditor.newline!),
        "\e[200~" => (state, args...) -> pastecompletion!(reference[], state),
        '\r' => (state, args...) -> send!(reference[], state, Send()),
        "\e\r" => (state, args...) -> send!(reference[], state, Follow()),
        "\e[13;3u" => (state, args...) -> send!(reference[], state, Follow()),
        "\e[13;3~" => (state, args...) -> send!(reference[], state, Follow()),
        "^Q" => (state, args...) -> send!(reference[], state, Follow()),
        "^C" => (state, args...) -> clear!(reference[], state),
        "\e[1;3A" => (state, args...) -> dequeue!(reference[], state),
    )
    merge!(extra, viewkeys(view, reference))
    editor = TerminalEditor.Editor(input, editoroutput(view, reference, terminal.diagnostics); extra)
    keymap = LineEdit.mode(editor.state).keymap_dict
    original = copy(keymap)
    escapes = original['\e']
    keymap['\e'] = (state, data, chars) -> escape!(reference[], state, data, escapes, original)
    editor
end

include("terminal_menus.jl")

stop!(session, ::Available) = nothing
stop!(session, ::Busy) = JuliaForever.cancel!(session.agent)

function loop!(terminal, agent, extensions, history, input::Base.TTY, directory, templates, mode::Mode=FullscreenMode())
    reference = Ref{Any}()
    view = createview(mode, terminal.output)
    intro!(view, terminal.diagnostics)
    editor = createeditor(input, terminal, reference, view)
    session = Session(editor, terminal, agent, templates, extensions, view)
    reference[] = session
    try
        start!(session)
        for line in editor
            waittask(session.task)
            line == "/exit" && break
            draft = Ref(session.draft)
            previous = session.agent
            mark = mark!(session.view)
            agent, selected, result = uicommand!(session, session.view, JuliaForever.terminalcommand(line), terminal, history[], input, directory, extensions, draft)
            history[] = selected
            session.agent = agent
            aftercommand!(session.view, previous, agent, mark, session.terminal)
            session.status = max(session.status, result)
            sessionname!(session)
            LineEdit.replace_line(editor.state, draft[])
            session.draft = ""
            session.visibility = Visible()
            redraw!(session)
        end
    finally
        try
            lock(editor.state.line_modify_lock) do
                session.visibility = Hidden()
                empty!(session.deferred)
            end
            stop!(session, session.activity)
            waittask(session.task)
        finally
            finish!(session)
        end
    end
    session.status
end

end
