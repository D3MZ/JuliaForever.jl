function synccompletion!(session, state)
    buffer = LineEdit.buffer(state)
    before = String(copy(buffer.data[1:position(buffer)]))
    text = LineEdit.input_string(state)
    synccompletion!(session, state, session.completion, before, text)
end

function synccompletion!(session, state, current::Completion.DismissedFiles, before, text)
    current.before == before && current.text == text && return current
    synccompletion!(session, state, Completion.Closed(), before, text)
end

function synccompletion!(session, state, current::Union{Completion.PendingFiles, Completion.FileMenu}, before, text)
    current.before == before && current.text == text && return current
    syncfile!(session, state, Completion.followup(current.request), before, text)
end

function synccompletion!(session, state, current::Completion.State, before, text)
    syncautomatic!(session, state, current, before, text, Completion.atprefix(before))
end
syncautomatic!(session, state, current, before, text, ::Nothing) = (session.completion = Completion.update(current, Completion.prefix(before), session.templates))
syncautomatic!(session, state, current, before, text, prefix::AbstractString) = requestfiles!(session, state, before, text, Completion.Automatic())

syncfile!(session, state, ::Completion.Automatic, before, text) = synccompletion!(session, state, Completion.Closed(), before, text)
syncfile!(session, state, ::Completion.Forced, before, text) = requestfiles!(session, state, before, text, Completion.Forced())

function requestfiles!(session, state, before, text, request::Completion.FileRequest)
    pending = Completion.PendingFiles(before, text, request)
    session.completion = pending
    root = pwd()
    home = homedir()
    errormonitor(@async begin
        Completion.delay(request)
        active() = Completion.searchstates[session.completion === pending]
        searchfiles!(session, state, pending, before, root, home, request, active, active())
    end)
    pending
end

searchfiles!(session, state, pending, before, root, home, request, active, ::Completion.Stopped) = nothing
function searchfiles!(session, state, pending, before, root, home, request, active, ::Completion.Searching)
    files = Completion.files(before, root, request; home, active)
    lock(session.editor.state.line_modify_lock) do
        finishfiles!(session, state, pending, files, active())
    end
end
finishfiles!(session, state, pending, files, ::Completion.Stopped) = nothing
finishfiles!(session, state, pending, files, ::Completion.Searching) = finishfiles!(session, state, pending, files)

function finishfiles!(session, state, pending, ::Nothing)
    session.completion = Completion.dismiss(pending)
    refreshcompletion!(session, session.view, pending, session.completion)
end
finishfiles!(session, state, pending, files::Completion.Files) = finishfiles!(session, state, pending, files, pending.request)
function finishfiles!(session, state, pending, files, request::Completion.FileRequest)
    menu = Completion.FileMenu(pending.before, pending.text, files.prefix, files.items, 1, Completion.followup(request))
    session.completion = menu
    displayfiles!(session, state, pending, menu, request)
end
function displayfiles!(session, state, pending, menu, ::Completion.Explicit)
    length(menu.items) == 1 && return applycompletion!(session, state, menu)
    refreshcompletion!(session, session.view, pending, menu)
end
displayfiles!(session, state, pending, menu, ::Completion.FileRequest) = refreshcompletion!(session, session.view, pending, menu)

refreshcompletion!(session, ::Fullscreen, previous, current) = paint!(session)
refreshcompletion!(session, ::Regular, ::Completion.Closed, ::Completion.Closed) = nothing
refreshcompletion!(session, ::Regular, previous, current) = redraw!(session)

function editcompletion!(session, state, action)
    previous = session.completion
    result = action(state)
    current = synccompletion!(session, state)
    refreshcompletion!(session, session.view, previous, current)
    result
end

function insertcompletion!(session, state, text)
    editcompletion!(session, state, state -> LineEdit.edit_insert(state, text))
end

function pastecompletion!(session, state)
    previous = session.completion
    result = TerminalEditor.paste!(state)
    session.completion = Completion.dismiss(synccompletion!(session, state))
    refreshcompletion!(session, session.view, previous, session.completion)
    result
end

tabcompletion!(session, state) = tabcompletion!(session, state, synccompletion!(session, state))
function tabcompletion!(session, state, closed::Completion.Closed)
    buffer = LineEdit.buffer(state)
    before = String(copy(buffer.data[1:position(buffer)]))
    tabfile!(session, state, before, Completion.prefix(before))
end
tabfile!(session, state, before, prefix::AbstractString) = :ok
function tabfile!(session, state, before, ::Nothing)
    requestfiles!(session, state, before, LineEdit.input_string(state), Completion.Explicit())
    :ok
end
function tabcompletion!(session, state, dismissed::Completion.Dismissed)
    session.completion = Completion.open(dismissed.prefix, session.templates)
    refreshcompletion!(session, session.view, dismissed, session.completion)
    :ok
end
tabcompletion!(session, state, menu::Completion.Menu) = (applycompletion!(session, state, menu); :ok)
tabcompletion!(session, state, menu::Completion.FileMenu) = (applycompletion!(session, state, menu); :ok)
function tabcompletion!(session, state, current::Union{Completion.PendingFiles, Completion.DismissedFiles})
    requestfiles!(session, state, current.before, current.text, Completion.Explicit())
    :ok
end

function applycompletion!(session, state, menu::Completion.Menu)
    buffer = LineEdit.buffer(state)
    cursor = position(buffer)
    LineEdit.push_undo(state)
    LineEdit.edit_splice!(state, cursor - ncodeunits(menu.prefix) => cursor, "/" * menu.items[menu.index].name * " ")
    session.completion = Completion.Closed()
    LineEdit.refresh_line(state)
    current = synccompletion!(session, state)
    refreshcompletion!(session, session.view, menu, current)
    nothing
end

function applycompletion!(session, state, menu::Completion.FileMenu)
    buffer = LineEdit.buffer(state)
    cursor = position(buffer)
    before = String(copy(buffer.data[1:cursor]))
    after = String(copy(buffer.data[cursor + 1:buffer.size]))
    text, offset = Completion.apply(before, after, menu.prefix, menu.items[menu.index])
    LineEdit.push_undo(state)
    LineEdit.edit_splice!(state, 0 => buffer.size, text)
    seek(LineEdit.buffer(state), offset)
    before = String(Vector{UInt8}(codeunits(text)[1:offset]))
    session.completion = Completion.DismissedFiles(before, text)
    LineEdit.refresh_line(state)
    refreshcompletion!(session, session.view, menu, session.completion)
    nothing
end

upcompletion!(session, state) = upcompletion!(session, state, synccompletion!(session, state))
downcompletion!(session, state) = downcompletion!(session, state, synccompletion!(session, state))
upcompletion!(session, state, menu::Union{Completion.Menu, Completion.FileMenu}) = movecompletion!(session, menu, -1)
downcompletion!(session, state, menu::Union{Completion.Menu, Completion.FileMenu}) = movecompletion!(session, menu, 1)
upcompletion!(session, state, ::Completion.State) = editcompletion!(session, state, TerminalEditor.up!)
downcompletion!(session, state, ::Completion.State) = editcompletion!(session, state, TerminalEditor.down!)
function movecompletion!(session, menu::Union{Completion.Menu, Completion.FileMenu}, offset)
    Completion.move!(menu, offset)
    refreshcompletion!(session, session.view, menu, menu)
    :ok
end

pagecompletion!(session, state, offset) = pagecompletion!(session, state, offset, synccompletion!(session, state))
pagecompletion!(session, state, offset, ::Completion.State) = scroll!(session, offset)
function pagecompletion!(session, state, offset, menu::Union{Completion.Menu, Completion.FileMenu})
    Completion.page!(menu, offset * 5)
    paint!(session)
    :ok
end

escapecompletion!(session, state, ::Completion.State) = abort!(session, state, session.activity)
function escapecompletion!(session, state, menu::Completion.Menu)
    session.completion = Completion.dismiss(menu)
    refreshcompletion!(session, session.view, menu, session.completion)
    :ok
end
function escapecompletion!(session, state, current::Union{Completion.PendingFiles, Completion.FileMenu})
    session.completion = Completion.dismiss(current)
    refreshcompletion!(session, session.view, current, session.completion)
    :ok
end

completionlines(session, width, limit) = completionlines(session, session.completion, width, limit)
completionlines(session, ::Completion.State, width, limit) = String[]
completionlabel(item::Completion.Item) = "/" * item.name
completionlabel(item::Completion.PathItem) = item.label
function completionlines(session, menu::Union{Completion.Menu, Completion.FileMenu}, width, limit)
    count = min(limit, length(menu.items))
    count <= 0 && return String[]
    start = clamp(menu.index - count ÷ 2, 1, length(menu.items) - count + 1)
    lines = String[]
    for index in start:start + count - 1
        item = menu.items[index]
        marker = index == menu.index ? "→ " : "  "
        label = marker * JuliaForever.redact(session.terminal, completionlabel(item)) * "  " * JuliaForever.redact(session.terminal, item.description)
        push!(lines, first(wrap(label, width)))
    end
    lines
end
