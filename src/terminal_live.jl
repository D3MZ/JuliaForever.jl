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

struct Deferred{M<:Submission}
    text::String
    mode::M
end

mutable struct Session
    editor::TerminalEditor.Editor
    physical::IO
    agent::JuliaForever.Agent
    terminal::JuliaForever.Terminal
    templates::Dict{String, String}
    activity::Activity
    visibility::Visibility
    task::Union{Nothing, Task}
    partial::String
    area::Union{Nothing, LineEdit.InputAreaState}
    deferred::Vector{Deferred}
    draft::String
    status::Int
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

function Session(editor, terminal, agent, templates)
    session = Session(editor, terminal.diagnostics, agent, terminal, templates, Available(), Visible(), nothing, "", nothing, Deferred[], "", 0)
    session.terminal = JuliaForever.Terminal(output(session, terminal.output), Output(session), terminal.secrets)
    session
end
output(session, stream::IO) = stream
output(session, stream::Base.TTY) = output(session.physical, session, stream)
output(physical::IO, session, stream::Base.TTY) = stream
output(physical::Base.TTY, session, stream::Base.TTY) = Output(session)

function queues(session)
    lock(session.agent.lock) do
        (; steering=session.agent.state.steering, followups=session.agent.state.followups)
    end
end

cleararea!(session, ::Nothing) = nothing
function cleararea!(session, area::LineEdit.InputAreaState)
    Terminals.cmove_up(session.editor.terminal, 1)
    LineEdit._clear_input_area(session.editor.terminal, area)
end

function redraw!(session, prefix="")
    lock(session.editor.state.line_modify_lock) do
        redraw!(session, session.visibility, prefix)
    end
end
redraw!(session, ::Hidden, prefix) = (print(session.physical, prefix); flush(session.physical))

function redraw!(session, ::Visible, prefix)
    terminal = session.editor.terminal
    state = session.editor.state
    LineEdit.clear_input_area(LineEdit.state(state))
    cleararea!(session, session.area)
    print(terminal, prefix)
    queued = queues(session)
    lines = String[]
    isempty(session.partial) || push!(lines, session.partial)
    append!(lines, ["Steering: " * replace(text, '\n' => ' ') for text in queued.steering])
    append!(lines, ["Follow-up: " * replace(text, '\n' => ' ') for text in queued.followups])
    append!(lines, [label(item) for item in session.deferred])
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
deferred!(steering, followups, item::Deferred{Send}) = push!(steering, item.text)
deferred!(steering, followups, item::Deferred{Follow}) = push!(followups, item.text)
steering(::Deferred{Send}) = true
steering(::Deferred{Follow}) = false

function queue!(session::Session, text, mode::Submission)
    lock(session.agent.lock) do
        queue!(session, text, mode, session.agent.turn, session.agent.state.phase)
    end
end
defer!(session, text, mode) = (push!(session.deferred, Deferred(text, mode)); nothing)
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
            result[] = JuliaForever.run!(session.terminal, session.agent, text; on_agent_event=event -> redraw!(session))
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
    continue!(session, findfirst(steering, session.deferred))
end
continue!(session, ::Nothing) = launch!(session, popfirst!(session.deferred).text)
function continue!(session, index::Int)
    item = splice!(session.deferred, index)
    launch!(session, item.text)
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

function send!(session, state, mode::Submission)
    continuation!(state, mode) && return :ok
    text = String(strip(LineEdit.input_string(state)))
    isempty(text) && return :ok
    send!(session, state, mode, text, session.activity)
end

function send!(session, state, mode, text, ::Available)
    waittask(session.task)
    LineEdit.replace_line(state, text)
    LineEdit.commit_line(state)
    if text == "/exit" || haskey(JuliaForever.terminalcommands, text)
        session.visibility = Hidden()
        return :done
    end
    LineEdit.reset_state(state)
    TerminalEditor.remember!(session.editor)
    LineEdit.refresh_line(state)
    launch!(session, JuliaForever.Prompts.expand(text, session.templates))
    :ok
end

function send!(session, state, mode, text, ::Busy)
    if text == "/exit"
        empty!(session.deferred)
        JuliaForever.cancel!(session.agent)
        LineEdit.commit_line(state)
        session.area = nothing
        session.partial = ""
        session.visibility = Hidden()
        return :done
    end
    haskey(JuliaForever.terminalcommands, text) && return command!(session, state)
    queued!(session, state, queue!(session, JuliaForever.Prompts.expand(text, session.templates), mode))
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

function collect!(session, queued::NamedTuple)
    foreach(item -> deferred!(queued.steering, queued.followups, item), session.deferred)
    empty!(session.deferred)
    [queued.steering; queued.followups]
end

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
escape!(session, state, data, escapes, keymap, ::EscapeAlone) = abort!(session, state, session.activity)

function createeditor(input, terminal, reference)
    extra = Dict{Any, Any}(
        '\r' => (state, args...) -> send!(reference[], state, Send()),
        "\e\r" => (state, args...) -> send!(reference[], state, Follow()),
        "\e[13;3u" => (state, args...) -> send!(reference[], state, Follow()),
        "\e[13;3~" => (state, args...) -> send!(reference[], state, Follow()),
        "^Q" => (state, args...) -> send!(reference[], state, Follow()),
        "^C" => (state, args...) -> clear!(reference[], state),
        "\e[1;3A" => (state, args...) -> dequeue!(reference[], state),
    )
    editor = TerminalEditor.Editor(input, terminal.diagnostics; extra)
    keymap = LineEdit.mode(editor.state).keymap_dict
    original = copy(keymap)
    escapes = original['\e']
    keymap['\e'] = (state, data, chars) -> escape!(reference[], state, data, escapes, original)
    editor
end

stop!(session, ::Available) = nothing
stop!(session, ::Busy) = JuliaForever.cancel!(session.agent)

function loop!(terminal, agent, history, input::Base.TTY, directory, templates)
    println(terminal.diagnostics, "Julia Forever — Enter sends, Alt+Enter follows up, Esc interrupts, /exit quits")
    reference = Ref{Any}()
    editor = createeditor(input, terminal, reference)
    session = Session(editor, terminal, agent, templates)
    reference[] = session
    try
        for line in editor
            waittask(session.task)
            line == "/exit" && break
            agent, selected, result = JuliaForever.command!(JuliaForever.terminalcommands[line], terminal, session.agent, history[], input, directory)
            history[] = selected
            session.agent = agent
            session.status = max(session.status, result)
            LineEdit.replace_line(editor.state, session.draft)
            session.draft = ""
            session.visibility = Visible()
        end
    finally
        lock(editor.state.line_modify_lock) do
            session.visibility = Hidden()
            empty!(session.deferred)
        end
        stop!(session, session.activity)
        waittask(session.task)
    end
    session.status
end

end
