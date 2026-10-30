const Menus = TerminalEditor.REPL.TerminalMenus

abstract type MenuAction end
struct MenuUp <: MenuAction end
struct MenuDown <: MenuAction end
struct MenuPageUp <: MenuAction end
struct MenuPageDown <: MenuAction end
struct MenuFirst <: MenuAction end
struct MenuLast <: MenuAction end
struct MenuAccept <: MenuAction end
struct MenuCancel <: MenuAction end
struct MenuBackspace <: MenuAction end
struct MenuCharacter <: MenuAction
    char::Char
end
const menuactions = Dict{UInt32, MenuAction}(
    UInt32(Menus.ARROW_UP) => MenuUp(), UInt32(Menus.ARROW_DOWN) => MenuDown(),
    UInt32(Menus.PAGE_UP) => MenuPageUp(), UInt32(Menus.PAGE_DOWN) => MenuPageDown(),
    UInt32(Menus.HOME_KEY) => MenuFirst(), UInt32(Menus.END_KEY) => MenuLast(),
    UInt32(13) => MenuAccept(), UInt32(27) => MenuCancel(), UInt32(3) => MenuCancel(),
    UInt32(8) => MenuBackspace(), UInt32(127) => MenuBackspace(),
)
menuaction(key::UInt32) = get(menuactions, key, MenuCharacter(Char(key)))

mutable struct Menu
    title::String
    labels::Vector{String}
    query::String
    matches::Vector{Int}
    index::Int
end
Menu(title, labels) = Menu(title, labels, "", collect(eachindex(labels)), 1)

function filtermenu!(menu::Menu)
    query = lowercase(menu.query)
    menu.matches = filter(index -> occursin(query, lowercase(menu.labels[index])), eachindex(menu.labels))
    menu.index = 1
    nothing
end

choose!(menu::Menu, ::MenuUp, page) = (menu.index = max(1, menu.index - 1); nothing)
choose!(menu::Menu, ::MenuDown, page) = (menu.index = min(max(1, length(menu.matches)), menu.index + 1); nothing)
choose!(menu::Menu, ::MenuPageUp, page) = (menu.index = max(1, menu.index - page); nothing)
choose!(menu::Menu, ::MenuPageDown, page) = (menu.index = min(max(1, length(menu.matches)), menu.index + page); nothing)
choose!(menu::Menu, ::MenuFirst, page) = (menu.index = 1; nothing)
choose!(menu::Menu, ::MenuLast, page) = (menu.index = max(1, length(menu.matches)); nothing)
choose!(menu::Menu, ::MenuCancel, page) = 0
choose!(menu::Menu, ::MenuAccept, page) = isempty(menu.matches) ? nothing : menu.matches[menu.index]
function choose!(menu::Menu, ::MenuBackspace, page)
    menu.query = chop(menu.query; tail=1)
    filtermenu!(menu)
end
function choose!(menu::Menu, action::MenuCharacter, page)
    isprint(action.char) || return nothing
    menu.query *= action.char
    filtermenu!(menu)
end

function drawmenu!(session, menu::Menu)
    rows, cols = displaysize(session.physical)
    width = max(1, cols - 1)
    page = max(1, rows - 4)
    firstitem = max(1, menu.index - page + 1)
    lastitem = min(length(menu.matches), firstitem + page - 1)
    out = IOBuffer()
    print(out, "\e[?25l\e[H\e[2J", first(wrap(menu.title, width)), "\nSearch: ", first(wrap(menu.query, max(1, width - 8))), "\n")
    for index in firstitem:lastitem
        marker = index == menu.index ? "> " : "  "
        print(out, marker, first(wrap(menu.labels[menu.matches[index]], max(1, width - 2))), "\n")
    end
    print(out, "\e[", rows, ";1H", first(wrap("↑/↓ select · Enter open · Esc cancel", width)), "\e[?25h")
    write(session.physical, take!(out))
    flush(session.physical)
    page
end

function menu!(session, title, labels::Vector{String})
    isempty(labels) && return 0
    menu = Menu(title, labels)
    terminal = Terminals.TTYTerminal(get(ENV, "TERM", "dumb"), session.editor.terminal.in_stream, session.physical, session.physical)
    Terminals.raw!(terminal, true)
    try
        while true
            page = drawmenu!(session, menu)
            key = Menus.readkey(terminal.in_stream)
            selected = choose!(menu, menuaction(key), page)
            selected === nothing || return selected
        end
    finally
        Terminals.raw!(terminal, false)
    end
end

uicommand!(session, ::Regular, command, terminal, history, input, directory, snapshot, draft) = JuliaForever.command!(command, terminal, session.agent, history, input, directory, snapshot, draft, session.templates)
uicommand!(session, ::Fullscreen, command, terminal, history, input, directory, snapshot, draft) = JuliaForever.command!(command, session.terminal, session.agent, history, input, directory, snapshot, draft, session.templates)

function modeloptions(session, provider)
    name = JuliaForever.modelcatalogname(provider, session.view.provider)
    sort!(JuliaForever.Models.pool(JuliaForever.modelcatalog(provider), name); by=model -> JuliaForever.Models.collation(model.id))
end

modelargument(session, text) = modelargument(text, modelchoices!(session))
modelargument(text, models::Vector{JuliaForever.Models.Model}) = modelargument(text, models, findfirst(model -> Completion.modelvalue(model) == text, models))
modelargument(text, models, ::Nothing) = text
modelargument(text, models, index::Int) = models[index].id

function uicommand!(session, ::Regular, command::JuliaForever.SetModel, terminal, history, input, directory, snapshot, draft)
    JuliaForever.setmodel!(terminal, session.agent, history, modelargument(session, command.model))
end
function uicommand!(session, ::Fullscreen, command::JuliaForever.SetModel, terminal, history, input, directory, snapshot, draft)
    JuliaForever.setmodel!(session.terminal, session.agent, history, modelargument(session, command.model))
end

function uicommand!(session, ::Fullscreen, ::JuliaForever.SelectModel, terminal, history, input, directory, snapshot, draft)
    current = modelname(session.agent.provider)
    models = modeloptions(session, session.agent.provider)
    labels = ["Current: " * current, "Enter a model ID…"]
    append!(labels, (model.id * "  " * model.name for model in models))
    index = menu!(session, "Select model", labels)
    index <= 1 && return session.agent, history, 0
    index > 2 && return JuliaForever.setmodel!(session.terminal, session.agent, history, models[index - 2].id)
    print(session.physical, "\e[H\e[2JModel ID (empty cancels): ")
    flush(session.physical)
    eof(input) && return session.agent, history, 0
    model = strip(readline(input))
    JuliaForever.setmodel!(session.terminal, session.agent, history, model)
end

function uicommand!(session, ::Fullscreen, ::JuliaForever.ResumeCommand, terminal, history, input, directory, snapshot, draft)
    blocked = JuliaForever.sourcecheck!(session.terminal, session.agent, history)
    resumemenu!(session, history, directory, blocked)
end
resumemenu!(session, history, directory, blocked::Union{JuliaForever.PendingInputs, JuliaForever.History.Rejected}) = (session.agent, history, JuliaForever.sourcestatus!(session.terminal, blocked))
resumemenu!(session, history, directory, ::Nothing) = resumemenu!(session, history, JuliaForever.attempt(() -> JuliaForever.SessionCatalog.list(directory, pwd())))
resumemenu!(session, history, failure::JuliaForever.ToolFailure) = JuliaForever.resume!(session.terminal, session.agent, history, failure)
function resumemenu!(session, history, items::Vector{JuliaForever.SessionCatalog.Info})
    if isempty(items)
        println(session.terminal.diagnostics, "No sessions for this project.")
        return session.agent, history, 0
    end
    labels = [JuliaForever.TreeTerminal.clean(JuliaForever.redact(session.terminal, item.title)) * "  " * item.id for item in items]
    selected = menu!(session, "Resume session", labels)
    iszero(selected) && return session.agent, history, 0
    chosen = JuliaForever.attempt(() -> JuliaForever.SessionCatalog.openinfo(items[selected]))
    JuliaForever.resume!(session.terminal, session.agent, history, chosen, session.templates)
end

function uicommand!(session, ::Fullscreen, command::Union{JuliaForever.TreeCommand, JuliaForever.ForkCommand}, terminal, history, input, directory, snapshot, draft)
    blocked = JuliaForever.sourcecheck!(session.terminal, session.agent, history)
    treemenu!(session, command, history, input, directory, snapshot, draft, blocked)
end
treemenu!(session, command, history, input, directory, snapshot, draft, blocked::Union{JuliaForever.PendingInputs, JuliaForever.History.Rejected}) = (session.agent, history, JuliaForever.sourcestatus!(session.terminal, blocked))
treemenu!(session, command, history, input, directory, snapshot, draft, ::Nothing) = treemenu!(session, command, history, input, directory, snapshot, draft, JuliaForever.attempt(() -> JuliaForever.sessiontree(history)))
treemenu!(session, command, history, input, directory, snapshot, draft, failure::JuliaForever.ToolFailure) = JuliaForever.resume!(session.terminal, session.agent, history, failure)
treemenu!(session, command, history, input, directory, snapshot, draft, rejected::JuliaForever.History.Rejected) = (session.agent, history, JuliaForever.result!(session.terminal, rejected))
treemenu!(session, command, history, input, directory, snapshot, draft, tree::JuliaForever.History.Tree) = treeitems!(session, command, history, input, directory, snapshot, draft, tree, JuliaForever.attempt(() -> JuliaForever.History.branches(tree)))
treeitems!(session, command, history, input, directory, snapshot, draft, tree, failure::JuliaForever.ToolFailure) = JuliaForever.resume!(session.terminal, session.agent, history, failure)
treeitems!(session, command, history, input, directory, snapshot, draft, tree, rejected::JuliaForever.History.Rejected) = (session.agent, history, JuliaForever.result!(session.terminal, rejected))

function treeitems!(session, ::JuliaForever.TreeCommand, history, input, directory, snapshot, draft, tree, branches::Vector)
    items = JuliaForever.TreeTerminal.choices(branches)
    isempty(items) && println(session.terminal.diagnostics, "No session messages.")
    labels = [repeat("  ", max(item.depth - 1, 0)) * JuliaForever.TreeTerminal.label(item) * ": " * JuliaForever.TreeTerminal.clean(JuliaForever.redact(session.terminal, item.text)) for item in items]
    selected = menu!(session, "Session tree", labels)
    iszero(selected) && return session.agent, history, 0
    choice = JuliaForever.TreeTerminal.select(items[selected], input, session.physical, text -> JuliaForever.redact(session.terminal, text))
    JuliaForever.tree!(session.terminal, session.agent, tree, choice, snapshot)
end

function treeitems!(session, ::JuliaForever.ForkCommand, history, input, directory, snapshot, draft, tree, branches::Vector)
    items = JuliaForever.TreeTerminal.ForkChoice[]
    for item in branches
        JuliaForever.TreeTerminal.forkitem!(items, item, JuliaForever.History.treeevent(item.batch), branches)
    end
    isempty(items) && println(session.terminal.diagnostics, "No messages to fork from.")
    labels = String[JuliaForever.TreeTerminal.forklabel(item, text -> JuliaForever.redact(session.terminal, text)) for item in items]
    selected = menu!(session, "Fork session", labels)
    iszero(selected) && return session.agent, history, 0
    forkchoice!(session, history, directory, draft, tree, items[selected])
end
forkchoice!(session, history, directory, draft, tree, choice::JuliaForever.TreeTerminal.InputFork) = JuliaForever.fork!(session.terminal, session.agent, history, directory, draft, tree, choice)
forkchoice!(session, history, directory, draft, tree, choice::JuliaForever.TreeTerminal.ImageFork) = JuliaForever.fork!(session.terminal, session.agent, history, directory, draft, tree, choice)
forkchoice!(session, history, directory, draft, tree, choice::JuliaForever.TreeTerminal.QueuedFork) = JuliaForever.fork!(session.terminal, session.agent, history, directory, draft, choice, JuliaForever.attempt(() -> JuliaForever.SessionCatalog.queuedpath(tree, choice.node)))
