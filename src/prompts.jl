module Prompts

import YAML

const command = r"\A/([^\s]+)(?:\s+([\s\S]*))?\z"
const word = r"(?:[^\s\"']+|\"[^\"]*\"?|'[^']*'?)+"
const fragment = r"([^\"']+)|\"([^\"]*)\"?|'([^']*)'?"
const placeholder = r"\$\{(\d+|ARGUMENTS|@):-([^}]*)\}|\$\{@:(\d+)(?::(\d+))?\}|\$(ARGUMENTS|@|\d+)"
const frontmatter = r"\A---(.*?)\n---(.*)\z"s

function body(raw)
    text = replace(String(chopprefix(raw, "\ufeff")), "\r\n" => "\n", '\r' => '\n')
    body(text, match(frontmatter, text))
end

body(text, ::Nothing) = text

function body(text, match::RegexMatch)
    header = String(something(match[1], ""))
    header = chop(header; head=min(1, length(header)), tail=0)
    try
        isempty(header) || YAML.load(header)
    catch
        return nothing
    end
    String(strip(something(match[2], "")))
end

function load!(templates, path, ::Nothing)
    @warn "Skipping invalid prompt template" path
    templates
end

function load!(templates, dir, content::AbstractString)
    get!(templates, splitext(basename(dir))[1], String(content))
    templates
end

function load!(templates, dir)
    isdir(dir) || return templates
    for path in readdir(dir; join=true)
        isfile(path) && endswith(path, ".md") || continue
        load!(templates, path, body(read(path, String)))
    end
    templates
end

function load(cwd=pwd(); agentdir=get(ENV, "PI_CODING_AGENT_DIR", joinpath(homedir(), ".pi", "agent")))
    templates = Dict{String, String}()
    load!(templates, joinpath(abspath(expanduser(agentdir)), "prompts"))
    load!(templates, joinpath(abspath(expanduser(cwd)), ".pi", "prompts"))
end

function arguments(text)
    String[join(something(part[1], part[2], part[3], "") for part in eachmatch(fragment, token.match)) for token in eachmatch(word, text)]
end

number(text) = something(tryparse(Int, text), typemax(Int))
value(args, target) = value(args, match(r"\A\d+\z", target), target)
value(args, ::Nothing, target) = join(args, " ")
value(args, ::RegexMatch, target) = get(args, number(target), "")

function substitution(target::AbstractString, fallback::AbstractString, ::Nothing, ::Nothing, ::Nothing, args)
    result = value(args, target)
    isempty(result) ? String(fallback) : result
end

function substitution(::Nothing, ::Nothing, start::AbstractString, count, ::Nothing, args)
    first = clamp(number(start), 1, length(args) + 1)
    size = min(length(args) - first + 1, number(something(count, string(typemax(Int)))))
    join(view(args, first:first + size - 1), " ")
end

substitution(::Nothing, ::Nothing, ::Nothing, ::Nothing, target::AbstractString, args) = value(args, target)

function substitution(text, args)
    match = something(Base.match(placeholder, text))
    substitution(match[1], match[2], match[3], match[4], match[5], args)
end

expand(text, ::Nothing, templates) = text

function expand(text, match::RegexMatch, templates)
    template = get(templates, something(match[1], ""), nothing)
    expand(text, template, something(match[2], ""))
end

expand(text, ::Nothing, args::AbstractString) = text

function expand(text, template::String, input::AbstractString)
    args = arguments(input)
    replace(template, placeholder => token -> substitution(token, args))
end

expand(text::AbstractString, templates::AbstractDict) = expand(text, match(command, text), templates)

end
