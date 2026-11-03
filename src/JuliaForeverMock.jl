module JuliaForeverMock

using Tachikoma
@tachikoma_app

const TITLE = "Select authentication method:"
const OPTIONS = ("Sign in with an account", "Sign in with an API key")
const FOOTER = "↑↓ navigate  enter select  escape/ctrl+c cancel"
const MENU_WIDTH = max(textwidth(TITLE), textwidth(FOOTER), 2 + maximum(textwidth, OPTIONS))
const MENU_HEIGHT = length(OPTIONS) + 4

@kwdef mutable struct Menu <: Model
    choices::SelectableList = SelectableList(collect(OPTIONS); focused=true)
    feedback::String = ""
    quit::Bool = false
end

should_quit(menu::Menu) = menu.quit

function update!(menu::Menu, event::KeyEvent)
    if event.key == :enter
        menu.feedback = "Sign-in is not implemented."
    elseif event.key == :escape || event.key == :ctrl_c || (event.key == :ctrl && event.char == 'c')
        menu.quit = true
    elseif handle_key!(menu.choices, event)
        menu.feedback = ""
    end
end

function update!(menu::Menu, event::MouseEvent)
    handle_mouse!(menu.choices, event) && (menu.feedback = "")
end

function view(menu::Menu, frame::Frame)
    area, buffer = frame.area, frame.buffer
    left = area.x + max(0, (area.width - MENU_WIDTH) ÷ 2)
    top = area.y + max(0, (area.height - MENU_HEIGHT) ÷ 2)
    bound = right(area)

    set_string!(buffer, left, top, TITLE, tstyle(:title, bold=true); max_x=bound)
    render(menu.choices, Rect(left, top + 2, min(MENU_WIDTH, area.width), length(OPTIONS)), buffer)
    isempty(menu.feedback) || set_string!(buffer, left, top + length(OPTIONS) + 2, menu.feedback, tstyle(:text_dim); max_x=bound)
    set_string!(buffer, left, top + MENU_HEIGHT - 1, FOOTER, tstyle(:text_dim); max_x=bound)
end

function main()
    app(Menu(); fps=10, default_bindings=false)
end

end
