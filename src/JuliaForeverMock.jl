module JuliaForeverMock

using Tachikoma
@tachikoma_app

const AUTH_OPTIONS = ["Sign in with an account", "Sign in with an API key"]
const ACCOUNTS = ["ChatGPT", "Anthropic", "Google", "Other provider"]
const API_OPTIONS = ["Sample API key", "Custom endpoint"]
const FORMATS = ["OpenAI Chat Completions", "OpenAI Responses", "Anthropic Messages", "Google Gemini"]
const RECIPES = ["Microphone", "Model selector", "Scheduling", "Web app", "GitHub", "Compaction", "Browser", "Caesar cipher"]
const STYLES = ["Pi", "DeepSeek", "Minimal"]
const PROFILES = ["Default", "Agent named", "Custom"]
const BUILD_SECONDS = 15.0

list(items) = SelectableList(collect(items); focused=true)

@kwdef mutable struct Menu <: Model
    page::Symbol = :auth
    choices::SelectableList = list(AUTH_OPTIONS)
    features::SelectableList = list(RECIPES)
    input::TextInput = TextInput(; focused=true)
    search::TextInput = TextInput(; focused=true)
    searching::Bool = false
    matches::Vector{Int} = collect(eachindex(RECIPES))
    started::Vector{Float64} = zeros(length(RECIPES))
    compaction::Int = 1
    connection::String = ""
    source::Symbol = :account
    profile_kind::Symbol = :default
    profile_name::String = ""
    quit::Bool = false
end

should_quit(menu::Menu) = menu.quit
selected_count(menu::Menu) = count(!iszero, menu.started)
running_count(menu::Menu) = count(t -> t > 0 && time() - t < BUILD_SECONDS, menu.started)

function show_choices!(menu::Menu, page::Symbol, options)
    menu.page = page
    menu.choices = list(options)
end

function show_input!(menu::Menu, page::Symbol, initial::String)
    menu.page = page
    menu.input = TextInput(; text=initial, focused=true)
end

function show_features!(menu::Menu)
    menu.page = :features
    menu.searching = false
    refresh_features!(menu)
end

function refresh_features!(menu::Menu)
    query = lowercase(strip(text(menu.search)))
    matches = [i for i in eachindex(RECIPES) if occursin(query, lowercase(RECIPES[i]))]
    if matches != menu.matches
        menu.matches = matches
        menu.features.selected = 1
        menu.features.offset = 0
    end
    spinner = SPINNER_BRAILLE[mod1(floor(Int, time() * 4), length(SPINNER_BRAILLE))]
    menu.features.items = [begin
        start = menu.started[i]
        running = start > 0 && time() - start < BUILD_SECONDS
        prefix = start == 0 ? "○ " : running ? "$(spinner) " : "✓ "
        prefix_style = start == 0 ? tstyle(:text_dim) : running ? tstyle(:accent) : tstyle(:success)
        name = i == 6 ? "Compaction · $(STYLES[menu.compaction])" : RECIPES[i]
        ListItem(name, tstyle(:text); prefix=prefix, prefix_style=prefix_style)
    end for i in matches]
end

function toggle_feature!(menu::Menu)
    isempty(menu.matches) && return
    i = menu.matches[menu.features.selected]
    menu.started[i] = menu.started[i] == 0 ? time() : 0.0
    refresh_features!(menu)
end

function submit_input!(menu::Menu)
    value = strip(text(menu.input))
    isempty(value) && return
    if menu.page == :key
        provider = startswith(value, "sk-ant-") ? "Anthropic" :
                   startswith(value, "sk-demo") || startswith(value, "sk-proj-") ? "OpenAI" :
                   startswith(value, "AIza") ? "Google" : ""
        set_text!(menu.input, "")
        menu.source = :key
        if isempty(provider)
            show_choices!(menu, :format, FORMATS)
        else
            menu.connection = provider * " key"
            show_features!(menu)
        end
    elseif menu.page == :endpoint
        set_text!(menu.input, "")
        menu.source = :endpoint
        show_choices!(menu, :format, FORMATS)
    else
        menu.profile_name = value
        menu.page = :saved
    end
end

function activate_choice!(menu::Menu)
    i = menu.choices.selected
    if menu.page == :auth
        i == 1 ? show_choices!(menu, :accounts, ACCOUNTS) : show_choices!(menu, :api, API_OPTIONS)
    elseif menu.page == :accounts
        menu.connection = ACCOUNTS[i] * " account"
        menu.source = :account
        show_features!(menu)
    elseif menu.page == :api
        i == 1 ? show_input!(menu, :key, "sk-demo-key") : show_input!(menu, :endpoint, "https://example.com/v1")
    elseif menu.page == :format
        menu.connection = FORMATS[i] * (menu.source == :key ? " key" : " endpoint")
        show_features!(menu)
    elseif menu.page == :profiles
        if i == 1
            menu.profile_kind = :default
            menu.profile_name = "Default"
            menu.page = :saved
        else
            menu.profile_kind = i == 2 ? :agent : :custom
            show_input!(menu, :name, i == 2 ? "researcher" : "my-profile")
        end
    end
end

function go_back!(menu::Menu)
    if menu.page == :auth
        menu.quit = true
    elseif menu.page in (:accounts, :api)
        show_choices!(menu, :auth, AUTH_OPTIONS)
    elseif menu.page in (:key, :endpoint)
        set_text!(menu.input, "")
        show_choices!(menu, :api, API_OPTIONS)
    elseif menu.page == :format
        show_input!(menu, menu.source == :key ? :key : :endpoint,
                    menu.source == :key ? "sk-demo-key" : "https://example.com/v1")
    elseif menu.page == :features
        menu.source == :account ? show_choices!(menu, :accounts, ACCOUNTS) : show_choices!(menu, :api, API_OPTIONS)
    elseif menu.page in (:name, :saved)
        show_choices!(menu, :profiles, PROFILES)
    elseif menu.page == :profiles
        show_features!(menu)
    end
end

function update!(menu::Menu, event::KeyEvent)
    if event.key == :ctrl_c || (event.key == :ctrl && event.char == 'c')
        menu.quit = true
        return
    end

    if menu.page == :features && menu.searching
        if event.key == :enter || event.key == :escape
            menu.searching = false
        elseif event.key == :ctrl && event.char == 'u'
            set_text!(menu.search, "")
        else
            handle_key!(menu.search, event)
        end
        refresh_features!(menu)
        return
    end

    if menu.page in (:key, :endpoint, :name)
        if event.key == :enter
            submit_input!(menu)
        elseif event.key == :escape
            go_back!(menu)
        elseif event.key == :ctrl && event.char == 'u'
            set_text!(menu.input, "")
        else
            handle_key!(menu.input, event)
        end
    elseif menu.page == :features
        if event.key == :escape
            go_back!(menu)
        elseif event.key == :tab
            show_choices!(menu, :profiles, PROFILES)
        elseif event.key == :enter || (event.key == :char && event.char == ' ')
            toggle_feature!(menu)
        elseif event.key == :char && event.char == '/'
            menu.searching = true
        elseif event.key == :char && event.char == 'c' && !isempty(menu.matches) && menu.matches[menu.features.selected] == 6
            menu.compaction = mod1(menu.compaction + 1, length(STYLES))
            menu.started[6] > 0 && (menu.started[6] = time())
            refresh_features!(menu)
        else
            handle_key!(menu.features, event)
        end
    elseif menu.page == :saved
        event.key == :escape && go_back!(menu)
        event.key == :tab && show_features!(menu)
    elseif event.key == :escape
        go_back!(menu)
    elseif event.key == :enter
        activate_choice!(menu)
    else
        handle_key!(menu.choices, event)
    end
end

function update!(menu::Menu, event::MouseEvent)
    if menu.page == :features && !menu.searching
        if handle_mouse!(menu.features, event) && event.button == mouse_left && event.action == mouse_press
            toggle_feature!(menu)
        end
    elseif menu.page in (:auth, :accounts, :api, :format, :profiles)
        handle_mouse!(menu.choices, event)
    elseif menu.page in (:endpoint, :name)
        handle_mouse!(menu.input, event)
    end
end

function position(area::Rect, width::Int, height::Int)
    actual_width = min(width, area.width)
    left = area.x + max(0, (area.width - actual_width) ÷ 2)
    top = area.y + max(0, (area.height - height) ÷ 2)
    left, top, actual_width
end

function put!(buffer::Buffer, area::Rect, x::Int, y::Int, message::AbstractString, style::Style)
    area.y <= y <= bottom(area) || return
    set_string!(buffer, x, y, message, style; max_x=right(area))
end

function list_view!(frame::Frame, title::String, subtitle::String, choices::SelectableList, footer::String; note::String="")
    area, buffer = frame.area, frame.buffer
    rows = min(max(1, area.height - 5), max(1, length(choices.items)))
    width = max(textwidth(title), textwidth(subtitle), textwidth(footer), textwidth(note),
                maximum((textwidth(item.content) + textwidth(item.prefix) + 2 for item in choices.items); init=0))
    left, top, width = position(area, width, rows + 5)
    put!(buffer, area, left, top, title, tstyle(:title, bold=true))
    isempty(subtitle) || put!(buffer, area, left, top + 1, subtitle, tstyle(:text_dim))
    choices.offset = clamp(choices.offset, 0, max(0, length(choices.items) - rows))
    render(choices, Rect(left, top + 2, width, rows), buffer)
    isempty(note) || put!(buffer, area, left, top + rows + 2, note, tstyle(:text_dim))
    put!(buffer, area, left, top + rows + 4, footer, tstyle(:text_dim))
end

function input_view!(menu::Menu, frame::Frame)
    area, buffer = frame.area, frame.buffer
    title = menu.page == :key ? "Enter a sample API key:" :
            menu.page == :endpoint ? "Enter a custom endpoint:" :
            menu.profile_kind == :agent ? "Name your agent:" : "Name your profile:"
    subtitle = menu.page == :key ? "Mock only; never enter a real key." :
               menu.page == :endpoint ? "Mock only; no request is sent." : "Mock only; not saved to disk."
    footer = "enter continue  ctrl+u clear  escape back"
    width = max(textwidth(title), textwidth(subtitle), textwidth(footer), 36)
    left, top, width = position(area, width, 6)
    put!(buffer, area, left, top, title, tstyle(:title, bold=true))
    put!(buffer, area, left, top + 1, subtitle, tstyle(:text_dim))
    if menu.page == :key
        masked = repeat("•", min(length(text(menu.input)), max(0, width - 3)))
        put!(buffer, area, left, top + 3, "› " * masked * "_", tstyle(:accent))
    else
        put!(buffer, area, left, top + 3, "› ", tstyle(:accent))
        render(menu.input, Rect(left + 2, top + 3, max(0, width - 2), 1), buffer)
    end
    put!(buffer, area, left, top + 5, footer, tstyle(:text_dim))
end

function features_view!(menu::Menu, frame::Frame)
    refresh_features!(menu)
    query = text(menu.search)
    search_line = "/ search: " * (isempty(query) && !menu.searching ? "all" : query) * (menu.searching ? "_" : "")
    note = isempty(menu.matches) ? "No matching features." :
           menu.matches[menu.features.selected] == 6 ? "c change compaction style" :
           menu.matches[menu.features.selected] == 3 ? "Scheduling: periodic checks" : ""
    status = "$(selected_count(menu)) selected · $(running_count(menu)) building"
    footer = menu.searching ? "type to search  enter done  ctrl+u clear" :
             "↑↓ navigate  enter toggle  / search  tab next  escape back"
    area, buffer = frame.area, frame.buffer
    rows = min(max(1, area.height - 6), max(1, length(menu.features.items)))
    width = max(textwidth("Build your features (mock):"), textwidth(search_line), textwidth(footer), textwidth(note), textwidth(status),
                maximum((textwidth(item.content) + textwidth(item.prefix) + 2 for item in menu.features.items); init=0))
    left, top, width = position(area, width, rows + 6)
    put!(buffer, area, left, top, "Build your features (mock):", tstyle(:title, bold=true))
    put!(buffer, area, left, top + 1, search_line, tstyle(menu.searching ? :accent : :text_dim))
    menu.features.offset = clamp(menu.features.offset, 0, max(0, length(menu.features.items) - rows))
    render(menu.features, Rect(left, top + 2, width, rows), buffer)
    isempty(note) || put!(buffer, area, left, top + rows + 2, note, tstyle(:text_dim))
    put!(buffer, area, left, top + rows + 3, status, tstyle(:text_dim))
    put!(buffer, area, left, top + rows + 5, footer, tstyle(:text_dim))
end

function saved_view!(menu::Menu, frame::Frame)
    area, buffer = frame.area, frame.buffer
    title = "Profile saved (mock):"
    status = "$(selected_count(menu)) selected · $(running_count(menu)) building"
    footer = "tab features  escape back"
    width = max(textwidth(title), textwidth(menu.profile_name), textwidth(menu.connection), textwidth(status), textwidth(footer), 30)
    left, top, width = position(area, width, 7)
    put!(buffer, area, left, top, title, tstyle(:title, bold=true))
    put!(buffer, area, left, top + 2, menu.profile_name, tstyle(:accent))
    put!(buffer, area, left, top + 3, menu.connection, tstyle(:text))
    put!(buffer, area, left, top + 4, status, tstyle(:text_dim))
    put!(buffer, area, left, top + 6, footer, tstyle(:text_dim))
end

function view(menu::Menu, frame::Frame)
    if menu.page == :auth
        list_view!(frame, "Select authentication method:", "", menu.choices,
                   "↑↓ navigate  enter select  escape/ctrl+c cancel")
    elseif menu.page == :accounts
        list_view!(frame, "Select an account:", "Mock only; no account is connected.", menu.choices,
                   "↑↓ navigate  enter select  escape back")
    elseif menu.page == :api
        list_view!(frame, "Select API connection:", "", menu.choices,
                   "↑↓ navigate  enter select  escape back")
    elseif menu.page == :format
        list_view!(frame, "Select a compatible format:", "Mock only; no request is sent.", menu.choices,
                   "↑↓ navigate  enter select  escape back")
    elseif menu.page in (:key, :endpoint, :name)
        input_view!(menu, frame)
    elseif menu.page == :features
        features_view!(menu, frame)
    elseif menu.page == :profiles
        list_view!(frame, "Save to profile (mock):", "", menu.choices,
                   "↑↓ navigate  enter select  escape back";
                   note="$(selected_count(menu)) selected · $(running_count(menu)) building")
    else
        saved_view!(menu, frame)
    end
end

function main()
    app(Menu(); fps=10, default_bindings=false)
end

end
