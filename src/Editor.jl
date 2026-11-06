@kwdef mutable struct EditorState
    undo::Vector{Tuple{Vector{Char},Int}} = Tuple{Vector{Char},Int}[]
    kill::Vector{Char} = Char[]
    last_action::Symbol = :none
end

function reset_editor!(state::EditorState)
    empty!(state.undo)
    empty!(state.kill)
    state.last_action = :none
end

function save_edit!(state::EditorState, input::TextInput, action::Symbol)
    if action != :typing || state.last_action != :typing
        push!(state.undo, (copy(input.buffer), input.cursor))
        length(state.undo) > 100 && popfirst!(state.undo)
    end
    state.last_action = action
end

function raw_editor_command(raw::AbstractVector{UInt8})
    n = length(raw)
    n >= 2 && raw[1] == 0x1b || return nothing
    if n == 2
        raw[2] == UInt8('b') && return :word_left
        raw[2] == UInt8('f') && return :word_right
        raw[2] == UInt8('d') && return :kill_word_forward
        raw[2] in (0x7f, 0x08) && return :kill_word_back
        return nothing
    end
    raw[2] == UInt8('[') || return nothing
    final = raw[end]
    final in (UInt8('u'), UInt8('C'), UInt8('D'), UInt8('H'), UInt8('F'), UInt8('~')) || return nothing
    key, modifier, field = 0, 0, 1
    reading = true
    has_modifier = false
    has_text = false
    for i in 3:n-1
        b = raw[i]
        if b == UInt8(';')
            field += 1
            reading = true
            field == 2 && (has_modifier = true)
            field == 3 && (has_text = true)
        elseif b == UInt8(':')
            reading = false
        elseif reading && UInt8('0') <= b <= UInt8('9')
            field == 1 && (key = min(1_000_000, 10 * key + Int(b - UInt8('0'))))
            field == 2 && (modifier = min(1_000, 10 * modifier + Int(b - UInt8('0'))))
        end
    end
    has_modifier || return nothing
    bits = max(1, modifier) - 1
    shift, alt, ctrl, super = (bits & 1 != 0), (bits & 2 != 0), (bits & 4 != 0), (bits & 8 != 0)
    (alt || ctrl || super) || return nothing
    if super
        if !alt && !ctrl && !shift
            final == UInt8('D') && return :line_start
            final == UInt8('C') && return :line_end
            final == UInt8('u') && key in (127, 57347) && return :clear_line
            (final == UInt8('u') && key == 57349 || final == UInt8('~') && key == 3) && return :kill_to_end
        end
        return :ignore
    end
    if !super && !shift && (alt ⊻ ctrl)
        final == UInt8('D') && return :word_left
        final == UInt8('C') && return :word_right
        ctrl && final == UInt8('H') && return :scroll_top
        ctrl && final == UInt8('F') && return :scroll_bottom
        final == UInt8('u') && key in (127, 57347) && return :kill_word_back
        (final == UInt8('u') && key == 57349 || final == UInt8('~') && key == 3) && return :kill_word_forward
        ctrl && final == UInt8('u') && key in (45, 95) && return :undo
        if alt && final == UInt8('u') && !has_text
            key == Int('b') && return :word_left
            key == Int('f') && return :word_right
            key == Int('d') && return :kill_word_forward
        end
    end
    final == UInt8('u') && key in (9, 13, 27, 57344, 57345, 57346) && return :ignore
    return nothing
end

function editor_command(event::KeyEvent)
    if !Sys.iswindows() && Tachikoma.raw_capture_enabled()
        command = raw_editor_command(Tachikoma.last_event_raw())
        command === nothing || return command
    end
    event.key == :ctrl || return nothing
    c = event.char
    c == 'a' && return :line_start
    c == 'e' && return :line_end
    c == 'b' && return :left
    c == 'f' && return :right
    c == 'd' && return :delete_forward
    c == 'w' && return :kill_word_back
    c == 'u' && return :kill_to_start
    c == 'k' && return :kill_to_end
    c == 'y' && return :yank
    c in ('_', '\x7f') && return :undo
    nothing
end

function word_kind(c::Char)
    isspace(c) && return :space
    (isletter(c) || isnumeric(c) || Base.Unicode.category_abbrev(c) in ("Mn", "Mc", "Me")) ? :word : :punctuation
end

function word_left(input::TextInput)
    i = input.cursor
    while i > 0 && word_kind(input.buffer[i]) == :space
        i -= 1
    end
    i == 0 && return i
    kind = word_kind(input.buffer[i])
    while i > 0 && word_kind(input.buffer[i]) == kind
        i -= 1
    end
    i
end

function word_right(input::TextInput)
    i, n = input.cursor, length(input.buffer)
    while i < n && word_kind(input.buffer[i + 1]) == :space
        i += 1
    end
    i == n && return i
    kind = word_kind(input.buffer[i + 1])
    while i < n && word_kind(input.buffer[i + 1]) == kind
        i += 1
    end
    i
end

function kill_range!(input::TextInput, state::EditorState, first::Int, last::Int; backward=false)
    first > last && return
    deleted = input.buffer[first:last]
    accumulate = state.last_action == :kill
    save_edit!(state, input, :kill)
    if accumulate
        state.kill = backward ? vcat(deleted, state.kill) : vcat(state.kill, deleted)
    else
        state.kill = deleted
    end
    deleteat!(input.buffer, first:last)
    input.cursor = first - 1
    Tachikoma._run_validator!(input)
end

function edit_input!(input::TextInput, state::EditorState, event::KeyEvent, command=editor_command(event))
    input.focused || return false
    if command === :ignore
        state.last_action = :none
    elseif command === :line_start
        input.cursor = 0; state.last_action = :none
    elseif command === :line_end
        input.cursor = length(input.buffer); state.last_action = :none
    elseif command === :word_left
        input.cursor = word_left(input); state.last_action = :none
    elseif command === :word_right
        input.cursor = word_right(input); state.last_action = :none
    elseif command === :clear_line
        state.last_action = :none
        kill_range!(input, state, 1, length(input.buffer); backward=true)
    elseif command === :kill_to_start
        kill_range!(input, state, 1, input.cursor; backward=true)
    elseif command === :kill_to_end
        kill_range!(input, state, input.cursor + 1, length(input.buffer))
    elseif command === :kill_word_back
        kill_range!(input, state, word_left(input) + 1, input.cursor; backward=true)
    elseif command === :kill_word_forward
        kill_range!(input, state, input.cursor + 1, word_right(input))
    elseif command === :yank
        if !isempty(state.kill)
            save_edit!(state, input, :yank)
            splice!(input.buffer, input.cursor+1:input.cursor, state.kill)
            input.cursor += length(state.kill)
            Tachikoma._run_validator!(input)
        end
    elseif command === :undo
        if !isempty(state.undo)
            input.buffer, input.cursor = pop!(state.undo)
            Tachikoma._run_validator!(input)
        end
        state.last_action = :none
    else
        evt = command === :left ? KeyEvent(:left) : command === :right ? KeyEvent(:right) :
              command === :delete_forward ? KeyEvent(:delete) : event
        if evt.key == :char
            save_edit!(state, input, :typing)
        elseif (evt.key == :backspace && input.cursor > 0) ||
               (evt.key == :delete && input.cursor < length(input.buffer))
            save_edit!(state, input, :delete)
        else
            state.last_action = :none
        end
        handled = handle_key!(input, evt)
        evt.key == :char && isspace(evt.char) && (state.last_action = :none)
        return handled
    end
    true
end
