module MarkdownScreen

import Markdown, Unicode
import ..LiveTerminal: clean

abstract type Appearance end
struct Plain <: Appearance end
struct Styled <: Appearance end

struct Run
    text::String
    style::String
end
struct Glyph
    text::String
    style::String
    width::Int
end

const bold = "\e[1m"
const italic = "\e[3m"
const underline = "\e[4m"
const strike = "\e[9m"
const code = "\e[36m"
const muted = "\e[2m"

struct Strike
    text::Vector{Any}
end
strikeparse(stream, md) = strikeparse(Markdown.parse_inline_wrapper(stream, "~~"), md)
strikeparse(::Nothing, md) = nothing
strikeparse(text::AbstractString, md) = Strike(Markdown.parseinline(text, md))
Markdown.triggers!(strikeparse, ('~',))

function nestedbold(stream, md)
    Markdown.withstream(stream) do
        Markdown.startswith(stream, "**") || return nothing
        skip(stream, -2)
        start = position(stream)
        source = read(stream, String)
        match = Base.match(r"^\*\*([^*\n]*\*[^*\n]+)\*\*\*", source)
        nestedbold(match, stream, start, md)
    end
end
nestedbold(::Nothing, stream, start, md) = nothing
function nestedbold(match::RegexMatch, stream, start, md)
    seek(stream, start + ncodeunits(match.match))
    Markdown.Bold(Markdown.parseinline(match.captures[1] * "*", md))
end
Markdown.triggers!(nestedbold, ('*',))

function fence(stream, md)
    Markdown.fencedcode(stream, md) && return true
    Markdown.withstream(stream) do
        Markdown.startswith(stream, "~~~", padding=true) || Markdown.startswith(stream, "```", padding=true) || return false
        skip(stream, -1)
        char = read(stream, Char)
        trailing = strip(readline(stream))
        language = lstrip(trailing, char)
        char in language && return false
        text = read(stream, String)
        push!(md, Markdown.Code(language, chomp(text)))
        true
    end
end
Markdown.breaking!(fence)

const flavor = Markdown.config(Markdown.list, Markdown.indentcode, Markdown.blockquote, fence, Markdown.hashheader, Markdown.horizontalrule, Markdown.github_table, Markdown.github_paragraph, Markdown.linebreak, Markdown.escapes, Markdown.inline_code, nestedbold, Markdown.asterisk_bold, Markdown.underscore_bold, Markdown.asterisk_italic, Markdown.underscore_italic, strikeparse, Markdown.image, Markdown.link, Markdown.autolink)

add!(runs, text::AbstractString, style) = (push!(runs, Run(String(text), style)); nothing)
function inline!(runs, values::AbstractVector, style)
    for value in values
        inline!(runs, value, style)
    end
    nothing
end
inline!(runs, text::AbstractString, style) = add!(runs, text, style)
inline!(runs, value::Markdown.Bold, style) = inline!(runs, value.text, style * bold)
inline!(runs, value::Markdown.Italic, style) = inline!(runs, value.text, style * italic)
inline!(runs, value::Strike, style) = inline!(runs, value.text, style * strike)
inline!(runs, value::Markdown.Code, style) = add!(runs, value.code, style * code)
inline!(runs, ::Markdown.LineBreak, style) = add!(runs, "\n", style)
function inline!(runs, value::Markdown.Link, style)
    start = length(runs)
    inline!(runs, value.text, style * underline)
    caption = join(run.text for run in runs[start + 1:end])
    target = replace(value.url, r"^mailto:" => "")
    caption == target || add!(runs, " (" * value.url * ")", style * muted)
    nothing
end
function inline!(runs, value::Markdown.Image, style)
    add!(runs, value.alt, style)
end
inline!(runs, value, style) = add!(runs, string(value), style)

function clusterwidth(cluster)
    if occursin('\u200d', cluster) || occursin('\ufe0f', cluster)
        return max(2, maximum(textwidth, cluster; init=0))
    end
    textwidth(cluster)
end
cellwidth(text) = sum(clusterwidth, Unicode.graphemes(text); init=0)
iscjk(text) = occursin(r"[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]", text)

function glyphs(runs)
    result = Glyph[]
    for run in runs, cluster in Unicode.graphemes(run.text)
        push!(result, Glyph(String(cluster), run.style, clusterwidth(cluster)))
    end
    result
end

function formatted(glyphs, ::Plain)
    join(glyph.text for glyph in glyphs)
end
function formatted(glyphs, ::Styled)
    output = IOBuffer()
    style = ""
    for glyph in glyphs
        if glyph.style != style
            isempty(style) || print(output, "\e[0m")
            style = glyph.style
            print(output, style)
        end
        print(output, glyph.text)
    end
    isempty(style) || print(output, "\e[0m")
    String(take!(output))
end

function addword!(lines, line, spaces, word, width, appearance)
    count = sum(glyph.width for glyph in line; init=0)
    gap = sum(glyph.width for glyph in spaces; init=0)
    size = sum(glyph.width for glyph in word; init=0)
    if !isempty(line) && count + gap + size > width
        push!(lines, formatted(line, appearance))
        empty!(line)
        empty!(spaces)
        count = 0
    end
    for glyph in Iterators.flatten((spaces, word))
        if count > 0 && count + glyph.width > width
            push!(lines, formatted(line, appearance))
            empty!(line)
            count = 0
        end
        if glyph.width <= width
            push!(line, glyph)
            count += glyph.width
        end
    end
    empty!(spaces)
    empty!(word)
    nothing
end

function wrapped(runs, width, appearance)
    width = max(1, width)
    lines = String[]
    line, spaces, word = Glyph[], Glyph[], Glyph[]
    for glyph in glyphs(runs)
        if glyph.text == "\n"
            addword!(lines, line, spaces, word, width, appearance)
            push!(lines, formatted(line, appearance))
            empty!(line)
        elseif all(isspace, glyph.text)
            isempty(word) || addword!(lines, line, spaces, word, width, appearance)
            push!(spaces, glyph)
        elseif iscjk(glyph.text)
            isempty(word) || addword!(lines, line, spaces, word, width, appearance)
            push!(word, glyph)
            addword!(lines, line, spaces, word, width, appearance)
        else
            push!(word, glyph)
        end
    end
    addword!(lines, line, spaces, word, width, appearance)
    push!(lines, formatted(line, appearance))
    lines
end

function inlines(values, width, appearance, style="")
    runs = Run[]
    inline!(runs, values, style)
    wrapped(runs, width, appearance)
end

function blocks(values, width, appearance)
    lines = String[]
    for value in values
        isempty(lines) || push!(lines, "")
        append!(lines, block(value, width, appearance))
    end
    lines
end
block(value::Markdown.Paragraph, width, appearance) = inlines(value.content, width, appearance)
function block(value::Markdown.Header{N}, width, appearance) where N
    prefix = N >= 3 ? repeat("#", N) * " " : ""
    style = bold * (N == 1 ? underline : "")
    inlines(Any[prefix; value.text], width, appearance, style)
end
function block(value::Markdown.Code, width, appearance)
    lines = inlines(["```" * value.language], width, appearance, muted)
    for text in split(value.code, '\n')
        append!(lines, inlines(["  " * text], width, appearance, code))
    end
    append!(lines, inlines(["```"], width, appearance, muted))
    lines
end
function block(value::Markdown.BlockQuote, width, appearance)
    prefix = width >= 3 ? "│ " : ""
    lines = blocks(value.content, max(1, width - textwidth(prefix)), appearance)
    [prefix * line for line in lines]
end
block(::Markdown.HorizontalRule, width, appearance) = [repeat("─", min(width, 80))]

function block(value::Markdown.List, width, appearance)
    list(value, width, appearance, 0)
end
function list(value::Markdown.List, width, appearance, depth)
    lines = String[]
    for (index, item) in enumerate(value.items)
        marker = value.ordered < 0 ? "- " : "$(value.ordered + index - 1). "
        marker = cellwidth(marker) < width ? marker : ""
        prefix = repeat(" ", min(4 * depth, max(0, width - cellwidth(marker) - 1))) * marker
        for (index, child) in enumerate(item)
            listitem!(lines, child, width, appearance, depth, prefix, index)
        end
    end
    lines
end
listitem!(lines, child::Markdown.List, width, appearance, depth, prefix, index) = append!(lines, list(child, width, appearance, depth + 1))
function listitem!(lines, child, width, appearance, depth, prefix, index)
    indent = index == 1 ? prefix : repeat(" ", cellwidth(prefix))
    content = block(child, max(1, width - cellwidth(indent)), appearance)
    for (lineindex, line) in enumerate(content)
        push!(lines, (lineindex == 1 ? indent : repeat(" ", cellwidth(indent))) * line)
    end
    lines
end

function border(widths, left, middle, right)
    left * join((repeat("─", width + 2) for width in widths), middle) * right
end
function tablewidths(rows, width)
    columns = length(first(rows))
    sizes = [maximum(cellwidth(join(g.text for g in glyphs(cell))) for row in rows for cell in row[index:index]; init=1) for index in 1:columns]
    while sum(sizes) + 3 * columns + 1 > width && maximum(sizes) > 1
        index = argmax(sizes)
        sizes[index] -= 1
    end
    sizes
end
function block(value::Markdown.Table, width, appearance)
    rows = [[begin runs = Run[]; inline!(runs, cell, ""); runs end for cell in row] for row in value.rows]
    widths = tablewidths(rows, width)
    if sum(widths) + 3 * length(widths) + 1 > width
        return reduce(vcat, (inlines([join((join(run.text for run in cell) for cell in row), " | ")], width, appearance) for row in rows); init=String[])
    end
    lines = [border(widths, "┌", "┬", "┐")]
    for (index, row) in enumerate(rows)
        cells = [wrapped(cell, size, appearance) for (cell, size) in zip(row, widths)]
        height = maximum(length, cells; init=1)
        for line in 1:height
            parts = String[]
            for (cell, size) in zip(cells, widths)
                text = line <= length(cell) ? cell[line] : ""
                visible = replace(text, r"\e\[[0-9;]*m" => "")
                push!(parts, " " * text * repeat(" ", size - cellwidth(visible) + 1))
            end
            push!(lines, "│" * join(parts, "│") * "│")
        end
        index == length(rows) || push!(lines, border(widths, "├", "┼", "┤"))
    end
    push!(lines, border(widths, "└", "┴", "┘"))
    lines
end
block(value, width, appearance) = inlines([string(value)], width, appearance)

function render(text::AbstractString, width::Integer, appearance::Appearance=Styled())
    parsed = Markdown.parse(clean(text); flavor)
    blocks(parsed.content, max(1, Int(width)), appearance)
end

end
