module CharmStyle

using Tachikoma

@kwdef struct Theme
    indigo::ColorRGB = ColorRGB(0x75, 0x71, 0xf9)
    pink::ColorRGB = ColorRGB(0xf7, 0x80, 0xe2)
    green::ColorRGB = ColorRGB(0x02, 0xcf, 0x92)
    progress_start::ColorRGB = ColorRGB(0x5a, 0x56, 0xe0)
    progress_end::ColorRGB = ColorRGB(0xee, 0x6f, 0xf8)
    text_color::Color256 = Color256(252)
    dim_color::Color256 = Color256(245)
    empty_color::ColorRGB = ColorRGB(0x60, 0x60, 0x60)
    dark_color::ColorRGB = ColorRGB(0x1a, 0x1a, 0x1a)

    title::Style = Style(fg=indigo, bold=true)
    text::Style = Style(fg=text_color)
    dim::Style = Style(fg=dim_color)
    active::Style = Style(fg=green)
    pointer::Style = Style(fg=pink)
    error::Style = Style(fg=ColorRGB(0xff, 0x46, 0x72))
    user_surface::Style = Style(bg=ColorRGB(0x37, 0x30, 0x43))
    tool_surface::Style = Style(bg=ColorRGB(0x2a, 0x35, 0x35))
    user_mark::Style = Style(fg=pink, bold=true)
    agent_mark::Style = Style(fg=indigo, bold=true)
    tool_text::Style = Style(fg=ColorRGB(0xc4, 0xd6, 0xd1))
    tool_dim::Style = Style(fg=ColorRGB(0xa8, 0xba, 0xb5))
    tool_error::Style = Style(fg=ColorRGB(0xff, 0x7d, 0x91))
end

const THEME = Theme()

function text_input(theme::Theme=THEME)
    TextInput(; focused=true, style=theme.text, cursor_style=Style(fg=theme.dark_color, bg=theme.green))
end

function button(label::String, theme::Theme=THEME)
    style = ButtonStyle(; normal=theme.text, focused=Style(fg=theme.dark_color, bg=theme.pink, bold=true))
    Button(label; button_style=style, flash_frames=0)
end

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
            color = color_lerp(THEME.progress_start, THEME.progress_end, t)
            set_char!(buffer, rect.x + col, rect.y, '█', Style(fg=color))
        else
            set_char!(buffer, rect.x + col, rect.y, '░', Style(fg=THEME.empty_color))
        end
    end
    isempty(label) || set_string!(buffer, rect.x + bar_width, rect.y, label, THEME.dim; max_x=right(rect))
end

end
