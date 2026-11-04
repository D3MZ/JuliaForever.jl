module JuliaForever

using Tachikoma
@tachikoma_app

include("ChatGPTAuth.jl")
include("NativeAgent.jl")
include("CharmStyle.jl")
import .ChatGPTAuth
import .NativeAgent
import .CharmStyle

const AUTH_OPTIONS = ["Sign in with an account", "Sign in with an API key"]
account_options() = ChatGPTAuth.saved_registration() === nothing ?
    ["ChatGPT", "Anthropic", "Google", "Other provider"] :
    ["ChatGPT", "ChatGPT (sign in again)", "Anthropic", "Google", "Other provider"]

list(items) = SelectableList(collect(items); focused=true, highlight_style=CharmStyle.ACTIVE_STYLE, marker='>')

@kwdef mutable struct Menu <: Model
    page::Symbol = :auth
    choices::SelectableList = list(AUTH_OPTIONS)
    picks::Dict{Symbol,Int} = Dict{Symbol,Int}()
    button::Button = CharmStyle.button("Continue")
    focus::Symbol = :content
    notice::String = ""
    flow::Union{Nothing,ChatGPTAuth.Login} = nothing
    catalog::Vector{NamedTuple{(:id, :name, :window),Tuple{String,String,Int}}} = []
    filtered::Vector{Int} = Int[]
    selected_model::Int = 0
    search::TextInput = CharmStyle.text_input()
    prompt::TextInput = CharmStyle.text_input()
    pending::Union{Nothing,Channel{Any}} = nothing
    session::Union{Nothing,NativeAgent.Session} = nothing
    transcript::Vector{String} = String[]
    streaming::String = ""
    tool_run::Int = 0
    scroll::Int = 0
    max_scroll::Int = 0
    chat_area::Rect = Rect()
    busy::Bool = false
    restart::Bool = false
    quit::Bool = false
end

should_quit(menu::Menu) = menu.quit

function set_focus!(menu::Menu, focus::Symbol)
    menu.focus = focus
    active = focus == :content
    menu.button.focused = !active
    menu.choices.focused = active
    menu.search.focused = active
    menu.choices.marker = active ? '>' : ' '
    menu.choices.highlight_style = active ? CharmStyle.ACTIVE_STYLE : CharmStyle.TEXT_STYLE
end

function show_page!(menu::Menu, page::Symbol, options=String[])
    menu.page = page
    menu.notice = ""
    menu.button.label = page == :limited ? "Done" : "Continue"
    menu.button.flash_remaining = 0
    menu.button.last_area = Rect()
    if page in (:auth, :accounts, :models)
        menu.choices = list(options)
        menu.choices.selected = clamp(get(menu.picks, page, 1), 1, max(1, length(options)))
        set_focus!(menu, :content)
    else
        set_focus!(menu, :continue)
    end
end

function refresh_choices!(menu::Menu)
    picked = menu.page == :models ? findfirst(==(menu.selected_model), menu.filtered) : get(menu.picks, menu.page, 0)
    menu.choices.items = [ListItem(item.content, i == picked ? CharmStyle.ACTIVE_STYLE : CharmStyle.TEXT_STYLE;
                                  prefix=i == picked ? "✓ " : "• ",
                                  prefix_style=i == picked ? CharmStyle.ACTIVE_STYLE : CharmStyle.DIM_STYLE)
                          for (i, item) in enumerate(menu.choices.items)]
    if menu.focus != :content
        menu.choices.highlight_style = menu.choices.selected == picked ? CharmStyle.ACTIVE_STYLE : CharmStyle.TEXT_STYLE
    end
end

function select_choice!(menu::Menu)
    if menu.page == :models
        isempty(menu.filtered) && return
        menu.selected_model = menu.filtered[menu.choices.selected]
    else
        menu.picks[menu.page] = menu.choices.selected
    end
    menu.notice = ""
end

function start_models!(menu::Menu)
    events = Channel{Any}(1)
    menu.pending = events
    show_page!(menu, :loading)
    @async begin
        try
            Base.put!(events, (:models, NativeAgent.models()))
        catch error
            message = error isa NativeAgent.ProviderError || error isa ChatGPTAuth.LoginError ?
                      error.message : "Could not load models. Try again."
            Base.put!(events, (:error, message))
        end
    end
end

function filter_models!(menu::Menu)
    query = lowercase(Tachikoma.text(menu.search))
    menu.filtered = [i for (i, model) in enumerate(menu.catalog) if
                     occursin(query, lowercase(model.name)) || occursin(query, lowercase(model.id))]
    menu.choices = list([menu.catalog[i].name for i in menu.filtered])
    set_focus!(menu, menu.focus)
end

function record_tool!(menu::Menu, name::AbstractString)
    if !isempty(menu.transcript) && startswith(menu.transcript[end], "→ ")
        menu.tool_run += 1
        menu.transcript[end] = "→ $(menu.tool_run) tool calls · $name"
    else
        menu.tool_run = 1
        push!(menu.transcript, "→ " * name)
    end
end

function show_chat!(menu::Menu, session::NativeAgent.Session)
    menu.session = session
    empty!(menu.transcript)
    menu.tool_run = 0
    for item in session.input
        role, kind = get(item, "role", ""), get(item, "type", "")
        if role == "user" && get(item, "content", nothing) isa AbstractString
            push!(menu.transcript, "You: " * item["content"])
        elseif role == "assistant"
            for part in get(item, "content", [])
                get(part, "type", "") == "output_text" && push!(menu.transcript, "Agent: " * part["text"])
            end
        elseif kind == "function_call"
            record_tool!(menu, item["name"])
        end
    end
    menu.streaming = ""
    menu.scroll = 0
    menu.max_scroll = 0
    Tachikoma.clear!(menu.prompt)
    menu.pending = Channel{Any}(2048)
    show_page!(menu, :chat)
end

function begin_chat!(menu::Menu)
    model = menu.catalog[menu.selected_model]
    show_chat!(menu, NativeAgent.Session(model.id, model.window, pwd()))
end

function send_prompt!(menu::Menu)
    menu.busy && return
    prompt = String(strip(Tachikoma.text(menu.prompt)))
    isempty(prompt) && return
    Tachikoma.clear!(menu.prompt)
    if prompt == "/restart"
        NativeAgent.remember_session!(menu.session)
        menu.restart = true
        menu.quit = true
        return
    end
    menu.scroll = 0
    push!(menu.transcript, "You: " * prompt)
    menu.streaming = ""
    menu.busy = true
    events, session = menu.pending, menu.session
    @async begin
        try
            NativeAgent.run_turn!(session, prompt, (kind, text) -> Base.put!(events, (kind, text)))
            Base.put!(events, (:done, ""))
        catch error
            message = error isa NativeAgent.ProviderError || error isa ChatGPTAuth.LoginError ?
                      error.message : "Agent error: " * sprint(showerror, error)
            Base.put!(events, (:error, message))
        end
    end
end

function continue_page!(menu::Menu)
    menu.notice = ""
    if menu.page in (:auth, :accounts)
        selected = get(menu.picks, menu.page, 0)
        if selected == 0
            menu.notice = "Select an option to continue."
        elseif menu.page == :auth
            selected == 1 ? show_page!(menu, :accounts, account_options()) :
                            (menu.notice = "API-key sign-in is not available yet.")
        else
            saved = ChatGPTAuth.saved_registration() !== nothing
            if selected == 1 && saved
                start_models!(menu)
            elseif selected == 1 || (saved && selected == 2)
                try
                    menu.flow = ChatGPTAuth.start_login()
                    show_page!(menu, :waiting)
                catch
                    menu.notice = "Could not start ChatGPT sign-in. Please try again."
                end
            else
                menu.notice = "This provider is not available yet."
            end
        end
    elseif menu.page == :connected
        start_models!(menu)
    elseif menu.page == :models
        menu.selected_model == 0 ? (menu.notice = "Select a model to continue.") : begin_chat!(menu)
    elseif menu.page == :limited
        menu.quit = true
    end
end

function go_back!(menu::Menu)
    if menu.page == :auth
        menu.quit = true
    elseif menu.page == :accounts
        show_page!(menu, :auth, AUTH_OPTIONS)
    elseif menu.page == :waiting
        menu.flow === nothing || ChatGPTAuth.cancel!(menu.flow)
        menu.flow = nothing
        show_page!(menu, :accounts, account_options())
    elseif menu.page == :models || menu.page == :loading
        menu.pending = nothing
        show_page!(menu, :accounts, account_options())
    elseif menu.page == :chat
        if menu.busy
            menu.notice = "The agent is working."
        else
            isempty(menu.catalog) ? start_models!(menu) : show_page!(menu, :models, [menu.catalog[i].name for i in menu.filtered])
        end
    else
        menu.quit = true
    end
end

function update!(menu::Menu, event::KeyEvent)
    if event.key == :ctrl_c || (event.key == :ctrl && event.char == 'c')
        menu.quit = true
    elseif event.key == :escape
        if menu.page == :models && !isempty(Tachikoma.text(menu.search))
            Tachikoma.clear!(menu.search)
            filter_models!(menu)
        else
            go_back!(menu)
        end
    elseif menu.page in (:waiting, :loading)
        return
    elseif menu.page == :chat
        if event.key in (:up, :pageup)
            menu.scroll += event.key == :up ? 1 : 10
        elseif event.key in (:down, :pagedown)
            menu.scroll = max(0, menu.scroll - (event.key == :down ? 1 : 10))
        elseif event.key == :enter
            send_prompt!(menu)
        elseif !menu.busy
            handle_key!(menu.prompt, event)
        end
    elseif event.key in (:tab, :backtab) && menu.page in (:auth, :accounts, :models)
        set_focus!(menu, menu.focus == :content ? :continue : :content)
    elseif menu.focus == :continue
        handle_key!(menu.button, event) && continue_page!(menu)
    elseif event.key == :enter || (menu.page != :models && event.key == :char && event.char == ' ')
        select_choice!(menu)
    elseif menu.page == :models && !(event.key in (:up, :down, :home, :end_key, :pageup, :pagedown))
        before = Tachikoma.text(menu.search)
        handle_key!(menu.search, event)
        before == Tachikoma.text(menu.search) || filter_models!(menu)
    else
        handle_key!(menu.choices, event)
    end
end

function update!(menu::Menu, event::MouseEvent)
    if menu.page == :chat
        if Base.contains(menu.chat_area, event.x, event.y) && event.action == mouse_press
            event.button == mouse_scroll_up && (menu.scroll += 3)
            event.button == mouse_scroll_down && (menu.scroll = max(0, menu.scroll - 3))
        end
        return
    end
    menu.page in (:waiting, :loading) && return
    if handle_mouse!(menu.button, event)
        set_focus!(menu, :continue)
        continue_page!(menu)
        return
    end
    click = event.button == mouse_left && event.action == mouse_press
    if menu.page in (:auth, :accounts, :models) && handle_mouse!(menu.choices, event) && click
        set_focus!(menu, :content)
        select_choice!(menu)
    end
end

function position(area::Rect, width::Int, height::Int)
    width = min(width, area.width)
    area.x + max(0, (area.width - width) ÷ 2), area.y + max(0, (area.height - height) ÷ 2), width
end

function put!(buffer::Buffer, area::Rect, x::Int, y::Int, message::AbstractString, style::Style)
    area.y <= y <= bottom(area) || return
    set_string!(buffer, x, y, message, style; max_x=right(area))
end

function choices_view!(menu::Menu, rect::Rect, buffer::Buffer)
    render(menu.choices, rect, buffer)
    row = menu.choices.selected - menu.choices.offset - 1
    if menu.focus == :content && !isempty(menu.choices.items) && 0 <= row < rect.height && rect.width > 0
        set_char!(buffer, rect.x, rect.y + row, '>', CharmStyle.POINTER_STYLE)
    end
end

function button_view!(menu::Menu, frame::Frame, left::Int, top::Int, width::Int)
    menu.button.last_area = Rect()
    frame.area.y <= top <= bottom(frame.area) || return
    put!(frame.buffer, frame.area, left, top, menu.focus == :continue ? "> " : "  ", CharmStyle.POINTER_STYLE)
    button_width = min(textwidth(menu.button.label) + 4, max(0, width - 2))
    render(menu.button, Rect(left + 2, top, button_width, 1), frame.buffer)
end

function choice_view!(menu::Menu, frame::Frame)
    refresh_choices!(menu)
    area, buffer = frame.area, frame.buffer
    title = menu.page == :auth ? "Select authentication method:" : "Select an account:"
    footer = "↑↓ move  enter select  tab focus  enter activate  esc back"
    rows = min(length(menu.choices.items), max(1, area.height - 7))
    width = max(textwidth(title), textwidth(footer), textwidth(menu.notice),
                maximum((textwidth(item.content) + 6 for item in menu.choices.items); init=0))
    left, top, width = position(area, width, rows + 6)
    put!(buffer, area, left, top, title, CharmStyle.TITLE_STYLE)
    menu.choices.offset = clamp(menu.choices.offset, 0, max(0, length(menu.choices.items) - rows))
    choices_view!(menu, Rect(left, top + 2, width, rows), buffer)
    isempty(menu.notice) || put!(buffer, area, left, top + rows + 2, menu.notice, CharmStyle.ERROR_STYLE)
    button_view!(menu, frame, left, top + rows + 4, width)
    put!(buffer, area, left, top + rows + 6, footer, CharmStyle.DIM_STYLE)
end

function poll_login!(menu::Menu)
    flow = menu.flow
    flow === nothing && return
    isready(flow.result) || return
    outcome, message = take!(flow.result)
    menu.flow = nothing
    if outcome == :error
        show_page!(menu, :accounts, account_options())
        menu.notice = message
    else
        show_page!(menu, outcome == :ready ? :connected : :limited)
        menu.notice = message
    end
end

function status_view!(menu::Menu, frame::Frame)
    area, buffer = frame.area, frame.buffer
    if menu.page == :waiting
        menu.button.last_area = Rect()
        spinner = SPINNER_BRAILLE[mod1(floor(Int, time() * 4), length(SPINNER_BRAILLE))]
        lines = ["$(spinner) Continue with ChatGPT in your browser.", "esc cancel"]
        width = maximum(textwidth, lines)
        left, top, _ = position(area, width, 3)
        put!(buffer, area, left, top, lines[1], CharmStyle.TITLE_STYLE)
        put!(buffer, area, left, top + 2, lines[2], CharmStyle.DIM_STYLE)
        return
    end
    title = menu.page == :connected ? "Signed in to ChatGPT." : "ChatGPT sign-in needs attention."
    lines = [menu.notice, "Credentials are stored locally."]
    width = max(textwidth(title), maximum(textwidth, lines), textwidth("enter activate  esc exit"))
    left, top, width = position(area, width, 7)
    put!(buffer, area, left, top, title, CharmStyle.TITLE_STYLE)
    for (i, line) in enumerate(lines)
        put!(buffer, area, left, top + i, line, CharmStyle.DIM_STYLE)
    end
    button_view!(menu, frame, left, top + 5, width)
    put!(buffer, area, left, top + 7, "enter activate  esc exit", CharmStyle.DIM_STYLE)
end

function poll_pending!(menu::Menu)
    events = menu.pending
    events === nothing && return
    while isready(events)
        kind, value = take!(events)
        if menu.page == :loading
            menu.pending = nothing
            if kind == :models
                menu.catalog = value
                menu.filtered = collect(eachindex(menu.catalog))
                menu.selected_model = 0
                Tachikoma.clear!(menu.search)
                show_page!(menu, :models, [model.name for model in menu.catalog])
            else
                show_page!(menu, :accounts, account_options())
                menu.notice = value
            end
            return
        elseif menu.page == :chat
            if kind == :delta
                menu.streaming *= value
            elseif kind == :tool
                isempty(menu.streaming) || push!(menu.transcript, "Agent: " * menu.streaming)
                menu.streaming = ""
                record_tool!(menu, value)
            elseif kind == :rollover
                push!(menu.transcript, value)
            elseif kind == :done || kind == :error
                isempty(menu.streaming) || push!(menu.transcript, "Agent: " * menu.streaming)
                menu.streaming = ""
                kind == :error && push!(menu.transcript, value)
                menu.busy = false
                menu.notice = ""
            end
        end
    end
end

function model_view!(menu::Menu, frame::Frame)
    refresh_choices!(menu)
    area, buffer = frame.area, frame.buffer
    rows = min(10, max(1, length(menu.choices.items)), max(1, area.height - 9))
    width = min(72, area.width)
    left, top, width = position(area, width, rows + 8)
    put!(buffer, area, left, top, "Select a model:", CharmStyle.TITLE_STYLE)
    put!(buffer, area, left, top + 2, "Search:", CharmStyle.POINTER_STYLE)
    render(menu.search, Rect(left + 8, top + 2, max(0, width - 8), 1), buffer)
    choices_view!(menu, Rect(left, top + 3, width, rows), buffer)
    isempty(menu.notice) || put!(buffer, area, left, top + rows + 3, menu.notice, CharmStyle.ERROR_STYLE)
    button_view!(menu, frame, left, top + rows + 5, width)
    put!(buffer, area, left, top + rows + 7, "type to search  ↑↓ move  enter select  tab focus  esc back", CharmStyle.DIM_STYLE)
end

function wrap_text(text::AbstractString, width::Int)
    width < 1 && return String(text)
    lines = String[]
    for line in split(text, '\n'; keepempty=true)
        expanded = IOBuffer()
        column = 0
        for char in Base.Unicode.graphemes(line)
            if char == "\t"
                spaces = 4 - mod(column, 4)
                print(expanded, " "^spaces)
                column += spaces
            else
                print(expanded, char)
                column += textwidth(char)
            end
        end
        chars = collect(Base.Unicode.graphemes(String(take!(expanded))))
        if isempty(chars)
            push!(lines, "")
            continue
        end
        start = 1
        while start <= length(chars)
            stop = start - 1
            last_space = 0
            columns = 0
            for i in start:length(chars)
                next_width = textwidth(chars[i])
                columns + next_width > width && break
                columns += next_width
                stop = i
                chars[i] == " " && (last_space = i)
            end
            stop < start && (stop = start)
            if stop < length(chars) && last_space >= start && any(!=(" "), chars[start:last_space])
                stop = last_space
            end
            push!(lines, join(chars[start:stop]))
            start = stop + 1
        end
    end
    join(lines, '\n')
end

function chat_view!(menu::Menu, frame::Frame)
    area, buffer = frame.area, frame.buffer
    if area.width < 6 || area.height < 6
        menu.chat_area = Rect()
        area.width > 0 && area.height > 0 &&
            put!(buffer, area, area.x, area.y, "Resize terminal", CharmStyle.DIM_STYLE)
        return
    end
    left, top, width, height = area.x, area.y, area.width, area.height
    model = menu.session.model
    put!(buffer, area, left, top, "JuliaForever · " * model, CharmStyle.TITLE_STYLE)
    entries = [menu.transcript; (isempty(menu.streaming) ? String[] : ["Agent: " * menu.streaming])]
    available = height - 6
    paragraph = Paragraph(wrap_text(join(entries, "\n"), width); show_scrollbar=false)
    total = paragraph_line_count(paragraph, width)
    maximum_scroll = max(0, total - available)
    menu.scroll > 0 && (menu.scroll += maximum_scroll - menu.max_scroll)
    menu.scroll = clamp(menu.scroll, 0, maximum_scroll)
    menu.max_scroll = maximum_scroll
    paragraph.scroll_offset = maximum_scroll - menu.scroll
    menu.chat_area = Rect(left, top + 2, width, available)
    render(paragraph, menu.chat_area, buffer)
    prompt_y = top + height - 3
    put!(buffer, area, left, prompt_y, menu.busy ? "…" : "❯", CharmStyle.POINTER_STYLE)
    render(menu.prompt, Rect(left + 2, prompt_y, max(0, width - 2), 1), buffer)
    footer = menu.busy ? "Agent working · ↑↓ scroll · ctrl+c exit" : "enter send  ↑↓ scroll  esc models  /restart"
    isempty(menu.notice) || (footer = menu.notice)
    put!(buffer, area, left, top + height - 1, footer, CharmStyle.DIM_STYLE)
end

function view(menu::Menu, frame::Frame)
    menu.page == :waiting && poll_login!(menu)
    menu.page in (:loading, :chat) && poll_pending!(menu)
    if menu.page in (:auth, :accounts)
        choice_view!(menu, frame)
    elseif menu.page == :models
        model_view!(menu, frame)
    elseif menu.page == :chat
        chat_view!(menu, frame)
    elseif menu.page == :loading
        left, top, width = position(frame.area, 36, 3)
        put!(frame.buffer, frame.area, left, top, "Loading models…", CharmStyle.TITLE_STYLE)
        if frame.area.y <= top + 2 <= bottom(frame.area)
            render(CharmStyle.Progress(nothing), Rect(left, top + 2, width, 1), frame.buffer)
        end
    else
        status_view!(menu, frame)
    end
end

function main()
    menu = Menu()
    previous = NativeAgent.restore_session()
    previous === nothing || show_chat!(menu, previous)
    try
        app(menu; fps=10, default_bindings=false)
    finally
        menu.flow === nothing || ChatGPTAuth.cancel!(menu.flow)
    end
    if menu.restart
        project = dirname(@__DIR__)
        run(`$(Base.julia_cmd()) --project=$project $(joinpath(project, "run.jl"))`)
    end
end

end
