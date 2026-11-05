module JuliaForever

using Tachikoma
using JSON
@tachikoma_app

include("Settings.jl")
include("ChatGPTAuth.jl")
include("HotReload.jl")
include("NativeAgent.jl")
include("BuildCore.jl")
include("CharmStyle.jl")
include("Editor.jl")
import .Settings
import .ChatGPTAuth
import .NativeAgent
import .BuildCore
import .CharmStyle

auth_options() = ["Sign in with an account", "Sign in with an API key"]
account_options() = ChatGPTAuth.saved_registration() === nothing ?
    ["ChatGPT", "Anthropic", "Google", "Other provider"] :
    ["ChatGPT", "ChatGPT (sign in again)", "Anthropic", "Google", "Other provider"]

list(items) = SelectableList(collect(items); focused=true, highlight_style=CharmStyle.THEME.active, marker='>')

@kwdef mutable struct ChatEntry
    kind::Symbol
    text::String = ""
    call_id::String = ""
    name::String = ""
    arguments::String = ""
    output::Union{Nothing,String} = nothing
    status::Symbol = :done
end

struct ChatLine
    spans::Vector{Span}
    surface::Symbol
    inset::Int
end

@kwdef mutable struct ChatLayout
    width::Int = 0
    lines::Vector{ChatLine} = ChatLine[]
    ends::Vector{Int} = Int[]
    streaming::String = ""
    streaming_lines::Vector{ChatLine} = ChatLine[]
    streaming_separator::Bool = false
    stream_task::Union{Nothing,Task} = nothing
end

@kwdef mutable struct Menu <: Model
    page::Symbol = :auth
    choices::SelectableList = list(auth_options())
    picks::Dict{Symbol,Int} = Dict{Symbol,Int}()
    button::Button = CharmStyle.button("Continue")
    focus::Symbol = :content
    notice::String = ""
    flow::Union{Nothing,ChatGPTAuth.Login} = nothing
    catalog::Vector{NativeAgent.ModelInfo} = NativeAgent.ModelInfo[]
    filtered::Vector{Int} = Int[]
    selected_model::Int = 0
    styled_pick::Int = -1
    search::TextInput = CharmStyle.text_input()
    feature_search::TextInput = CharmStyle.text_input()
    harness_name::TextInput = CharmStyle.text_input()
    prompt::TextInput = CharmStyle.text_input()
    search_editor::EditorState = EditorState()
    feature_editor::EditorState = EditorState()
    name_editor::EditorState = EditorState()
    prompt_editor::EditorState = EditorState()
    builder::Union{Nothing,BuildCore.BuildSession} = nothing
    feature_filtered::Vector{Int} = collect(eachindex(BuildCore.RECIPES))
    feature_signature::String = ""
    pending::Union{Nothing,Channel{Any}} = nothing
    session::Union{Nothing,NativeAgent.Session} = nothing
    transcript::Vector{ChatEntry} = ChatEntry[]
    tool_indices::Dict{String,Int} = Dict{String,Int}()
    layout::ChatLayout = ChatLayout()
    streaming::String = ""
    expanded_tools::Bool = false
    scroll::Int = 0
    max_scroll::Int = 0
    chat_area::Rect = Rect()
    busy::Bool = false
    control::Union{Nothing,NativeAgent.TurnControl} = nothing
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
    menu.feature_search.focused = active
    menu.harness_name.focused = active
    menu.choices.marker = active ? '>' : ' '
    menu.choices.highlight_style = active ? CharmStyle.THEME.active : CharmStyle.THEME.text
end

function show_page!(menu::Menu, page::Symbol, options=String[])
    menu.page = page
    menu.notice = ""
    menu.button.label = page == :limited ? "Done" : "Continue"
    menu.button.flash_remaining = 0
    menu.button.last_area = Rect()
    if page in (:auth, :accounts, :models, :features, :name)
        menu.choices = list(options)
        menu.styled_pick = -1
        menu.choices.selected = clamp(get(menu.picks, page, 1), 1, max(1, length(options)))
        set_focus!(menu, :content)
    else
        set_focus!(menu, :continue)
    end
end

function refresh_choices!(menu::Menu)
    picked = menu.page == :models ? something(findfirst(==(menu.selected_model), menu.filtered), 0) : get(menu.picks, menu.page, 0)
    if menu.styled_pick != picked
        menu.choices.items = [ListItem(item.content, i == picked ? CharmStyle.THEME.active : CharmStyle.THEME.text;
                                      prefix=i == picked ? "✓ " : "• ",
                                      prefix_style=i == picked ? CharmStyle.THEME.active : CharmStyle.THEME.dim)
                              for (i, item) in enumerate(menu.choices.items)]
        menu.styled_pick = picked
    end
    if menu.focus != :content
        menu.choices.highlight_style = menu.choices.selected == picked ? CharmStyle.THEME.active : CharmStyle.THEME.text
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
    Threads.@spawn begin
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
    menu.styled_pick = -1
    set_focus!(menu, menu.focus)
end

function record_tool!(menu::Menu, call)
    id = string(get(call, "call_id", ""))
    push!(menu.transcript, ChatEntry(kind=:tool, call_id=id, name=string(get(call, "name", "tool")),
                                    arguments=string(get(call, "arguments", "")), status=:running))
    isempty(id) || (menu.tool_indices[id] = length(menu.transcript))
end

function record_tool_result!(menu::Menu, result)
    index = get(menu.tool_indices, string(get(result, "call_id", "")), 0)
    index == 0 && return
    entry = menu.transcript[index]
    entry.output = string(get(result, "output", ""))
    exit_status = match(r"\nExit status: (-?\d+)\s*$", entry.output)
    failed = startswith(entry.output, "Error: ") || startswith(entry.output, "Tool execution was interrupted") ||
             (exit_status !== nothing && exit_status.captures[1] != "0")
    entry.status = failed ? :error : startswith(entry.output, "Skipped because the user steered") ? :skipped : :done
    invalidate_chat!(menu, index)
end

function show_chat!(menu::Menu, session::NativeAgent.Session)
    menu.session = session
    empty!(menu.transcript)
    empty!(menu.tool_indices)
    invalidate_chat!(menu)
    for item in session.input
        role, kind = get(item, "role", ""), get(item, "type", "")
        if role == "user" && get(item, "content", nothing) isa AbstractString
            push!(menu.transcript, ChatEntry(kind=:user, text=item["content"]))
        elseif role == "assistant"
            for part in get(item, "content", [])
                get(part, "type", "") == "output_text" && push!(menu.transcript, ChatEntry(kind=:agent, text=part["text"]))
            end
        elseif kind == "function_call"
            record_tool!(menu, item)
        elseif kind == "function_call_output"
            record_tool_result!(menu, item)
        end
    end
    menu.streaming = ""
    menu.scroll = 0
    menu.max_scroll = 0
    Tachikoma.clear!(menu.prompt)
    reset_editor!(menu.prompt_editor)
    menu.pending = Channel{Any}(2048)
    show_page!(menu, :chat)
end

function show_features!(menu::Menu)
    model = menu.catalog[menu.selected_model]
    if menu.builder === nothing || menu.builder.model != model.id
        old = menu.builder
        old === nothing || Threads.@spawn BuildCore.cleanup!(old)
        menu.builder = BuildCore.BuildSession(model.id, model.window)
        Tachikoma.clear!(menu.feature_search)
        reset_editor!(menu.feature_editor)
        menu.feature_filtered = collect(eachindex(BuildCore.RECIPES))
    end
    menu.feature_signature = ""
    show_page!(menu, :features, [BuildCore.RECIPES[i].name for i in menu.feature_filtered])
end

function filter_features!(menu::Menu)
    words = split(lowercase(strip(Tachikoma.text(menu.feature_search))))
    menu.feature_filtered = [i for (i, recipe) in enumerate(BuildCore.RECIPES) if
                             all(word -> occursin(word, lowercase(recipe.name * " " * recipe.description)), words)]
    menu.choices = list([BuildCore.RECIPES[i].name for i in menu.feature_filtered])
    menu.feature_signature = ""
    set_focus!(menu, menu.focus)
end

function toggle_feature!(menu::Menu)
    isempty(menu.feature_filtered) && return
    recipe = BuildCore.RECIPES[menu.feature_filtered[menu.choices.selected]]
    state = BuildCore.snapshot(menu.builder)
    if haskey(state.jobs, recipe.id)
        BuildCore.remove_feature!(menu.builder, recipe.id)
    else
        BuildCore.start_feature!(menu.builder, recipe.id)
    end
    menu.feature_signature = ""
    menu.notice = ""
end

function open_built_harness!(menu::Menu, install_dir::String)
    events, builder = Channel{Any}(1), menu.builder
    menu.pending = events
    show_page!(menu, :opening)
    Threads.@spawn begin
        try
            HotReload.stop!()
            ENV["JULIAFOREVER_PROFILE"] = install_dir
            HotReload.start!(@__MODULE__, joinpath(install_dir, "features"))
            Base.put!(events, (:opened, (builder.model, builder.window)))
        catch error
            Base.put!(events, (:error, "Could not open the harness: " * sprint(showerror, error)))
        end
    end
end

function send_prompt!(menu::Menu)
    menu.busy && return
    prompt = String(strip(Tachikoma.text(menu.prompt)))
    isempty(prompt) && return
    Tachikoma.clear!(menu.prompt)
    reset_editor!(menu.prompt_editor)
    if prompt == "/restart"
        NativeAgent.remember_session!(menu.session)
        menu.restart = true
        menu.quit = true
        return
    end
    menu.scroll = 0
    push!(menu.transcript, ChatEntry(kind=:user, text=prompt))
    menu.streaming = ""
    menu.busy = true
    menu.notice = ""
    events, session = menu.pending, menu.session
    control = NativeAgent.TurnControl()
    menu.control = control
    Threads.@spawn begin
        try
            NativeAgent.run_turn!(session, prompt, (kind, text) -> Base.put!(events, (kind, text)); control=control)
            Base.put!(events, (:done, ""))
        catch error
            message = error isa NativeAgent.ProviderError || error isa ChatGPTAuth.LoginError ?
                      error.message : "Agent error: " * sprint(showerror, error)
            Base.put!(events, (:error, message))
        end
    end
end

function queue_prompt!(menu::Menu, mode::Symbol)
    menu.busy || return false
    control = menu.control
    control === nothing && return false
    prompt = String(strip(Tachikoma.text(menu.prompt)))
    isempty(prompt) && return true
    if !NativeAgent.enqueue!(control, prompt, mode)
        menu.notice = "The agent is finishing; send again in a moment."
        return true
    end
    Tachikoma.clear!(menu.prompt)
    reset_editor!(menu.prompt_editor)
    push!(menu.transcript, ChatEntry(kind=:user, text=prompt))
    invalidate_chat!(menu)
    menu.scroll = 0
    menu.notice = mode == :steer ? "Steering after the current operation." : "Follow-up queued."
    true
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
        menu.selected_model == 0 ? (menu.notice = "Select a model to continue.") : show_features!(menu)
    elseif menu.page == :features
        show_page!(menu, :name)
    elseif menu.page == :name
        name = String(strip(Tachikoma.text(menu.harness_name)))
        try
            BuildCore.validate_name(name)
            BuildCore.start_finalize!(menu.builder, name)
            show_page!(menu, :building)
        catch error
            menu.notice = sprint(showerror, error)
        end
    elseif menu.page == :limited
        menu.quit = true
    end
end

function go_back!(menu::Menu)
    if menu.page == :auth
        menu.quit = true
    elseif menu.page == :accounts
        show_page!(menu, :auth, auth_options())
    elseif menu.page == :waiting
        menu.flow === nothing || ChatGPTAuth.cancel!(menu.flow)
        menu.flow = nothing
        show_page!(menu, :accounts, account_options())
    elseif menu.page == :models || menu.page == :loading
        menu.pending = nothing
        show_page!(menu, :accounts, account_options())
    elseif menu.page == :features
        show_page!(menu, :models, [menu.catalog[i].name for i in menu.filtered])
    elseif menu.page == :name
        show_features!(menu)
    elseif menu.page == :building
        BuildCore.cancel_finalize!(menu.builder)
        show_page!(menu, :name)
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
    menu.page == :chat && HotReload.on_key!(menu, event) && return
    command = menu.page == :chat || (menu.page in (:models, :features, :name) && menu.focus == :content) ? editor_command(event) : nothing
    if command === :ignore
        return
    elseif event.key == :ctrl_c || (event.key == :ctrl && event.char == 'c')
        menu.quit = true
    elseif event.key == :escape && command === nothing
        if menu.page == :models && !isempty(Tachikoma.text(menu.search))
            Tachikoma.clear!(menu.search)
            reset_editor!(menu.search_editor)
            filter_models!(menu)
        elseif menu.page == :features && !isempty(Tachikoma.text(menu.feature_search))
            Tachikoma.clear!(menu.feature_search)
            reset_editor!(menu.feature_editor)
            filter_features!(menu)
        else
            go_back!(menu)
        end
    elseif menu.page in (:waiting, :loading, :opening, :building)
        return
    elseif menu.page == :chat
        if event.key == :ctrl && event.char == 'o'
            menu.expanded_tools = !menu.expanded_tools
            invalidate_chat!(menu)
        elseif command === :scroll_top
            menu.scroll = menu.max_scroll
        elseif command === :scroll_bottom
            menu.scroll = 0
        elseif command !== nothing
            edit_input!(menu.prompt, menu.prompt_editor, event, command)
        elseif event.key in (:up, :pageup)
            menu.scroll += event.key == :up ? 1 : max(1, menu.chat_area.height - 1)
        elseif event.key in (:down, :pagedown)
            menu.scroll = max(0, menu.scroll - (event.key == :down ? 1 : max(1, menu.chat_area.height - 1)))
        elseif event.key == :enter
            send_prompt!(menu)
        else
            edit_input!(menu.prompt, menu.prompt_editor, event, command)
        end
    elseif event.key in (:tab, :backtab) && menu.page in (:auth, :accounts, :models, :features, :name)
        set_focus!(menu, menu.focus == :content ? :continue : :content)
    elseif menu.focus == :continue
        handle_key!(menu.button, event) && continue_page!(menu)
    elseif menu.page == :models && command !== nothing && !(command in (:scroll_top, :scroll_bottom))
        before = Tachikoma.text(menu.search)
        edit_input!(menu.search, menu.search_editor, event, command)
        before == Tachikoma.text(menu.search) || filter_models!(menu)
    elseif menu.page == :name
        event.key == :enter || edit_input!(menu.harness_name, menu.name_editor, event, command)
    elseif menu.page == :features && command !== nothing && !(command in (:scroll_top, :scroll_bottom))
        before = Tachikoma.text(menu.feature_search)
        edit_input!(menu.feature_search, menu.feature_editor, event, command)
        before == Tachikoma.text(menu.feature_search) || filter_features!(menu)
    elseif menu.page == :features && event.key == :enter
        toggle_feature!(menu)
    elseif menu.page == :features && !(event.key in (:up, :down, :home, :end_key, :pageup, :pagedown))
        before = Tachikoma.text(menu.feature_search)
        edit_input!(menu.feature_search, menu.feature_editor, event, command)
        before == Tachikoma.text(menu.feature_search) || filter_features!(menu)
    elseif event.key == :enter || (menu.page != :models && event.key == :char && event.char == ' ')
        select_choice!(menu)
    elseif menu.page == :models && !(event.key in (:up, :down, :home, :end_key, :pageup, :pagedown))
        before = Tachikoma.text(menu.search)
        edit_input!(menu.search, menu.search_editor, event, command)
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
    menu.page in (:waiting, :loading, :opening, :building) && return
    if handle_mouse!(menu.button, event)
        set_focus!(menu, :continue)
        continue_page!(menu)
        return
    end
    click = event.button == mouse_left && event.action == mouse_press
    if menu.page in (:auth, :accounts, :models, :features) && handle_mouse!(menu.choices, event) && click
        set_focus!(menu, :content)
        menu.page == :features ? toggle_feature!(menu) : select_choice!(menu)
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
        set_char!(buffer, rect.x, rect.y + row, '>', CharmStyle.THEME.pointer)
    end
end

function button_view!(menu::Menu, frame::Frame, left::Int, top::Int, width::Int)
    menu.button.last_area = Rect()
    frame.area.y <= top <= bottom(frame.area) || return
    put!(frame.buffer, frame.area, left, top, menu.focus == :continue ? "> " : "  ", CharmStyle.THEME.pointer)
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
    put!(buffer, area, left, top, title, CharmStyle.THEME.title)
    menu.choices.offset = clamp(menu.choices.offset, 0, max(0, length(menu.choices.items) - rows))
    choices_view!(menu, Rect(left, top + 2, width, rows), buffer)
    isempty(menu.notice) || put!(buffer, area, left, top + rows + 2, menu.notice, CharmStyle.THEME.error)
    button_view!(menu, frame, left, top + rows + 4, width)
    put!(buffer, area, left, top + rows + 6, footer, CharmStyle.THEME.dim)
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
        put!(buffer, area, left, top, lines[1], CharmStyle.THEME.title)
        put!(buffer, area, left, top + 2, lines[2], CharmStyle.THEME.dim)
        return
    end
    title = menu.page == :connected ? "Signed in to ChatGPT." : "ChatGPT sign-in needs attention."
    lines = [menu.notice, "Credentials are stored locally."]
    width = max(textwidth(title), maximum(textwidth, lines), textwidth("enter activate  esc exit"))
    left, top, width = position(area, width, 7)
    put!(buffer, area, left, top, title, CharmStyle.THEME.title)
    for (i, line) in enumerate(lines)
        put!(buffer, area, left, top + i, line, CharmStyle.THEME.dim)
    end
    button_view!(menu, frame, left, top + 5, width)
    put!(buffer, area, left, top + 7, "enter activate  esc exit", CharmStyle.THEME.dim)
end

function poll_pending!(menu::Menu)
    events = menu.pending
    (events === nothing || !isready(events)) && return
    deltas = IOBuffer()
    for _ in 1:256
        isready(events) || break
        kind, value = take!(events)
        if menu.page == :opening
            menu.pending = nothing
            if kind == :opened
                model, window = value
                builder = menu.builder
                menu.builder = nothing
                builder === nothing || Threads.@spawn BuildCore.cleanup!(builder)
                show_chat!(menu, NativeAgent.Session(model, window, pwd()))
                menu.notice = "Harness installed and ready."
            else
                show_page!(menu, :name)
                menu.notice = value
            end
            return
        elseif menu.page == :loading
            menu.pending = nothing
            if kind == :models
                menu.catalog = value
                menu.filtered = collect(eachindex(menu.catalog))
                menu.selected_model = 0
                Tachikoma.clear!(menu.search)
                reset_editor!(menu.search_editor)
                show_page!(menu, :models, [model.name for model in menu.catalog])
            else
                show_page!(menu, :accounts, account_options())
                menu.notice = value
            end
            return
        elseif menu.page == :chat
            if kind == :delta
                print(deltas, value)
                continue
            end
            menu.streaming *= String(take!(deltas))
            if kind == :tool
                isempty(menu.streaming) || push!(menu.transcript, ChatEntry(kind=:agent, text=menu.streaming))
                menu.streaming = ""
                record_tool!(menu, value)
            elseif kind == :tool_result
                record_tool_result!(menu, value)
            elseif kind == :rollover
                push!(menu.transcript, ChatEntry(kind=:notice, text=value))
            elseif kind == :boundary
                isempty(menu.streaming) || push!(menu.transcript, ChatEntry(kind=:agent, text=menu.streaming))
                menu.streaming = ""
            elseif kind == :done || kind == :error
                isempty(menu.streaming) || push!(menu.transcript, ChatEntry(kind=:agent, text=menu.streaming))
                menu.streaming = ""
                kind == :error && push!(menu.transcript, ChatEntry(kind=:error, text=value))
                menu.busy = false
                menu.notice = ""
            end
        end
    end
    menu.streaming *= String(take!(deltas))
end

function model_view!(menu::Menu, frame::Frame)
    refresh_choices!(menu)
    area, buffer = frame.area, frame.buffer
    rows = min(10, max(1, length(menu.choices.items)), max(1, area.height - 9))
    width = min(72, area.width)
    left, top, width = position(area, width, rows + 8)
    put!(buffer, area, left, top, "Select a model:", CharmStyle.THEME.title)
    put!(buffer, area, left, top + 2, "Search:", CharmStyle.THEME.pointer)
    render(menu.search, Rect(left + 8, top + 2, max(0, width - 8), 1), buffer)
    choices_view!(menu, Rect(left, top + 3, width, rows), buffer)
    isempty(menu.notice) || put!(buffer, area, left, top + rows + 3, menu.notice, CharmStyle.THEME.error)
    button_view!(menu, frame, left, top + rows + 5, width)
    put!(buffer, area, left, top + rows + 7, "type to search  ↑↓ move  enter select  tab focus  esc back", CharmStyle.THEME.dim)
end

function feature_view!(menu::Menu, frame::Frame)
    state = BuildCore.snapshot(menu.builder)
    signature = join([string(i, ':', haskey(state.jobs, BuildCore.RECIPES[i].id) ?
                            state.jobs[BuildCore.RECIPES[i].id].state : :off) for i in menu.feature_filtered], ',')
    if signature != menu.feature_signature
        menu.choices.items = [begin
            recipe = BuildCore.RECIPES[i]
            job = get(state.jobs, recipe.id, nothing)
            marker = job === nothing ? "• " : job.state == :done ? "✓ " : job.state == :failed ? "! " : "… "
            style = job === nothing ? CharmStyle.THEME.dim : job.state == :failed ? CharmStyle.THEME.error : CharmStyle.THEME.active
            suffix = job === nothing ? "" : job.state == :running ? "  building" : job.state == :failed ? "  failed" : "  ready"
            ListItem(recipe.name * suffix, CharmStyle.THEME.text; prefix=marker, prefix_style=style)
        end for i in menu.feature_filtered]
        menu.feature_signature = signature
    end
    area, buffer = frame.area, frame.buffer
    rows = min(10, max(1, length(menu.choices.items)), max(1, area.height - 9))
    width = min(72, area.width)
    left, top, width = position(area, width, rows + 8)
    put!(buffer, area, left, top, "Build your features:", CharmStyle.THEME.title)
    put!(buffer, area, left, top + 2, "Search:", CharmStyle.THEME.pointer)
    render(menu.feature_search, Rect(left + 8, top + 2, max(0, width - 8), 1), buffer)
    choices_view!(menu, Rect(left, top + 3, width, rows), buffer)
    if !isempty(menu.feature_filtered)
        recipe = BuildCore.RECIPES[menu.feature_filtered[menu.choices.selected]]
        job = get(state.jobs, recipe.id, nothing)
        message = job !== nothing && job.state == :failed ? job.error : menu.notice
        isempty(message) || put!(buffer, area, left, top + rows + 3, message, CharmStyle.THEME.error)
    end
    button_view!(menu, frame, left, top + rows + 5, width)
    put!(buffer, area, left, top + rows + 7, "type to search  ↑↓ move  enter toggle  tab focus  esc back", CharmStyle.THEME.dim)
end

function name_view!(menu::Menu, frame::Frame)
    area, buffer = frame.area, frame.buffer
    width = min(72, area.width)
    left, top, width = position(area, width, 9)
    put!(buffer, area, left, top, "Name your harness:", CharmStyle.THEME.title)
    render(menu.harness_name, Rect(left, top + 2, max(0, width), 1), buffer)
    put!(buffer, area, left, top + 4, "Use this name as a command in your terminal.", CharmStyle.THEME.dim)
    isempty(menu.notice) || put!(buffer, area, left, top + 5, menu.notice, CharmStyle.THEME.error)
    button_view!(menu, frame, left, top + 7, width)
    put!(buffer, area, left, top + 9, "tab focus  enter activate  esc back", CharmStyle.THEME.dim)
end

function building_view!(menu::Menu, frame::Frame)
    state = BuildCore.snapshot(menu.builder)
    if state.state == :done
        open_built_harness!(menu, state.install_dir)
        return
    end
    area, buffer = frame.area, frame.buffer
    width = min(72, area.width)
    left, top, width = position(area, width, 9)
    title = state.state == :failed ? "Build needs attention" : "Building your harness…"
    put!(buffer, area, left, top, title, state.state == :failed ? CharmStyle.THEME.error : CharmStyle.THEME.title)
    done = count(j -> j.state == :done, values(state.jobs)) + Int(state.build_done) + Int(state.alias_done)
    total = length(state.jobs) + 2
    render(CharmStyle.Progress(done / total), Rect(left, top + 2, width, 1), buffer)
    if state.state == :failed
        put!(buffer, area, left, top + 4, state.error, CharmStyle.THEME.error)
    else
        seconds = BuildCore.estimate(menu.builder)
        estimate = seconds === nothing ? "Estimating time…" : "About $(ceil(Int, seconds))s remaining"
        put!(buffer, area, left, top + 4, "$done / $total complete  ·  $estimate", CharmStyle.THEME.dim)
    end
    put!(buffer, area, left, top + 7, "esc back", CharmStyle.THEME.dim)
end

function wrap_lines(text::AbstractString, width::Int)
    width < 1 && return [String(text)]
    lines = String[]
    for original in split(text, '\n'; keepempty=true)
        line = if occursin('\t', original)
            expanded = IOBuffer()
            column = 0
            for glyph in Base.Unicode.graphemes(original)
                if glyph == "\t"
                    spaces = 4 - mod(column, 4)
                    print(expanded, " "^spaces)
                    column += spaces
                else
                    print(expanded, glyph)
                    column += textwidth(glyph)
                end
            end
            String(take!(expanded))
        else
            original
        end
        if isempty(line)
            push!(lines, "")
            continue
        end
        start, limit = firstindex(line), ncodeunits(line) + 1
        if all(b -> 0x20 <= b <= 0x7e, codeunits(line))
            while start < limit
                stop = min(start + width, limit)
                if stop < limit
                    last_space, seen_nonspace = 0, false
                    for i in start:stop-1
                        if codeunit(line, i) == 0x20
                            seen_nonspace && (last_space = i + 1)
                        else
                            seen_nonspace = true
                        end
                    end
                    last_space != 0 && (stop = last_space)
                end
                push!(lines, String(SubString(line, start, stop - 1)))
                start = stop
            end
            continue
        end
        while start < limit
            stop, next_index, last_space, columns = start, start, 0, 0
            seen_nonspace = false
            for glyph in Base.Unicode.graphemes(SubString(line, start))
                next_index += ncodeunits(glyph)
                glyph_width = textwidth(glyph)
                columns + glyph_width > width && break
                columns += glyph_width
                stop = next_index
                if glyph == " "
                    seen_nonspace && (last_space = stop)
                else
                    seen_nonspace = true
                end
            end
            stop == start && (stop = next_index)
            stop < limit && last_space != 0 && (stop = last_space)
            push!(lines, String(SubString(line, start, prevind(line, stop))))
            start = stop
        end
    end
    lines
end

function invalidate_chat!(menu::Menu, from::Int=1)
    layout = menu.layout
    keep = clamp(from - 1, 0, length(layout.ends))
    resize!(layout.lines, keep == 0 ? 0 : layout.ends[keep])
    resize!(layout.ends, keep)
end

function tool_summary(entry::ChatEntry)
    args = try JSON.parse(entry.arguments) catch; nothing end
    args isa AbstractDict || return entry.arguments
    path = string(get(args, "path", ""))
    if entry.name == "command"
        return string(get(args, "command", ""))
    elseif entry.name == "search"
        query = string(get(args, "query", ""))
        return isempty(path) ? repr(query) : repr(query) * " · " * path
    elseif entry.name == "read" && haskey(args, "offset")
        return path * ":" * string(args["offset"])
    end
    path
end

function wrapped_lines(text::AbstractString, width::Int)
    wrap_lines(chomp(text), max(1, width))
end

function output_preview(text::String, width::Int, limit::Int)
    lines = String[]
    more = false
    for line in eachline(IOBuffer(text))
        isempty(strip(line)) && continue
        if length(lines) >= limit
            more = true
            break
        end
        sample = first(line, max(128, width * (limit + 1)))
        more |= ncodeunits(sample) < ncodeunits(line)
        append!(lines, wrapped_lines(sample, width))
        length(lines) > limit && (more = true; break)
    end
    resize!(lines, min(length(lines), limit))
    lines, more
end

function chat_entry_lines(entry::ChatEntry, width::Int, expanded::Bool)
    inset = width >= 24 ? (entry.kind == :tool ? 3 : 1) : 0
    surface = entry.kind == :user ? :user : entry.kind == :tool ? :tool : :none
    body_width = max(1, width - 2 * inset - 3)
    rows = ChatLine[]
    function add_lines(text, marker, marker_style, text_style)
        for (i, line) in enumerate(wrapped_lines(text, body_width))
            lead = i == 1 ? marker : "  "
            push!(rows, ChatLine([Span(lead, marker_style), Span(String(line), text_style)], surface, inset))
        end
    end
    if entry.kind == :tool
        state = entry.status == :running ? "…" : entry.status == :error ? "!" : entry.status == :skipped ? "–" : "✓"
        summary = tool_summary(entry)
        header = entry.name * "  " * state * (isempty(summary) ? "" : "  " * summary)
        header_lines, header_more = output_preview(header, body_width, 2)
        for line in header_lines
            push!(rows, ChatLine([Span("  ", CharmStyle.THEME.tool_dim), Span(String(line), CharmStyle.THEME.tool_text)], surface, inset))
        end
        header_more && push!(rows, ChatLine([Span("  …", CharmStyle.THEME.tool_dim)], surface, inset))
        if expanded && !isempty(entry.arguments)
            args = try JSON.json(JSON.parse(entry.arguments); pretty=2) catch; entry.arguments end
            add_lines(args, "  ", CharmStyle.THEME.tool_dim, CharmStyle.THEME.tool_dim)
        end
        if entry.output !== nothing && !isempty(entry.output)
            if expanded
                isempty(entry.arguments) || push!(rows, ChatLine(Span[], surface, inset))
                add_lines(entry.output, "  ", CharmStyle.THEME.tool_dim,
                          entry.status == :error ? CharmStyle.THEME.tool_error : CharmStyle.THEME.tool_dim)
            else
                preview, more = output_preview(entry.output, body_width, 2)
                for line in preview
                    push!(rows, ChatLine([Span("  ", CharmStyle.THEME.tool_dim),
                                          Span(String(line), entry.status == :error ? CharmStyle.THEME.tool_error : CharmStyle.THEME.tool_dim)], surface, inset))
                end
                more && push!(rows, ChatLine([Span("  …", CharmStyle.THEME.tool_dim)], surface, inset))
            end
        end
    elseif entry.kind == :user
        add_lines(entry.text, "❯ ", CharmStyle.THEME.user_mark, CharmStyle.THEME.text)
    elseif entry.kind == :agent
        add_lines(entry.text, "✦ ", CharmStyle.THEME.agent_mark, CharmStyle.THEME.text)
    else
        style = entry.kind == :error ? CharmStyle.THEME.error : CharmStyle.THEME.dim
        add_lines(entry.text, entry.kind == :error ? "! " : "· ", style, style)
    end
    rows
end

function streaming_rows(text::String, width::Int, separator::Bool)
    rows = chat_entry_lines(ChatEntry(kind=:agent, text=text), width, false)
    separator && pushfirst!(rows, ChatLine(Span[], :none, 0))
    rows
end

function chat_layout!(menu::Menu, width::Int)
    layout = menu.layout
    if layout.width != width || length(layout.ends) > length(menu.transcript)
        invalidate_chat!(menu)
        layout.width = width
        layout.streaming = ""
        empty!(layout.streaming_lines)
        layout.stream_task = nothing
    end
    blank = ChatLine(Span[], :none, 0)
    for i in length(layout.ends)+1:length(menu.transcript)
        i > 1 && push!(layout.lines, blank)
        append!(layout.lines, chat_entry_lines(menu.transcript[i], width, menu.expanded_tools))
        push!(layout.ends, length(layout.lines))
    end
    text = menu.streaming
    separator = !isempty(menu.transcript)
    if isempty(text)
        layout.streaming = ""
        empty!(layout.streaming_lines)
        layout.stream_task = nothing
        return layout
    end
    task = layout.stream_task
    failed = false
    if task !== nothing && istaskdone(task)
        layout.stream_task = nothing
        result = try fetch(task) catch; failed = true; nothing end
        if result !== nothing
            old_text, old_width, old_separator, rows = result
            if old_width == width && old_separator == separator && startswith(text, old_text)
                layout.streaming = old_text
                layout.streaming_separator = old_separator
                layout.streaming_lines = rows
            end
        end
    end
    if layout.streaming !== text || layout.streaming_separator != separator
        if !failed && ncodeunits(text) >= 64_000 && Threads.nthreads() > 1
            if layout.stream_task === nothing
                layout.stream_task = Threads.@spawn (text, width, separator, streaming_rows(text, width, separator))
            end
        else
            layout.streaming = text
            layout.streaming_separator = separator
            layout.streaming_lines = streaming_rows(text, width, separator)
        end
    end
    layout
end

function chat_view!(menu::Menu, frame::Frame)
    area, buffer = frame.area, frame.buffer
    if area.width < 6 || area.height < 6
        menu.chat_area = Rect()
        area.width > 0 && area.height > 0 &&
            put!(buffer, area, area.x, area.y, "Resize terminal", CharmStyle.THEME.dim)
        return
    end
    left, top, width, height = area.x, area.y, area.width, area.height
    model = menu.session.model
    put!(buffer, area, left, top, "JuliaForever · " * model, CharmStyle.THEME.title)
    available = height - 6
    layout = chat_layout!(menu, width)
    fixed = length(layout.lines)
    total = fixed + length(layout.streaming_lines)
    maximum_scroll = max(0, total - available)
    menu.scroll > 0 && (menu.scroll += maximum_scroll - menu.max_scroll)
    menu.scroll = clamp(menu.scroll, 0, maximum_scroll)
    menu.max_scroll = maximum_scroll
    first_line = maximum_scroll - menu.scroll + 1
    last_line = min(total, first_line + available - 1)
    menu.chat_area = Rect(left, top + 2, width, available)
    if first_line <= last_line
        for (row, i) in enumerate(first_line:last_line)
            line = i <= fixed ? layout.lines[i] : layout.streaming_lines[i - fixed]
            y = menu.chat_area.y + row - 1
            if line.surface != :none
                style = line.surface == :user ? CharmStyle.THEME.user_surface : CharmStyle.THEME.tool_surface
                set_style!(buffer, Rect(left + line.inset, y, width - 2 * line.inset, 1), style)
            end
            x = left + line.inset + 1
            for span in line.spans
                x = set_string!(buffer, x, y, span.content, span.style; max_x=right(menu.chat_area) - line.inset)
            end
        end
    end
    if maximum_scroll > 0
        indicator = (menu.scroll < maximum_scroll ? "↑" : "") * (menu.scroll > 0 ? " ↓" : "")
        put!(buffer, area, max(left, left + width - textwidth(indicator)), top, indicator, CharmStyle.THEME.dim)
    end
    prompt_y = top + height - 3
    put!(buffer, area, left, prompt_y, menu.busy ? "…" : "❯", CharmStyle.THEME.pointer)
    render(menu.prompt, Rect(left + 2, prompt_y, max(0, width - 2), 1), buffer)
    footer = menu.busy ? "…  ↑↓ scroll  ctrl+o tools" : "enter send  ↑↓ scroll  ctrl+o tools  esc models"
    feature_footer = HotReload.footer(menu)
    feature_footer isa AbstractString && !isempty(feature_footer) && (footer = String(feature_footer))
    isempty(menu.notice) || (footer = menu.notice)
    put!(buffer, area, left, top + height - 1, footer, CharmStyle.THEME.dim)
end

function view(menu::Menu, frame::Frame)
    reload_notice = HotReload.take_notice!()
    isempty(reload_notice) || (menu.notice = reload_notice)
    menu.page == :chat && HotReload.on_frame!(menu)
    menu.page == :waiting && poll_login!(menu)
    menu.page in (:loading, :opening, :chat) && poll_pending!(menu)
    if menu.page in (:auth, :accounts)
        choice_view!(menu, frame)
    elseif menu.page == :models
        model_view!(menu, frame)
    elseif menu.page == :features
        feature_view!(menu, frame)
    elseif menu.page == :name
        name_view!(menu, frame)
    elseif menu.page == :building
        building_view!(menu, frame)
    elseif menu.page == :chat
        chat_view!(menu, frame)
    elseif menu.page in (:loading, :opening)
        left, top, width = position(frame.area, 36, 3)
        put!(frame.buffer, frame.area, left, top, menu.page == :opening ? "Opening harness…" : "Loading models…", CharmStyle.THEME.title)
        if frame.area.y <= top + 2 <= bottom(frame.area)
            render(CharmStyle.Progress(nothing), Rect(left, top + 2, width, 1), frame.buffer)
        end
    else
        status_view!(menu, frame)
    end
end

function warm_live_editor!(menu::Menu)
    generation = HotReload.snapshot()
    generation === nothing && return
    for (_, source) in generation.sources
        try
            callback = Base.invokelatest(getfield, source, :on_key!)
            Base.invokelatest(precompile, callback, (typeof(menu), KeyEvent, Dict{Symbol,Any}))
        catch
        end
    end
end

function feature_dir()
    profile = get(ENV, "JULIAFOREVER_PROFILE", "")
    isempty(profile) ? joinpath(ChatGPTAuth.ensure_dir(), "features") : joinpath(profile, "features")
end

function main()
    profile = get(ENV, "JULIAFOREVER_PROFILE", "")
    feature_path = feature_dir()
    if isempty(profile)
        mkpath(feature_path; mode=0o700)
    elseif !isdir(feature_path)
        error("Harness feature directory not found: $feature_path")
    end
    HotReload.start!(@__MODULE__, feature_path)
    menu = Menu()
    warm_live_editor!(menu)
    previous = NativeAgent.restore_session()
    if previous !== nothing
        show_chat!(menu, previous)
    elseif !isempty(profile)
        data = JSON.parsefile(joinpath(profile, "profile.json"))
        show_chat!(menu, NativeAgent.Session(String(data["model"]), Int(data["window"]), pwd()))
    end
    capturing = Tachikoma.raw_capture_enabled()
    Tachikoma.enable_raw_capture!()
    try
        app(menu; fps=120, default_bindings=false)
    finally
        capturing || Tachikoma.disable_raw_capture!()
        menu.flow === nothing || ChatGPTAuth.cancel!(menu.flow)
        menu.builder === nothing || BuildCore.cleanup!(menu.builder)
        HotReload.stop!()
    end
    if menu.restart
        project = dirname(@__DIR__)
        run(`$(Base.julia_cmd()) --project=$project $(joinpath(project, "run.jl"))`)
    end
end

include("Precompile.jl")

end
