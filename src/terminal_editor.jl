module TerminalEditor

import REPL
import Unicode
const LineEdit = REPL.LineEdit

function enter!(state, args...)
    buffer = LineEdit.buffer(state)
    if position(buffer) > 0 && buffer.data[position(buffer)] == UInt8('\\')
        LineEdit.edit_backspace(state)
        LineEdit.edit_insert_newline(state, 0)
        return :ok
    end
    text = strip(LineEdit.input_string(state))
    LineEdit.replace_line(state, text)
    if isempty(text)
        LineEdit.refresh_line(state)
        return :ok
    end
    LineEdit.commit_line(state)
    :done
end

newline!(state, args...) = LineEdit.edit_insert_newline(state, 0)

const controls = merge(Dict("\e[$code;5u" => string(Char(code - 96)) for code in 97:122), Dict("\e[$code;5u" => string(Char(code - 64)) for code in 65:90))

function paste!(state, args...)
    text = readuntil(LineEdit.terminal(state), "\e[201~")
    text = replace(text, r"\e\[\d+;5u" => token -> get(controls, token, token))
    text = replace(replace(replace(text, "\r\n" => "\n"), '\r' => '\n'), '\t' => "    ")
    text = replace(text, r"[\x00-\x09\x0b-\x1f]" => "")
    LineEdit.edit_insert(state, text)
end

function boundaries(state)
    positions = Int[0]
    for grapheme in Unicode.graphemes(LineEdit.input_string(state))
        push!(positions, last(positions) + ncodeunits(grapheme))
    end
    positions
end

function previous(state)
    positions = boundaries(state)
    get(positions, searchsortedlast(positions, position(LineEdit.buffer(state)) - 1), 0)
end

function following(state)
    positions = boundaries(state)
    buffer = LineEdit.buffer(state)
    get(positions, searchsortedfirst(positions, position(buffer) + 1), buffer.size)
end

function move!(state, position)
    seek(LineEdit.buffer(state), position)
    LineEdit.refresh_line(state)
end

left!(state, args...) = move!(state, previous(state))
right!(state, args...) = move!(state, following(state))
linestart!(state, args...) = (LineEdit.move_line_start(state); LineEdit.refresh_line(state))
lineend!(state, args...) = (LineEdit.move_line_end(state); LineEdit.refresh_line(state))
ignore!(state, args...) = nothing

function erase!(state, first, last)
    first == last && return LineEdit.beep(state)
    LineEdit.push_undo(state)
    LineEdit.edit_splice!(state, first => last)
    LineEdit.refresh_line(state)
end

backspace!(state, args...) = erase!(state, previous(state), position(LineEdit.buffer(state)))
forward!(state, args...) = erase!(state, position(LineEdit.buffer(state)), following(state))

function history!(state)
    history = LineEdit.mode(state).hist
    if history.cur_idx <= length(history.history) && LineEdit.input_string(state) != history.history[history.cur_idx]
        history.cur_idx = length(history.history) + 1
        history.last_idx = -1
    end
    history
end

function up!(state, args...)
    history = history!(state)
    LineEdit.edit_move_up(state) && return
    if history.cur_idx > length(history.history) && position(LineEdit.buffer(state)) > 0
        LineEdit.move_line_start(state)
        LineEdit.refresh_line(state)
    else
        LineEdit.history_prev(state, history)
        LineEdit.move_input_start(state)
        LineEdit.refresh_line(state)
    end
end

function down!(state, args...)
    history = history!(state)
    LineEdit.edit_move_down(state) && return
    if history.cur_idx <= length(history.history)
        position = Base.position(history.last_buffer)
        last = Val(history.cur_idx == length(history.history))
        LineEdit.history_next(state, history)
        restoredraft!(state, position, last)
    else
        LineEdit.move_line_end(state)
        LineEdit.refresh_line(state)
    end
end

function restoredraft!(state, position, ::Val{true})
    seek(LineEdit.buffer(state), position)
    LineEdit.refresh_line(state)
end

restoredraft!(state, position, ::Val{false}) = nothing

struct PreviousClear end
struct OtherAction end
const clearstates = Dict(:clear => PreviousClear())

clear!(state, args...) = clear!(state, get(clearstates, state.last_action, OtherAction()))
clear!(state, ::OtherAction) = clearinput!(state)
clear!(state, ::PreviousClear) = clear!(state, Val(LineEdit.buffer(state).size == 0))
clear!(state, ::Val{false}) = clearinput!(state)
clear!(state, ::Val{true}) = (println(LineEdit.terminal(state)); :abort)

function clearinput!(state)
    LineEdit.move_input_end(state)
    LineEdit.refresh_line(state)
    print(LineEdit.terminal(state), "^C\n")
    LineEdit.transition(state, :reset)
    LineEdit.refresh_line(state)
    LineEdit.set_action!(state, :clear)
    :ok
end

delete!(state, args...) = LineEdit.buffer(state).size == 0 ? LineEdit.edit_abort(state, false) : forward!(state)

struct Editor
    terminal::REPL.Terminals.TTYTerminal
    interface::LineEdit.ModalInterface
    state::LineEdit.MIState
    history::REPL.REPLHistoryProvider
end

function Editor(input::Base.TTY, output::IO)
    history = REPL.REPLHistoryProvider(Dict{Symbol, LineEdit.Prompt}())
    prompt = LineEdit.Prompt("> "; hist=history)
    history.mode_mapping[:julia] = prompt
    LineEdit.reset_state(history)
    keys = Dict{Any, Any}('\r' => enter!, '\n' => newline!, "\e\r" => newline!, "\e[13;2~" => newline!, "\e[13;2u" => newline!, "\e[200~" => paste!, "\e[A" => up!, "\e[B" => down!, "\e[D" => left!, "\e[C" => right!, "\e[H" => linestart!, "\e[1~" => linestart!, "\e[F" => lineend!, "\e[4~" => lineend!, "^B" => left!, "^F" => right!, '\b' => backspace!, '\x7f' => backspace!, "\e[3~" => forward!, "^C" => clear!, "^D" => delete!, "^L" => ignore!, "^P" => ignore!, "^N" => ignore!, "^T" => ignore!, "\e[1;2A" => ignore!, "\e[1;2B" => ignore!, "\e[1;2C" => ignore!, "\e[1;2D" => ignore!)
    prompt.keymap_dict = LineEdit.keymap(Dict{Any, Any}[keys, LineEdit.default_keymap, LineEdit.escape_defaults])
    interface = LineEdit.ModalInterface(LineEdit.TextInterface[prompt])
    terminal = REPL.Terminals.TTYTerminal(get(ENV, "TERM", "dumb"), input, output, output)
    Editor(terminal, interface, LineEdit.init_state(terminal, interface), history)
end

function next!(editor::Editor)
    buffer, accepted, suspended = LineEdit.prompt!(editor.terminal, editor.interface, editor.state)
    next!(editor, buffer, Val(accepted), Val(suspended))
end

function next!(editor::Editor, buffer, accepted, ::Val{true})
    @static if Sys.isunix()
        ccall(:jl_repl_raise_sigtstp, Cint, ())
    end
    next!(editor)
end

function next!(editor::Editor, buffer, ::Val{true}, ::Val{false})
    text = String(take!(copy(buffer)))
    LineEdit.reset_state(editor.state)
    excess = max(length(editor.history.history) - 100, 0)
    deleteat!(editor.history.history, 1:excess)
    deleteat!(editor.history.modes, 1:excess)
    LineEdit.reset_state(editor.history)
    text, nothing
end

next!(editor::Editor, buffer, ::Val{false}, ::Val{false}) = nothing
Base.iterate(editor::Editor) = next!(editor)
Base.iterate(editor::Editor, ::Nothing) = next!(editor)

end

terminalinput(input::IO, output::IO) = eachline(input)

function terminalinput(input::Base.TTY, output::IO)
    println(output, "Julia Forever — Enter sends, Ctrl+J adds a line, /exit quits")
    TerminalEditor.Editor(input, output)
end
