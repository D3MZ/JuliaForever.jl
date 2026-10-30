function markdowncontent(io, text)
    document = Markdown.parse(text; flavor=:github)
    print(io, "<div class=\"markdown\">")
    markdownblocks(io, document.content)
    print(io, "</div>")
    nothing
end

function markdownblocks(io, blocks)
    for block in blocks
        markdownblock(io, block)
        print(io, '\n')
    end
end
markdownblock(io, block) = print(io, "<pre>", escape(Markdown.plain(block)), "</pre>")
function markdownblock(io, block::Markdown.Paragraph)
    print(io, "<p>")
    markdowninlines(io, block.content)
    print(io, "</p>")
end
function markdownblock(io, block::Markdown.Header{level}) where level
    print(io, "<h", level, ">")
    markdowninlines(io, block.text)
    print(io, "</h", level, ">")
end
markdownblock(io, block::Markdown.Code) = print(io, "<pre><code>", escape(block.code), "</code></pre>")
function markdownblock(io, block::Markdown.BlockQuote)
    print(io, "<blockquote>")
    markdownblocks(io, block.content)
    print(io, "</blockquote>")
end
function markdownblock(io, block::Markdown.Footnote)
    print(io, "<aside><strong>[", escape(block.id), "]</strong> ")
    markdownblocks(io, block.text)
    print(io, "</aside>")
end
function markdownblock(io, block::Markdown.List)
    tag = Markdown.isordered(block) ? "ol" : "ul"
    start = block.ordered > 1 ? " start=\"$(block.ordered)\"" : ""
    print(io, "<", tag, start, ">")
    for item in block.items
        print(io, "<li>")
        markdownblocks(io, item)
        print(io, "</li>")
    end
    print(io, "</", tag, ">")
end
function markdownblock(io, block::Markdown.Table)
    print(io, "<table><thead><tr>")
    markdowncells(io, first(block.rows), "th")
    print(io, "</tr></thead><tbody>")
    for row in Iterators.drop(block.rows, 1)
        print(io, "<tr>")
        markdowncells(io, row, "td")
        print(io, "</tr>")
    end
    print(io, "</tbody></table>")
end
function markdowncells(io, row, tag)
    for cell in row
        print(io, "<", tag, ">")
        markdowninlines(io, cell)
        print(io, "</", tag, ">")
    end
end
markdownblock(io, ::Markdown.HorizontalRule) = print(io, "<hr>")

markdowninlines(io, content) = foreach(item -> markdowninline(io, item), content)
markdowninline(io, value) = print(io, escape(Markdown.plain(value)))
markdowninline(io, text::AbstractString) = print(io, escape(text))
function markdowninline(io, value::Markdown.Bold)
    print(io, "<strong>")
    markdowninlines(io, value.text)
    print(io, "</strong>")
end
function markdowninline(io, value::Markdown.Italic)
    print(io, "<em>")
    markdowninlines(io, value.text)
    print(io, "</em>")
end
markdowninline(io, value::Markdown.Code) = print(io, "<code>", escape(value.code), "</code>")
markdowninline(io, value::Markdown.Image) = print(io, escape(value.alt))
markdowninline(io, value::Markdown.Footnote) = print(io, "<sup>[", escape(value.id), "]</sup>")
markdowninline(io, ::Markdown.LineBreak) = print(io, "<br>")
function markdowninline(io, value::Markdown.Link)
    url = strip(value.url)
    markdownlink(io, value, url, match(r"(?i)^https?://", url))
end
markdownlink(io, value, url, ::Nothing) = markdowninlines(io, value.text)
function markdownlink(io, value, url, ::RegexMatch)
    print(io, "<a href=\"", escape(url), "\" rel=\"noreferrer noopener\">")
    markdowninlines(io, value.text)
    print(io, "</a>")
    nothing
end
