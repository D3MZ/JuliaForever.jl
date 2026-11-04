module JuliaForever

using Tachikoma
@tachikoma_app

include("ChatGPTAuth.jl")
import .ChatGPTAuth

const AUTH_OPTIONS = ["Sign in with an account", "Sign in with an API key"]
const ACCOUNTS = ["ChatGPT", "Anthropic", "Google", "Other provider"]

list(items) = SelectableList(collect(items); focused=true)

@kwdef mutable struct Menu <: Model
    page::Symbol = :auth
    choices::SelectableList = list(AUTH_OPTIONS)
    picks::Dict{Symbol,Int} = Dict{Symbol,Int}()
    button::Button = Button("Continue")
    focus::Symbol = :content
    notice::String = ""
    flow::Union{Nothing,ChatGPTAuth.Login} = nothing
    quit::Bool = false
end

should_quit(menu::Menu) = menu.quit

function set_focus!(menu::Menu, focus::Symbol)
    menu.focus = focus
    active = focus == :content
    menu.button.focused = !active
    menu.choices.focused = active
    menu.choices.marker = active ? MARKER : ' '
    menu.choices.highlight_style = active ? tstyle(:accent, bold=true) : tstyle(:text)
end

function show_page!(menu::Menu, page::Symbol, options=String[])
    menu.page = page
    menu.notice = ""
    menu.button.label = page in (:connected, :limited) ? "Done" : "Continue"
    menu.button.flash_remaining = 0
    menu.button.last_area = Rect()
    if page in (:auth, :accounts)
        menu.choices = list(options)
        menu.choices.selected = clamp(get(menu.picks, page, 1), 1, length(options))
        set_focus!(menu, :content)
    else
        set_focus!(menu, :continue)
    end
end

function refresh_choices!(menu::Menu)
    picked = get(menu.picks, menu.page, 0)
    menu.choices.items = [ListItem(item.content, tstyle(:text);
                                  prefix=i == picked ? "● " : "○ ",
                                  prefix_style=tstyle(i == picked ? :success : :text_dim))
                          for (i, item) in enumerate(menu.choices.items)]
end

function select_choice!(menu::Menu)
    menu.picks[menu.page] = menu.choices.selected
    menu.notice = ""
end

function continue_page!(menu::Menu)
    menu.notice = ""
    if menu.page in (:auth, :accounts)
        selected = get(menu.picks, menu.page, 0)
        if selected == 0
            menu.notice = "Select an option to continue."
        elseif menu.page == :auth
            selected == 1 ? show_page!(menu, :accounts, ACCOUNTS) :
                            (menu.notice = "API-key sign-in is not available yet.")
        elseif selected != 1
            menu.notice = "This provider is not available yet."
        else
            try
                menu.flow = ChatGPTAuth.start_login()
                show_page!(menu, :waiting)
            catch
                menu.notice = "Could not start ChatGPT sign-in. Please try again."
            end
        end
    elseif menu.page in (:connected, :limited)
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
        show_page!(menu, :accounts, ACCOUNTS)
    else
        menu.quit = true
    end
end

function update!(menu::Menu, event::KeyEvent)
    if event.key == :ctrl_c || (event.key == :ctrl && event.char == 'c')
        menu.quit = true
    elseif event.key == :escape
        go_back!(menu)
    elseif menu.page == :waiting
        return
    elseif event.key in (:tab, :backtab) && menu.page in (:auth, :accounts)
        set_focus!(menu, menu.focus == :content ? :continue : :content)
    elseif menu.focus == :continue
        handle_key!(menu.button, event) && continue_page!(menu)
    elseif event.key == :enter || (event.key == :char && event.char == ' ')
        select_choice!(menu)
    else
        handle_key!(menu.choices, event)
    end
end

function update!(menu::Menu, event::MouseEvent)
    menu.page == :waiting && return
    if handle_mouse!(menu.button, event)
        set_focus!(menu, :continue)
        continue_page!(menu)
        return
    end
    click = event.button == mouse_left && event.action == mouse_press
    if menu.page in (:auth, :accounts) && handle_mouse!(menu.choices, event) && click
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

function button_view!(menu::Menu, frame::Frame, left::Int, top::Int, width::Int)
    menu.button.last_area = Rect()
    frame.area.y <= top <= bottom(frame.area) || return
    put!(frame.buffer, frame.area, left, top, menu.focus == :continue ? "▸ " : "  ", tstyle(:accent))
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
    put!(buffer, area, left, top, title, tstyle(:title, bold=true))
    menu.choices.offset = clamp(menu.choices.offset, 0, max(0, length(menu.choices.items) - rows))
    render(menu.choices, Rect(left, top + 2, width, rows), buffer)
    isempty(menu.notice) || put!(buffer, area, left, top + rows + 2, menu.notice, tstyle(:error))
    button_view!(menu, frame, left, top + rows + 4, width)
    put!(buffer, area, left, top + rows + 6, footer, tstyle(:text_dim))
end

function poll_login!(menu::Menu)
    flow = menu.flow
    flow === nothing && return
    isready(flow.result) || return
    outcome, message = take!(flow.result)
    menu.flow = nothing
    if outcome == :error
        show_page!(menu, :accounts, ACCOUNTS)
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
        put!(buffer, area, left, top, lines[1], tstyle(:title, bold=true))
        put!(buffer, area, left, top + 2, lines[2], tstyle(:text_dim))
        return
    end
    title = menu.page == :connected ? "Signed in to ChatGPT." : "ChatGPT sign-in needs attention."
    lines = [menu.notice, "Credentials are stored locally.", "Model connection comes next."]
    width = max(textwidth(title), maximum(textwidth, lines), textwidth("enter activate  esc exit"))
    left, top, width = position(area, width, 7)
    put!(buffer, area, left, top, title, tstyle(:title, bold=true))
    for (i, line) in enumerate(lines)
        put!(buffer, area, left, top + i, line, tstyle(:text_dim))
    end
    button_view!(menu, frame, left, top + 5, width)
    put!(buffer, area, left, top + 7, "enter activate  esc exit", tstyle(:text_dim))
end

function view(menu::Menu, frame::Frame)
    menu.page == :waiting && poll_login!(menu)
    menu.page in (:auth, :accounts) ? choice_view!(menu, frame) : status_view!(menu, frame)
end

function main()
    menu = Menu()
    try
        app(menu; fps=10, default_bindings=false)
    finally
        menu.flow === nothing || ChatGPTAuth.cancel!(menu.flow)
    end
end

end
