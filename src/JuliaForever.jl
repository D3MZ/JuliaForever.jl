module JuliaForever

using Tachikoma
@tachikoma_app
include("BuildCore.jl")
import .BuildCore

const AUTH_OPTIONS = ["Sign in with an account", "Sign in with an API key"]
const ACCOUNTS = ["ChatGPT", "Anthropic", "Google", "Other provider"]
const API_OPTIONS = ["OpenAI", "Anthropic", "Google", "Other provider / endpoint"]
const CONFIGURE_PROVIDER = "Configure another provider in Pi…"

struct ModelChoice
    id::String
    name::String
    provider::String
end

const RECIPES = BuildCore.RECIPES

list(items) = SelectableList(collect(items); focused=true)

@kwdef mutable struct Menu <: Model
    page::Symbol = :auth
    choices::SelectableList = list(AUTH_OPTIONS)
    choice_picks::Dict{Symbol,Int} = Dict{Symbol,Int}()
    models::SelectableList = list(String[])
    features::SelectableList = list([recipe.name for recipe in RECIPES])
    input::TextInput = TextInput(; focused=true)
    model_search::TextInput = TextInput(; focused=true)
    search::TextInput = TextInput(; focused=true)
    model_catalog::Vector{ModelChoice} = ModelChoice[]
    model_matches::Vector{Int} = Int[]
    model_provider::String = ""
    model_pick::Union{Nothing,String} = nothing
    matches::Vector{Int} = collect(eachindex(RECIPES))
    provider::String = ""
    source::Symbol = :account
    model::String = ""
    harness_name::String = ""
    builder::Union{Nothing,BuildCore.BuildSession} = nothing
    continue_button::Button = Button("Continue")
    focus::Symbol = :content
    notice::String = ""
    action::Symbol = :none
    check_token::Int = 0
    done_seen::Float64 = 0.0
    quit::Bool = false
end

should_quit(menu::Menu) = menu.quit
selected_count(menu::Menu) = menu.builder === nothing ? 0 : length(menu.builder.jobs)
running_count(menu::Menu) = menu.builder === nothing ? 0 : count(j -> j.state == :running, values(menu.builder.jobs))

function set_focus!(menu::Menu, focus::Symbol)
    menu.focus = focus
    active = focus == :content
    menu.continue_button.focused = !active
    menu.input.focused = active
    menu.search.focused = active
    menu.model_search.focused = active
    for widget in (menu.choices, menu.models, menu.features)
        widget.focused = active
        widget.marker = active ? MARKER : ' '
        widget.highlight_style = active ? tstyle(:accent, bold=true) : tstyle(:text)
    end
end

function prepare_page!(menu::Menu)
    menu.notice = ""
    menu.continue_button.label = menu.page == :login ? "Open Pi" : "Continue"
    menu.continue_button.flash_remaining = 0
    menu.continue_button.last_area = Rect()
    set_focus!(menu, :content)
end

function show_choices!(menu::Menu, page::Symbol, options)
    menu.page = page
    menu.choices = list(options)
    menu.choices.selected = clamp(get(menu.choice_picks, page, 1), 1, max(1, length(menu.choices.items)))
    prepare_page!(menu)
end

function show_input!(menu::Menu, page::Symbol, initial::String)
    menu.page = page
    menu.input = TextInput(; text=initial, focused=true)
    prepare_page!(menu)
end

function refresh_choices!(menu::Menu)
    picked = get(menu.choice_picks, menu.page, 0)
    menu.choices.items = [ListItem(item.content, tstyle(:text);
                                  prefix=i == picked ? "● " : "○ ",
                                  prefix_style=tstyle(i == picked ? :success : :text_dim))
                          for (i, item) in enumerate(menu.choices.items)]
end

function select_choice!(menu::Menu)
    menu.choice_picks[menu.page] = menu.choices.selected
    menu.notice = ""
end

function show_models!(menu::Menu, entries=nothing)
    try
        catalog = entries === nothing ? copy(menu.model_catalog) :
                  [ModelChoice(id, id, provider) for (provider, id) in entries if provider == menu.provider]
        isempty(catalog) && error("No models found for $(menu.provider). Configure models in Pi first.")
        preferred = get(ENV, "PI_MODEL", "gpt-6.1-terra")
        sort!(catalog; by=c -> (c.id == preferred ? 0 : 1, c.id))
        if menu.model_provider != menu.provider
            set_text!(menu.model_search, "")
            menu.model_pick = nothing
            menu.model = ""
        end
        menu.model_provider = menu.provider
        menu.model_catalog = catalog
        menu.page = :models
        prepare_page!(menu)
        refresh_models!(menu)
        chosen = findfirst(choice -> choice.id == menu.model_pick, catalog)
        menu.models.selected = chosen === nothing ? 1 : something(findfirst(==(chosen), menu.model_matches), 1)
    catch e
        menu.page = :login
        prepare_page!(menu)
        menu.notice = sprint(showerror, e)
    end
end

function request_auth!(menu::Menu, provider::String)
    if menu.builder !== nothing && !isempty(menu.builder.jobs) && menu.builder.provider != provider
        menu.notice = "Deselect features before changing providers."
        return
    end
    menu.provider = provider
    menu.check_token += 1
    token = menu.check_token
    desired = menu.source == :account ? :oauth : :api_key
    menu.page = :checking
    prepare_page!(menu)
    @async begin
        try
            actual = BuildCore.auth_type(provider)
            menu.check_token == token || return
            if actual != desired
                menu.page = :login
                prepare_page!(menu)
                menu.notice = actual == :none ? "No Pi credentials configured for this provider." :
                              actual == :unknown ? "Pi could not identify the credential type." :
                              "Pi uses $(actual == :oauth ? "an account" : "an API key"); configure the selected method."
                return
            end
            entries = BuildCore.pi_models()
            menu.check_token == token || return
            show_models!(menu, entries)
        catch e
            if menu.check_token == token
                menu.page = :login
                prepare_page!(menu)
                menu.notice = sprint(showerror, e)
            end
        end
    end
end

function show_providers!(menu::Menu)
    menu.check_token += 1
    token = menu.check_token
    menu.page = :checking
    prepare_page!(menu)
    @async begin
        try
            providers = sort!(unique([provider for (provider, _) in BuildCore.pi_models()]))
            menu.check_token == token || return
            push!(providers, CONFIGURE_PROVIDER)
            show_choices!(menu, :providers, providers)
        catch e
            if menu.check_token == token
                menu.page = :login
                menu.provider = ""
                prepare_page!(menu)
                menu.notice = sprint(showerror, e)
            end
        end
    end
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
    if matches != menu.model_matches
        menu.model_matches = matches
        menu.models.selected = 1
        menu.models.offset = 0
    end
    menu.models.items = [begin
        choice = menu.model_catalog[i]
        picked = menu.model_pick !== nothing && menu.model_pick == choice.id
        ListItem("$(choice.id) [$(choice.provider)]", tstyle(:text); prefix=picked ? "● " : "○ ",
                 prefix_style=tstyle(picked ? :success : :text_dim))
    end for i in matches]
end

function select_model!(menu::Menu)
    isempty(menu.model_matches) && return
    i = menu.model_matches[menu.models.selected]
    menu.model_pick = menu.model_catalog[i].id
    menu.notice = ""
    refresh_models!(menu)
end

function show_features!(menu::Menu)
    menu.page = :features
    prepare_page!(menu)
    refresh_features!(menu)
end

function show_harness_name!(menu::Menu)
    show_input!(menu, :harness_name, isempty(menu.harness_name) ? "juliaforever" : menu.harness_name)
end

function refresh_features!(menu::Menu)
    query = text(menu.search)
    matches = [i for i in eachindex(RECIPES) if
        matches_query(query, RECIPES[i].name, RECIPES[i].description)]
    if matches != menu.matches
        menu.matches = matches
        menu.features.selected = 1
        menu.features.offset = 0
    end
    spinner = SPINNER_BRAILLE[mod1(floor(Int, time() * 4), length(SPINNER_BRAILLE))]
    menu.features.items = [begin
        recipe = RECIPES[i]
        job = menu.builder === nothing ? nothing : get(menu.builder.jobs, recipe.id, nothing)
        prefix = job === nothing ? "[ ]   " : job.state == :running ? "[x] $(spinner) " : job.state == :done ? "[x]   " : "[x] ! "
        prefix_style = job === nothing ? tstyle(:text_dim) : job.state == :running ? tstyle(:accent) :
                       job.state == :done ? tstyle(:success) : tstyle(:error)
        ListItem(recipe.name, tstyle(:text); prefix=prefix, prefix_style=prefix_style)
    end for i in matches]
end

function toggle_feature!(menu::Menu)
    isempty(menu.matches) && return
    i = menu.matches[menu.features.selected]
    id = RECIPES[i].id
    if haskey(menu.builder.jobs, id)
        BuildCore.remove_feature!(menu.builder, id)
    else
        BuildCore.start_feature!(menu.builder, id)
    end
    menu.notice = ""
    refresh_features!(menu)
end

function submit_input!(menu::Menu)
    value = String(strip(text(menu.input)))
    isempty(value) && return
    menu.harness_name = value
    menu.page = :progress
    menu.done_seen = 0.0
    prepare_page!(menu)
    BuildCore.start_finalize!(menu.builder, value)
end

function activate_choice!(menu::Menu)
    i = menu.choices.selected
    if menu.page == :auth
        i == 1 ? show_choices!(menu, :accounts, ACCOUNTS) : show_choices!(menu, :api, API_OPTIONS)
    elseif menu.page == :accounts || menu.page == :api
        menu.source = menu.page == :accounts ? :account : :api
        i == 4 ? show_providers!(menu) : request_auth!(menu, ["openai", "anthropic", "google"][i])
    elseif menu.page == :providers
        provider = menu.choices.items[i].content
        if provider == CONFIGURE_PROVIDER
            menu.provider = ""
            menu.page = :login
            prepare_page!(menu)
        else
            request_auth!(menu, provider)
        end
    end
end

function go_back!(menu::Menu)
    if menu.page == :auth
        menu.quit = true
    elseif menu.page in (:accounts, :api)
        show_choices!(menu, :auth, AUTH_OPTIONS)
    elseif menu.page == :providers
        menu.source == :account ? show_choices!(menu, :accounts, ACCOUNTS) : show_choices!(menu, :api, API_OPTIONS)
    elseif menu.page in (:checking, :login, :models)
        menu.check_token += 1
        menu.source == :account ? show_choices!(menu, :accounts, ACCOUNTS) : show_choices!(menu, :api, API_OPTIONS)
    elseif menu.page == :features
        show_models!(menu)
    elseif menu.page == :harness_name
        show_features!(menu)
    elseif menu.page == :progress
        if menu.builder.final_state in (:building, :alias, :done)
            menu.notice = "Finishing installation…"
        else
            BuildCore.cancel_finalize!(menu.builder)
            show_harness_name!(menu)
        end
    end
end

function continue_page!(menu::Menu)
    menu.notice = ""
    if menu.page in (:auth, :accounts, :api, :providers)
        picked = get(menu.choice_picks, menu.page, 0)
        if picked == 0
            menu.notice = "Select an option to continue."
        else
            menu.choices.selected = picked
            activate_choice!(menu)
        end
    elseif menu.page == :models
        if menu.model_pick === nothing
            menu.notice = "Select a model to continue."
        else
            chosen = menu.model_pick
            if menu.builder !== nothing && (menu.builder.provider != menu.provider || menu.builder.model != chosen)
                if !isempty(menu.builder.jobs)
                    menu.notice = "Deselect features before changing models."
                    return
                end
                BuildCore.cleanup!(menu.builder)
                menu.builder = nothing
            end
            menu.model = chosen
            menu.builder === nothing && (menu.builder = BuildCore.BuildSession(menu.provider, chosen))
            show_features!(menu)
        end
    elseif menu.page == :features
        show_harness_name!(menu)
    elseif menu.page == :harness_name
        if isempty(strip(text(menu.input)))
            menu.notice = "Enter a value to continue."
        else
            submit_input!(menu)
        end
    elseif menu.page == :login
        menu.action = :login
        menu.quit = true
    end
end

function update!(menu::Menu, event::KeyEvent)
    if event.key == :ctrl_c || (event.key == :ctrl && event.char == 'c')
        if menu.page == :progress && menu.builder.final_state in (:building, :alias)
            menu.notice = "Finishing installation…"
        else
            menu.quit = true
        end
        return
    elseif event.key == :escape
        if menu.page == :models && !isempty(text(menu.model_search))
            set_text!(menu.model_search, "")
            refresh_models!(menu)
            set_focus!(menu, :content)
        elseif menu.page == :features && !isempty(text(menu.search))
            set_text!(menu.search, "")
            refresh_features!(menu)
            set_focus!(menu, :content)
        else
            go_back!(menu)
        end
        return
    elseif menu.page in (:progress, :checking)
        return
    elseif event.key in (:tab, :backtab)
        set_focus!(menu, menu.focus == :content ? :continue : :content)
        return
    elseif menu.focus == :continue
        handle_key!(menu.continue_button, event) && continue_page!(menu)
        return
    end

    if menu.page == :harness_name
        if event.key == :ctrl && event.char == 'u'
            set_text!(menu.input, "")
            menu.notice = ""
        elseif handle_key!(menu.input, event)
            menu.notice = ""
        end
    elseif menu.page == :models
        if event.key == :enter
            select_model!(menu)
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
        if event.key == :enter || (event.key == :char && event.char == ' ' && isempty(text(menu.search)))
            toggle_feature!(menu)
        elseif event.key == :ctrl && event.char == 'u'
            set_text!(menu.search, "")
            refresh_features!(menu)
        elseif event.key in (:up, :down, :pageup, :pagedown)
            handle_key!(menu.features, event)
        elseif event.key != :char || length(text(menu.search)) < 128
            handle_key!(menu.search, event)
            refresh_features!(menu)
        end
    elseif menu.page in (:auth, :accounts, :api, :providers)
        if event.key == :enter || (event.key == :char && event.char == ' ')
            select_choice!(menu)
        else
            handle_key!(menu.choices, event)
        end
    end
end

function update!(menu::Menu, event::MouseEvent)
    if handle_mouse!(menu.continue_button, event)
        set_focus!(menu, :continue)
        continue_page!(menu)
        return
    end
    click = event.button == mouse_left && event.action == mouse_press
    if menu.page == :models
        if handle_mouse!(menu.model_search, event)
            set_focus!(menu, :content)
        elseif handle_mouse!(menu.models, event) && click
            set_focus!(menu, :content)
            select_model!(menu)
        end
    elseif menu.page == :features
        if handle_mouse!(menu.search, event)
            set_focus!(menu, :content)
        elseif handle_mouse!(menu.features, event) && click
            set_focus!(menu, :content)
            toggle_feature!(menu)
        end
    elseif menu.page in (:auth, :accounts, :api, :providers)
        if handle_mouse!(menu.choices, event) && click
            set_focus!(menu, :content)
            select_choice!(menu)
        end
    elseif menu.page == :harness_name
        handle_mouse!(menu.input, event) && set_focus!(menu, :content)
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

function footer_lines(area::Rect, parts::String...)
    lines = String[]
    for part in parts
        if !isempty(lines) && textwidth(lines[end] * "  " * part) <= area.width
            lines[end] *= "  " * part
        else
            push!(lines, part)
        end
    end
    lines
end

function button_view!(menu::Menu, frame::Frame, left::Int, y::Int, width::Int)
    area, buffer = frame.area, frame.buffer
    menu.continue_button.last_area = Rect()
    area.y <= y <= bottom(area) || return
    put!(buffer, area, left, y, menu.focus == :continue ? "▸ " : "  ", tstyle(:accent))
    button_width = min(textwidth(menu.continue_button.label) + 4, max(0, width - 2))
    render(menu.continue_button, Rect(left + 2, y, button_width, 1), buffer)
end

function footer_view!(frame::Frame, left::Int, y::Int, lines::Vector{String})
    for (i, line) in enumerate(lines)
        put!(frame.buffer, frame.area, left, y + i - 1, line, tstyle(:text_dim))
    end
end

function list_view!(menu::Menu, frame::Frame, title::String, subtitle::String)
    refresh_choices!(menu)
    area, buffer = frame.area, frame.buffer
    choices = menu.choices
    footers = footer_lines(area, "↑↓ move", "enter select", "tab focus", "enter activate", "esc back")
    rows = min(max(1, area.height - 6 - length(footers)), max(1, length(choices.items)))
    width = max(textwidth(title), textwidth(subtitle), textwidth(menu.notice), maximum(textwidth, footers),
                maximum((textwidth(item.content) + textwidth(item.prefix) + 2 for item in choices.items); init=0))
    left, top, width = position(area, width, rows + 6 + length(footers))
    put!(buffer, area, left, top, title, tstyle(:title, bold=true))
    isempty(subtitle) || put!(buffer, area, left, top + 1, subtitle, tstyle(:text_dim))
    choices.offset = clamp(choices.offset, 0, max(0, length(choices.items) - rows))
    render(choices, Rect(left, top + 2, width, rows), buffer)
    isempty(menu.notice) || put!(buffer, area, left, top + rows + 2, menu.notice, tstyle(:error))
    button_view!(menu, frame, left, top + rows + 4, width)
    footer_view!(frame, left, top + rows + 6, footers)
end

function input_view!(menu::Menu, frame::Frame)
    area, buffer = frame.area, frame.buffer
    footers = footer_lines(area, "tab focus", "enter activate", "ctrl+u clear", "esc back")
    title = "Name your harness:"
    explanation = ["A command is installed in $(BuildCore.bin_dir()).",
                   "Existing commands are never overwritten.",
                   "Generated code is syntax-checked only; review before use.",
                   "Pi tools and generated code use your permissions."]
    status = "$(selected_count(menu)) selected · $(running_count(menu)) building"
    width = max(textwidth(title), maximum(textwidth, footers), textwidth(status),
                textwidth(menu.notice), maximum(textwidth, explanation))
    left, top, width = position(area, width, 13 + length(footers))
    put!(buffer, area, left, top, title, tstyle(:title, bold=true))
    for (i, line) in enumerate(explanation)
        put!(buffer, area, left, top + i, line, tstyle(:text_dim))
    end
    put!(buffer, area, left, top + 6, status, tstyle(:text_dim))
    put!(buffer, area, left, top + 8, "› ", tstyle(:accent))
    render(menu.input, Rect(left + 2, top + 8, max(0, width - 2), 1), buffer)
    isempty(menu.notice) || put!(buffer, area, left, top + 9, menu.notice, tstyle(:error))
    button_view!(menu, frame, left, top + 11, width)
    footer_view!(frame, left, top + 13, footers)
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
    title = "Select a model:"
    subtitle = "Models from Pi · $(menu.provider)"
    i = isempty(menu.model_matches) ? 0 : menu.model_matches[menu.models.selected]
    detail = i == 0 ? "" : "Highlighted: " * menu.model_catalog[i].name
    position_text = i == 0 ? "" : "($(menu.models.selected)/$(length(menu.model_matches)))"
    selected = menu.model_pick === nothing ? "" : "Selected: " * menu.model_pick
    footers = footer_lines(area, "↑↓ move", "enter select", "tab focus", "enter activate", "ctrl+u clear", "esc clear/back")
    rows = min(10, max(1, area.height - 11 - length(footers)), max(1, length(menu.model_catalog)))
    width = max(textwidth(title), textwidth(subtitle), textwidth(detail), textwidth(selected), textwidth(menu.notice),
                maximum(textwidth, footers),
                maximum((textwidth(item.content) + textwidth(item.prefix) + 2 for item in menu.models.items); init=0))
    left, top, width = position(area, width, rows + 11 + length(footers))
    put!(buffer, area, left, top, title, tstyle(:title, bold=true))
    put!(buffer, area, left, top + 1, subtitle, tstyle(:text_dim))
    search_view!(menu.model_search, frame, left, top + 3, width)
    menu.models.offset = clamp(menu.models.offset, 0, max(0, length(menu.models.items) - rows))
    render(menu.models, Rect(left, top + 5, width, rows), buffer)
    isempty(menu.model_matches) && put!(buffer, area, left, top + 5, "No matching models. Configure custom models in Pi.", tstyle(:text_dim))
    put!(buffer, area, left, top + rows + 5, position_text, tstyle(:text_dim))
    put!(buffer, area, left, top + rows + 6, detail, tstyle(:text_dim))
    put!(buffer, area, left, top + rows + 7, isempty(menu.notice) ? selected : menu.notice,
         tstyle(isempty(menu.notice) ? :text_dim : :error))
    button_view!(menu, frame, left, top + rows + 9, width)
    footer_view!(frame, left, top + rows + 11, footers)
end

function features_view!(menu::Menu, frame::Frame)
    refresh_features!(menu)
    query = text(menu.search)
    recipe = isempty(menu.matches) ? nothing : RECIPES[menu.matches[menu.features.selected]]
    job = recipe === nothing || menu.builder === nothing ? nothing : get(menu.builder.jobs, recipe.id, nothing)
    note = recipe === nothing ? "" : job !== nothing && job.state == :failed ?
           "Build failed. Deselect and select to retry." : recipe.description
    status = "$(selected_count(menu)) selected · $(running_count(menu)) building" *
             (isempty(query) ? "" : " · $(length(menu.matches)) matches")
    area, buffer = frame.area, frame.buffer
    footers = footer_lines(area, "↑↓ move", "enter toggle", "tab focus", "enter activate", "ctrl+u clear", "esc clear/back")
    rows = min(max(1, area.height - 7 - length(footers)), length(RECIPES))
    width = max(textwidth("Select features to build:"), maximum(textwidth, footers), textwidth(note), textwidth(status),
                maximum((textwidth(item.content) + textwidth(item.prefix) + 2 for item in menu.features.items); init=0))
    left, top, width = position(area, width, rows + 7 + length(footers))
    put!(buffer, area, left, top, "Select features to build:", tstyle(:title, bold=true))
    search_view!(menu.search, frame, left, top + 1, width)
    menu.features.offset = clamp(menu.features.offset, 0, max(0, length(menu.features.items) - rows))
    render(menu.features, Rect(left, top + 2, width, rows), buffer)
    isempty(menu.matches) && put!(buffer, area, left, top + 2, "No matching features.", tstyle(:text_dim))
    isempty(note) || put!(buffer, area, left, top + rows + 2, note, tstyle(:text_dim))
    put!(buffer, area, left, top + rows + 3, status, tstyle(:text_dim))
    button_view!(menu, frame, left, top + rows + 5, width)
    footer_view!(frame, left, top + rows + 7, footers)
end

function login_view!(menu::Menu, frame::Frame)
    area, buffer = frame.area, frame.buffer
    title = isempty(menu.provider) ? "Configure a provider:" : "Sign in to $(menu.provider):"
    login = isempty(menu.provider) ? "/login" : "/login $(menu.provider)"
    lines = ["Open Pi, run $(login), then exit Pi to return.",
             "Select the requested sign-in method in Pi."]
    footer = "tab focus  enter activate  esc back"
    width = max(textwidth(title), textwidth(footer), textwidth(menu.notice), maximum(textwidth, lines))
    left, top, width = position(area, width, 8)
    put!(buffer, area, left, top, title, tstyle(:title, bold=true))
    for (i, line) in enumerate(lines)
        put!(buffer, area, left, top + i, line, tstyle(:text_dim))
    end
    isempty(menu.notice) || put!(buffer, area, left, top + 4, menu.notice, tstyle(:error))
    button_view!(menu, frame, left, top + 5, width)
    put!(buffer, area, left, top + 7, footer, tstyle(:text_dim))
end

function checking_view!(menu::Menu, frame::Frame)
    area, buffer = frame.area, frame.buffer
    spinner = SPINNER_BRAILLE[mod1(floor(Int, time() * 4), length(SPINNER_BRAILLE))]
    title = "$(spinner) Checking Pi…"
    left, top, _ = position(area, textwidth(title), 3)
    put!(buffer, area, left, top, title, tstyle(:title, bold=true))
    put!(buffer, area, left, top + 2, "esc back", tstyle(:text_dim))
end

function wrap_message(message::String, width::Int)
    lines = String[]
    for word in split(message)
        candidate = isempty(lines) ? String(word) : lines[end] * " " * word
        if !isempty(lines) && textwidth(candidate) <= width
            lines[end] = candidate
        else
            push!(lines, String(word))
        end
    end
    isempty(lines) && push!(lines, "")
    lines
end

function progress_view!(menu::Menu, frame::Frame)
    session = menu.builder
    area, buffer = frame.area, frame.buffer
    completed, total = BuildCore.progress(session)
    state = session.final_state
    eta = BuildCore.estimate(session)
    remaining = state == :failed ? "Build stopped" : eta === nothing ? "Time remaining: learning from history" :
                "Estimated remaining: $(eta)s"
    status = state == :failed ? BuildCore.build_error(session) :
             state == :done ? "Opening your harness…" :
             !isempty(menu.notice) ? menu.notice : "$(completed) of $(total) steps complete"
    jobs = [session.jobs[r.id] for r in RECIPES if haskey(session.jobs, r.id)]
    footer = state == :failed || state == :waiting ? "esc back" : ""
    width = min(area.width, max(50, textwidth("Building your harness:"), textwidth(remaining), textwidth(footer),
                                maximum((textwidth(j.recipe.name) + 4 for j in jobs); init=0)))
    status_lines = wrap_message(status, max(1, width))
    length(status_lines) > max(1, area.height - 9) && resize!(status_lines, max(1, area.height - 9))
    rows = min(length(jobs), max(0, area.height - 8 - length(status_lines)))
    left, top, width = position(area, width, rows + 8 + length(status_lines))
    put!(buffer, area, left, top, "Building your harness:", tstyle(:title, bold=true))
    render(Gauge(completed / total), Rect(left, top + 2, width, 1), buffer)
    put!(buffer, area, left, top + 3, remaining, tstyle(:text_dim))
    spinner = SPINNER_BRAILLE[mod1(floor(Int, time() * 4), length(SPINNER_BRAILLE))]
    for (i, job) in enumerate(jobs[1:rows])
        icon = job.state == :done ? "✓" : job.state == :running ? string(spinner) : "!"
        put!(buffer, area, left, top + 3 + i, "$icon $(job.recipe.name)",
             tstyle(job.state == :done ? :success : job.state == :running ? :accent : :error))
    end
    build_icon = session.build_done ? "✓" : state == :building ? string(spinner) : "○"
    alias_icon = session.alias_done ? "✓" : state == :alias ? string(spinner) : "○"
    put!(buffer, area, left, top + rows + 4, "$build_icon Build harness", tstyle(:text_dim))
    put!(buffer, area, left, top + rows + 5, "$alias_icon Install command", tstyle(:text_dim))
    for (i, line) in enumerate(status_lines)
        put!(buffer, area, left, top + rows + 6 + i, line, tstyle(state == :failed ? :error : :text_dim))
    end
    isempty(footer) || put!(buffer, area, left, top + rows + 7 + length(status_lines), footer, tstyle(:text_dim))
    if state == :done
        menu.done_seen == 0 && (menu.done_seen = time())
        if time() - menu.done_seen >= 1.0
            menu.action = :launch
            menu.quit = true
        end
    end
end

function view(menu::Menu, frame::Frame)
    if menu.page == :auth
        list_view!(menu, frame, "Select authentication method:", "")
    elseif menu.page == :accounts
        list_view!(menu, frame, "Select an account:", "Pi manages sign-in securely.")
    elseif menu.page == :api
        list_view!(menu, frame, "Select an API provider:", "Pi uses its configured credentials and endpoints.")
    elseif menu.page == :providers
        list_view!(menu, frame, "Select a Pi provider:", "Configure custom endpoints in Pi first.")
    elseif menu.page == :login
        login_view!(menu, frame)
    elseif menu.page == :checking
        checking_view!(menu, frame)
    elseif menu.page == :models
        models_view!(menu, frame)
    elseif menu.page == :harness_name
        input_view!(menu, frame)
    elseif menu.page == :features
        features_view!(menu, frame)
    elseif menu.page == :progress
        progress_view!(menu, frame)
    end
end

function main()
    menu = Menu()
    try
        while true
            app(menu; fps=10, default_bindings=false)
            if menu.action == :login
                menu.action = :none
                menu.quit = false
                pi = BuildCore.pi_path()
                if isempty(pi)
                    menu.notice = "Pi is not installed or not on PATH."
                    continue
                end
                login = isempty(menu.provider) ? "/login" : "/login $(menu.provider)"
                println("In Pi, run $login, then exit Pi to return.")
                try
                    run(Cmd([pi, "--no-extensions", "--no-mcp"]))
                catch e
                    menu.notice = sprint(showerror, e)
                end
                isempty(menu.provider) ? show_providers!(menu) : request_auth!(menu, menu.provider)
            elseif menu.action == :launch
                command = menu.builder.command
                BuildCore.cleanup!(menu.builder)
                menu.builder = nothing
                try
                    run(Cmd([command]))
                catch e
                    println(stderr, "Could not open harness: ", sprint(showerror, e))
                    println(stderr, "Run it again with: ", command)
                end
                return
            else
                return
            end
        end
    finally
        menu.check_token += 1
        menu.builder === nothing || BuildCore.cleanup!(menu.builder)
    end
end

end
