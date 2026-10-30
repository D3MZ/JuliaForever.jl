function synccompletion!(session, state)
    buffer = LineEdit.buffer(state)
    before = String(copy(buffer.data[1:position(buffer)]))
    session.completion = Completion.update(session.completion, Completion.prefix(before), session.templates)
end

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
tabcompletion!(session, state, ::Completion.Closed) = :ok
function tabcompletion!(session, state, dismissed::Completion.Dismissed)
    session.completion = Completion.open(dismissed.prefix, session.templates)
    refreshcompletion!(session, session.view, dismissed, session.completion)
    :ok
end
tabcompletion!(session, state, menu::Completion.Menu) = (applycompletion!(session, state, menu); :ok)

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

upcompletion!(session, state) = upcompletion!(session, state, synccompletion!(session, state))
downcompletion!(session, state) = downcompletion!(session, state, synccompletion!(session, state))
upcompletion!(session, state, menu::Completion.Menu) = movecompletion!(session, menu, -1)
downcompletion!(session, state, menu::Completion.Menu) = movecompletion!(session, menu, 1)
upcompletion!(session, state, ::Completion.State) = editcompletion!(session, state, TerminalEditor.up!)
downcompletion!(session, state, ::Completion.State) = editcompletion!(session, state, TerminalEditor.down!)
function movecompletion!(session, menu::Completion.Menu, offset)
    Completion.move!(menu, offset)
    refreshcompletion!(session, session.view, menu, menu)
    :ok
end

pagecompletion!(session, state, offset) = pagecompletion!(session, state, offset, synccompletion!(session, state))
pagecompletion!(session, state, offset, ::Completion.State) = scroll!(session, offset)
function pagecompletion!(session, state, offset, menu::Completion.Menu)
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

completionlines(session, width, limit) = completionlines(session, session.completion, width, limit)
completionlines(session, ::Completion.State, width, limit) = String[]
function completionlines(session, menu::Completion.Menu, width, limit)
    count = min(limit, length(menu.items))
    count <= 0 && return String[]
    start = clamp(menu.index - count ÷ 2, 1, length(menu.items) - count + 1)
    lines = String[]
    for index in start:start + count - 1
        item = menu.items[index]
        marker = index == menu.index ? "→ " : "  "
        label = marker * "/" * JuliaForever.redact(session.terminal, item.name) * "  " * JuliaForever.redact(session.terminal, item.description)
        push!(lines, first(wrap(label, width)))
    end
    lines
end
