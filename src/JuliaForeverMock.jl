module JuliaForeverMock

using Tachikoma
@tachikoma_app

const BACKGROUND = ColorRGB(41, 44, 51)
const ACCENT = ColorRGB(164, 153, 211)
const TEXT = ColorRGB(222, 224, 225)
const MUTED = ColorRGB(158, 165, 169)
const HINT = ColorRGB(128, 136, 141)

const TITLE = "Select authentication method:"
const OPTIONS = ("Sign in with an account", "Sign in with an API key", "Sign in with Radius")
const FOOTER = "↑↓ navigate  enter select  escape/ctrl+c cancel"
const MENU_WIDTH = max(textwidth(TITLE), textwidth(FOOTER), 2 + textwidth(OPTIONS[3] * " • not configured"))

@kwdef mutable struct Menu <: Model
    selected::Int = 1
    feedback::String = ""
    quit::Bool = false
    left::Int = 1
    top::Int = 1
end

should_quit(menu::Menu) = menu.quit

function update!(menu::Menu, event::KeyEvent)
    if event.key == :up
        menu.selected = mod1(menu.selected - 1, length(OPTIONS))
        menu.feedback = ""
    elseif event.key == :down
        menu.selected = mod1(menu.selected + 1, length(OPTIONS))
        menu.feedback = ""
    elseif event.key == :enter
        menu.feedback = menu.selected == 3 ? "Radius is not configured." : "Sign-in is not implemented."
    elseif event.key == :escape || event.key == :ctrl_c || (event.key == :ctrl && event.char == 'c')
        menu.quit = true
    end
end

function update!(menu::Menu, event::MouseEvent)
    if event.button == mouse_left && event.action == mouse_press &&
       menu.left <= event.x < menu.left + MENU_WIDTH && menu.top + 2 <= event.y <= menu.top + 4
        menu.selected = event.y - menu.top - 1
        menu.feedback = ""
    end
end

function view(menu::Menu, frame::Frame)
    area, buffer = frame.area, frame.buffer
    background = Style(bg=BACKGROUND)
    for y in area.y:bottom(area), x in area.x:right(area)
        set_char!(buffer, x, y, ' ', background)
    end

    menu.left = area.x + max(0, (area.width - MENU_WIDTH) ÷ 2)
    menu.top = area.y + max(0, (area.height - 7) ÷ 2)
    left, top = menu.left, menu.top
    bound = right(area)

    set_string!(buffer, left, top, TITLE, Style(fg=ACCENT, bold=true); max_x=bound)
    for (i, label) in enumerate(OPTIONS)
        y = top + i + 1
        selected = i == menu.selected
        selected && set_string!(buffer, left, y, "→", Style(fg=ACCENT); max_x=bound)
        set_string!(buffer, left + 2, y, label, Style(fg=selected ? ACCENT : TEXT); max_x=bound)
        if i == 3
            set_string!(buffer, left + 2 + textwidth(label), y, " • not configured", Style(fg=MUTED); max_x=bound)
        end
    end
    isempty(menu.feedback) || set_string!(buffer, left, top + 5, menu.feedback, Style(fg=MUTED); max_x=bound)
    set_string!(buffer, left, top + 6, FOOTER, Style(fg=HINT); max_x=bound)
end

function main()
    app(Menu(); fps=10, default_bindings=false)
end

end
