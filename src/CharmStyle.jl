module CharmStyle

using Tachikoma

# Charm's dark form palette and Bubbles' purple-to-pink progress blend.
const INDIGO = ColorRGB(0x75, 0x71, 0xf9)
const PINK = ColorRGB(0xf7, 0x80, 0xe2)
const GREEN = ColorRGB(0x02, 0xcf, 0x92)
const PROGRESS_START = ColorRGB(0x5a, 0x56, 0xe0)
const PROGRESS_END = ColorRGB(0xee, 0x6f, 0xf8)
const TEXT = Color256(252)
const DIM = Color256(245)
const RAIL = Color256(238)
const EMPTY = ColorRGB(0x60, 0x60, 0x60)
const DARK = ColorRGB(0x1a, 0x1a, 0x1a)

const TITLE_STYLE = Style(fg=INDIGO, bold=true)
const TEXT_STYLE = Style(fg=TEXT)
const DIM_STYLE = Style(fg=DIM)
const ACTIVE_STYLE = Style(fg=GREEN)
const POINTER_STYLE = Style(fg=PINK)
const RAIL_STYLE = Style(fg=RAIL)
const ERROR_STYLE = Style(fg=ColorRGB(0xff, 0x46, 0x72))

function text_input()
    TextInput(; focused=true, style=TEXT_STYLE, cursor_style=Style(fg=DARK, bg=GREEN))
end

function button(label::String)
    style = ButtonStyle(; normal=TEXT_STYLE, focused=Style(fg=DARK, bg=PINK, bold=true))
    Button(label; button_style=style, flash_frames=0)
end

"""A real ratio draws a percentage; `nothing` draws an indeterminate loading bar."""
struct Progress
    ratio::Union{Nothing,Float64}
    Progress(ratio::Union{Nothing,Real}) = new(ratio === nothing ? nothing : clamp(Float64(ratio), 0, 1))
end

function Tachikoma.render(progress::Progress, rect::Rect, buffer::Buffer)
    (rect.width < 1 || rect.height < 1) && return
    determinate = progress.ratio !== nothing
    label = determinate ? " " * lpad(string(round(Int, 100 * progress.ratio)), 3) * "%" : ""
    bar_width = max(0, rect.width - textwidth(label))
    filled = determinate ? round(Int, progress.ratio * bar_width) : 0
    segment = min(bar_width, max(3, bar_width ÷ 4))
    phase = floor(Int, time() * 8)
    start = bar_width == 0 ? 0 : mod(phase, bar_width + segment) - segment
    for col in 0:bar_width-1
        active = determinate ? col < filled : start <= col < start + segment
        if active
            t = bar_width <= 1 ? 0.0 : col / (bar_width - 1)
            set_char!(buffer, rect.x + col, rect.y, '█', Style(fg=color_lerp(PROGRESS_START, PROGRESS_END, t)))
        else
            set_char!(buffer, rect.x + col, rect.y, '░', Style(fg=EMPTY))
        end
    end
    isempty(label) || set_string!(buffer, rect.x + bar_width, rect.y, label, DIM_STYLE; max_x=right(rect))
end

end
