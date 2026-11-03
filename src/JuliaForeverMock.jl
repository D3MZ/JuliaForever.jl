module JuliaForeverMock

using Tachikoma
@tachikoma_app

const AUTH_OPTIONS = ["Sign in with an account", "Sign in with an API key"]
const ACCOUNTS = ["ChatGPT", "Anthropic", "Google", "Other provider"]
const API_OPTIONS = ["Sample API key", "Custom endpoint"]
const FORMATS = ["OpenAI Chat Completions", "OpenAI Responses", "Anthropic Messages", "Google Gemini"]

struct ModelChoice
    id::String
    name::String
    provider::String
end

struct Recipe
    name::String
    detail::String
    styles::Vector{String}
end
Recipe(name; detail="", styles=String[]) = Recipe(name, detail, styles)

const RECIPES = [
    Recipe("Microphone"),
    Recipe("Model selector"; detail="Switch models in the harness"),
    Recipe("Scheduling"; detail="Periodic checks"),
    Recipe("Web app"),
    Recipe("GitHub"),
    Recipe("Compaction"; styles=["Pi", "DeepSeek", "Minimal"]),
    Recipe("Browser"),
    Recipe("Caesar cipher"),
]
const BUILD_SECONDS = 15.0

list(items) = SelectableList(collect(items); focused=true)

@kwdef mutable struct Menu <: Model
    page::Symbol = :auth
    choices::SelectableList = list(AUTH_OPTIONS)
    models::SelectableList = list(String[])
    features::SelectableList = list([recipe.name for recipe in RECIPES])
    input::TextInput = TextInput(; focused=true)
    model_search::TextInput = TextInput(; focused=true)
    search::TextInput = TextInput(; focused=true)
    model_catalog::Vector{ModelChoice} = ModelChoice[]
    model_matches::Vector{Int} = Int[]
    model_provider::String = ""
    model_defaults::Dict{String,String} = Dict{String,String}()
    matches::Vector{Int} = collect(eachindex(RECIPES))
    started::Vector{Float64} = zeros(length(RECIPES))
    styles::Vector{Int} = ones(Int, length(RECIPES))
    connection::String = ""
    source::Symbol = :account
    via_format::Bool = false
    model::String = ""
    harness_name::String = ""
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

function show_models!(menu::Menu)
    connection = lowercase(menu.connection)
    provider, catalog = if menu.source == :endpoint
        "custom", [ModelChoice("example-model", "Example model", "custom")]
    elseif occursin("anthropic", connection)
        "anthropic", [ModelChoice("claude-sonnet", "Claude Sonnet", "anthropic"),
                      ModelChoice("claude-opus", "Claude Opus", "anthropic")]
    elseif occursin("google", connection) || occursin("gemini", connection)
        "google", [ModelChoice("gemini-pro", "Gemini Pro", "google"),
                   ModelChoice("gemini-flash", "Gemini Flash", "google")]
    elseif occursin("openai", connection) || occursin("chatgpt", connection)
        "openai", [ModelChoice("gpt-6.1-terra", "GPT-6.1 Terra", "openai"),
                   ModelChoice("gpt-5.6-terra", "GPT-5.6 Terra", "openai"),
                   ModelChoice("gpt-5", "GPT-5", "openai")]
    else
        "other", [ModelChoice("example-model", "Example model", "other")]
    end
    menu.model_provider != provider && set_text!(menu.model_search, "")
    menu.model_provider = provider
    menu.model_catalog = catalog
    get!(menu.model_defaults, provider, first(catalog).id)
    menu.page = :models
    refresh_models!(menu)
    chosen = findfirst(choice -> choice.id == menu.model, catalog)
    menu.models.selected = chosen === nothing ? 1 : something(findfirst(==(chosen), menu.model_matches), 1)
end

function fuzzy_match(needle::AbstractString, haystack::AbstractString)
    chars = collect(needle)
    isempty(chars) && return true
    i = 1
    for char in haystack
        if char == chars[i]
            i += 1
            i > length(chars) && return true
        end
    end
    false
end

function matches_query(query::AbstractString, fields::AbstractString...)
    haystack = lowercase(join(fields, " "))
    all(token -> fuzzy_match(token, haystack), split(lowercase(strip(query))))
end

function refresh_models!(menu::Menu)
    query = text(menu.model_search)
    matches = [i for i in eachindex(menu.model_catalog) if
               matches_query(query, menu.model_catalog[i].id, menu.model_catalog[i].name, menu.model_catalog[i].provider)]
    # Offer a custom model when browsing the full list or when nothing matches.
    (isempty(strip(query)) || isempty(matches)) && push!(matches, 0)
    if matches != menu.model_matches
        menu.model_matches = matches
        menu.models.selected = 1
        menu.models.offset = 0
    end
    default = menu.model_defaults[menu.model_provider]
    menu.models.items = [if i == 0
        label = isempty(strip(query)) ? "Enter a model name…" : "Use \"$(strip(query))\" as model"
        ListItem(label, tstyle(:text_dim))
    else
        choice = menu.model_catalog[i]
        is_default = choice.id == default
        label = "$(choice.id) [$(choice.provider)]" * (is_default ? " · mock default" : "")
        ListItem(label, tstyle(:text); prefix=is_default ? "✓ " : "  ", prefix_style=tstyle(:success))
    end for i in matches]
end

function activate_model!(menu::Menu)
    i = menu.model_matches[menu.models.selected]
    if i == 0 && isempty(strip(text(menu.model_search)))
        show_input!(menu, :model_name, isempty(menu.model) ? "my-model" : menu.model)
    else
        menu.model = i == 0 ? strip(text(menu.model_search)) : menu.model_catalog[i].id
        show_features!(menu)
    end
end

function show_features!(menu::Menu)
    menu.page = :features
    refresh_features!(menu)
end

function show_harness_name!(menu::Menu)
    show_input!(menu, :harness_name, isempty(menu.harness_name) ? "juliaforever" : menu.harness_name)
end

function refresh_features!(menu::Menu)
    query = text(menu.search)
    matches = [i for i in eachindex(RECIPES) if
        matches_query(query, RECIPES[i].name, RECIPES[i].detail, RECIPES[i].styles...)]
    if matches != menu.matches
        menu.matches = matches
        menu.features.selected = 1
        menu.features.offset = 0
    end
    spinner = SPINNER_BRAILLE[mod1(floor(Int, time() * 4), length(SPINNER_BRAILLE))]
    menu.features.items = [begin
        start = menu.started[i]
        running = start > 0 && time() - start < BUILD_SECONDS
        prefix = start == 0 ? "○   " : running ? "✓ $(spinner) " : "✓   "
        prefix_style = start == 0 ? tstyle(:text_dim) : running ? tstyle(:accent) : tstyle(:success)
        recipe = RECIPES[i]
        name = isempty(recipe.styles) ? recipe.name : "$(recipe.name) · $(recipe.styles[menu.styles[i]])"
        ListItem(name, tstyle(:text); prefix=prefix, prefix_style=prefix_style)
    end for i in matches]
end

function toggle_feature!(menu::Menu)
    isempty(menu.matches) && return
    i = menu.matches[menu.features.selected]
    menu.started[i] = menu.started[i] == 0 ? time() : 0.0
    refresh_features!(menu)
end

function cycle_style!(menu::Menu, direction::Int)
    isempty(menu.matches) && return
    i = menu.matches[menu.features.selected]
    styles = RECIPES[i].styles
    isempty(styles) && return
    menu.styles[i] = mod1(menu.styles[i] + direction, length(styles))
    menu.started[i] > 0 && (menu.started[i] = time())
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
        menu.via_format = isempty(provider)
        if isempty(provider)
            show_choices!(menu, :format, FORMATS)
        else
            menu.connection = provider * " key"
            show_models!(menu)
        end
    elseif menu.page == :endpoint
        set_text!(menu.input, "")
        menu.source = :endpoint
        menu.via_format = true
        show_choices!(menu, :format, FORMATS)
    elseif menu.page == :model_name
        menu.model = value
        show_features!(menu)
    elseif menu.page == :harness_name
        menu.harness_name = value
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
        menu.via_format = false
        show_models!(menu)
    elseif menu.page == :api
        i == 1 ? show_input!(menu, :key, "sk-demo-key") : show_input!(menu, :endpoint, "https://example.com/v1")
    elseif menu.page == :format
        menu.connection = FORMATS[i] * (menu.source == :key ? " key" : " endpoint")
        show_models!(menu)
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
    elseif menu.page == :models
        if menu.source == :account
            show_choices!(menu, :accounts, ACCOUNTS)
        elseif menu.via_format
            show_choices!(menu, :format, FORMATS)
        else
            show_input!(menu, :key, "sk-demo-key")
        end
    elseif menu.page == :model_name || menu.page == :features
        show_models!(menu)
    elseif menu.page == :harness_name
        show_features!(menu)
    elseif menu.page == :saved
        show_harness_name!(menu)
    end
end

function update!(menu::Menu, event::KeyEvent)
    if event.key == :ctrl_c || (event.key == :ctrl && event.char == 'c')
        menu.quit = true
        return
    end

    if menu.page in (:key, :endpoint, :model_name, :harness_name)
        if event.key == :enter
            submit_input!(menu)
        elseif event.key == :escape
            go_back!(menu)
        elseif event.key == :ctrl && event.char == 'u'
            set_text!(menu.input, "")
        else
            handle_key!(menu.input, event)
        end
    elseif menu.page == :models
        if event.key == :escape
            if isempty(text(menu.model_search))
                go_back!(menu)
            else
                set_text!(menu.model_search, "")
                refresh_models!(menu)
            end
        elseif event.key == :enter
            activate_model!(menu)
        elseif event.key == :ctrl && event.char == 's'
            i = menu.model_matches[menu.models.selected]
            if i != 0
                menu.model_defaults[menu.model_provider] = menu.model_catalog[i].id
                refresh_models!(menu)
            end
        elseif event.key == :ctrl && event.char == 'u'
            set_text!(menu.model_search, "")
            refresh_models!(menu)
        elseif event.key in (:up, :down, :pageup, :pagedown)
            handle_key!(menu.models, event)
        elseif event.key != :char || length(text(menu.model_search)) < 128
            handle_key!(menu.model_search, event)
            refresh_models!(menu)
        end
    elseif menu.page == :features
        if event.key == :escape
            if isempty(text(menu.search))
                go_back!(menu)
            else
                set_text!(menu.search, "")
                refresh_features!(menu)
            end
        elseif event.key == :tab
            show_harness_name!(menu)
        elseif event.key == :enter || (event.key == :char && event.char == ' ' && isempty(text(menu.search)))
            toggle_feature!(menu)
        elseif event.key == :ctrl && event.char == 'u'
            set_text!(menu.search, "")
            refresh_features!(menu)
        elseif event.key in (:up, :down, :pageup, :pagedown)
            handle_key!(menu.features, event)
        elseif event.key in (:left, :right) && isempty(text(menu.search)) &&
               !isempty(menu.matches) && !isempty(RECIPES[menu.matches[menu.features.selected]].styles)
            cycle_style!(menu, event.key == :right ? 1 : -1)
        elseif event.key != :char || length(text(menu.search)) < 128
            handle_key!(menu.search, event)
            refresh_features!(menu)
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
    if menu.page == :models
        if handle_mouse!(menu.model_search, event)
            return
        elseif handle_mouse!(menu.models, event) && event.button == mouse_left && event.action == mouse_press
            activate_model!(menu)
        end
    elseif menu.page == :features
        if handle_mouse!(menu.search, event)
            return
        elseif handle_mouse!(menu.features, event) && event.button == mouse_left && event.action == mouse_press
            toggle_feature!(menu)
        end
    elseif menu.page in (:auth, :accounts, :api, :format)
        handle_mouse!(menu.choices, event)
    elseif menu.page in (:endpoint, :model_name, :harness_name)
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
    footer = "enter continue  ctrl+u clear  escape back"
    if menu.page == :harness_name
        title = "Name your harness (mock):"
        explanation = ["Once implemented, the name will be registered in",
                       "your environment, which will then be reloaded.",
                       "Type the name to start the harness.",
                       "Mock only; nothing is registered or reloaded."]
        status = "$(selected_count(menu)) selected · $(running_count(menu)) building (mock)"
        width = max(textwidth(title), textwidth(footer), textwidth(status), maximum(textwidth, explanation))
        left, top, width = position(area, width, 11)
        put!(buffer, area, left, top, title, tstyle(:title, bold=true))
        for (i, line) in enumerate(explanation)
            put!(buffer, area, left, top + i, line, tstyle(:text_dim))
        end
        put!(buffer, area, left, top + 6, status, tstyle(:text_dim))
        put!(buffer, area, left, top + 8, "› ", tstyle(:accent))
        render(menu.input, Rect(left + 2, top + 8, max(0, width - 2), 1), buffer)
        put!(buffer, area, left, top + 10, footer, tstyle(:text_dim))
        return
    end

    title = menu.page == :key ? "Enter a sample API key:" :
            menu.page == :endpoint ? "Enter a custom endpoint:" : "Enter a model name:"
    subtitle = menu.page == :key ? "Mock only; never enter a real key." :
               menu.page == :endpoint ? "Mock only; no request is sent." : "Mock only; no model is loaded."
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

function search_view!(search::TextInput, frame::Frame, left::Int, top::Int, width::Int)
    area, buffer = frame.area, frame.buffer
    put!(buffer, area, left, top, "Search: ", tstyle(:text_dim))
    render(search, Rect(left + 8, top, max(0, width - 8), 1), buffer)
    isempty(text(search)) && put!(buffer, area, left + 9, top, "type to filter", tstyle(:text_dim))
end

function models_view!(menu::Menu, frame::Frame)
    refresh_models!(menu)
    area, buffer = frame.area, frame.buffer
    title = "Select a model (mock):"
    subtitle = "Mock only; no provider contacted or default saved."
    i = menu.model_matches[menu.models.selected]
    detail = i == 0 ? "Model: custom" : "Model: " * menu.model_catalog[i].name
    position_text = i == 0 ? "" : "($(menu.models.selected)/$(count(!iszero, menu.model_matches)))"
    footer = "↑↓ move  enter select  ctrl+s default"
    footer_extra = "ctrl+u clear  esc clear/back"
    footers = textwidth(footer * "  " * footer_extra) <= area.width ? [footer * "  " * footer_extra] : [footer, footer_extra]
    rows = min(10, max(1, area.height - 8 - length(footers)), length(menu.model_catalog) + 1)
    width = max(textwidth(title), textwidth(subtitle), textwidth(detail), maximum(textwidth, footers),
                maximum((textwidth(item.content) + textwidth(item.prefix) + 2 for item in menu.models.items); init=0))
    left, top, width = position(area, width, rows + 8 + length(footers))
    put!(buffer, area, left, top, title, tstyle(:title, bold=true))
    put!(buffer, area, left, top + 1, subtitle, tstyle(:text_dim))
    search_view!(menu.model_search, frame, left, top + 3, width)
    menu.models.offset = clamp(menu.models.offset, 0, max(0, length(menu.models.items) - rows))
    render(menu.models, Rect(left, top + 5, width, rows), buffer)
    put!(buffer, area, left, top + rows + 5, position_text, tstyle(:text_dim))
    put!(buffer, area, left, top + rows + 6, detail, tstyle(:text_dim))
    for (i, line) in enumerate(footers)
        put!(buffer, area, left, top + rows + 7 + i, line, tstyle(:text_dim))
    end
end

function features_view!(menu::Menu, frame::Frame)
    refresh_features!(menu)
    query = text(menu.search)
    recipe = isempty(menu.matches) ? nothing : RECIPES[menu.matches[menu.features.selected]]
    note = recipe === nothing ? "" :
           !isempty(recipe.styles) && isempty(query) ? "←→ change style" : recipe.detail
    status = "$(selected_count(menu)) selected · $(running_count(menu)) building (mock)" *
             (isempty(query) ? "" : " · $(length(menu.matches)) matches")
    footer = "↑↓ move  enter toggle  tab next"
    footer_extra = "ctrl+u clear  esc clear/back"
    area, buffer = frame.area, frame.buffer
    footers = textwidth(footer * "  " * footer_extra) <= area.width ? [footer * "  " * footer_extra] : [footer, footer_extra]
    rows = min(max(1, area.height - 5 - length(footers)), length(RECIPES))
    width = max(textwidth("Build your features (mock):"), maximum(textwidth, footers), textwidth(note), textwidth(status),
                maximum((textwidth(item.content) + textwidth(item.prefix) + 2 for item in menu.features.items); init=0))
    left, top, width = position(area, width, rows + 5 + length(footers))
    put!(buffer, area, left, top, "Build your features (mock):", tstyle(:title, bold=true))
    search_view!(menu.search, frame, left, top + 1, width)
    menu.features.offset = clamp(menu.features.offset, 0, max(0, length(menu.features.items) - rows))
    render(menu.features, Rect(left, top + 2, width, rows), buffer)
    isempty(menu.matches) && put!(buffer, area, left, top + 2, "No matching features.", tstyle(:text_dim))
    isempty(note) || put!(buffer, area, left, top + rows + 2, note, tstyle(:text_dim))
    put!(buffer, area, left, top + rows + 3, status, tstyle(:text_dim))
    for (i, line) in enumerate(footers)
        put!(buffer, area, left, top + rows + 4 + i, line, tstyle(:text_dim))
    end
end

function saved_view!(menu::Menu, frame::Frame)
    area, buffer = frame.area, frame.buffer
    title = "Harness named (mock):"
    model = "Model: " * menu.model
    status = "$(selected_count(menu)) selected · $(running_count(menu)) building (mock)"
    warning = "Nothing registered or reloaded."
    footer = "tab features  escape back"
    width = max(textwidth(title), textwidth(menu.harness_name), textwidth(model), textwidth(status), textwidth(warning), textwidth(footer))
    left, top, width = position(area, width, 8)
    put!(buffer, area, left, top, title, tstyle(:title, bold=true))
    put!(buffer, area, left, top + 2, menu.harness_name, tstyle(:accent))
    put!(buffer, area, left, top + 3, model, tstyle(:text))
    put!(buffer, area, left, top + 4, status, tstyle(:text_dim))
    put!(buffer, area, left, top + 5, warning, tstyle(:text_dim))
    put!(buffer, area, left, top + 7, footer, tstyle(:text_dim))
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
    elseif menu.page == :models
        models_view!(menu, frame)
    elseif menu.page in (:key, :endpoint, :model_name, :harness_name)
        input_view!(menu, frame)
    elseif menu.page == :features
        features_view!(menu, frame)
    else
        saved_view!(menu, frame)
    end
end

function main()
    app(Menu(); fps=10, default_bindings=false)
end

end
