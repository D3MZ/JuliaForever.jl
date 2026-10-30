module ContextEstimates

using JSON3
import ..JuliaForever: Usage, Image, Tool, name, description, schema
import ..Conversation

export Estimate, tokens, estimate

"An approximate context size, divided into a reported prefix and estimated tail."
struct Estimate
    total::Int
    reported::Int
    trailing::Int
    index::Union{Nothing, Int}
end

units(::Nothing) = 0
units(text::AbstractString) = sum(char -> 1 + (char > '\uffff'), text; init=0)
units(::Image) = 4800

"Approximate tokens for text or a supported native conversation message."
tokens(text::AbstractString) = cld(2 * units(text), 7)
tokens(message::Conversation.User) = tokens(message.content)
tokens(message::Conversation.SkillContext) = tokens(message.content)
tokens(message::Conversation.ImageUser) = cld(2 * (units(message.content) + sum(units, message.images; init=0)), 7)

attached(::Nothing) = 0
attached(image::Image) = units(image)
attached(::AbstractDict) = 4800

textblock(block) = units(block["text"])
imageblock(block) = 4800
const blocks = Dict("text" => textblock, "input_text" => textblock, "image" => imageblock, "image_url" => imageblock, "input_image" => imageblock)
units(block::AbstractDict) = blocks[block["type"]](block)
units(items::AbstractVector) = sum(units, items; init=0)

systemblock(block) = systemblocks[block["type"]](block)
systemtextblock(block) = (String(block["text"]),)
systemimageblock(block) = ()
const systemblocks = Dict("text" => systemtextblock, "input_text" => systemtextblock, "image" => systemimageblock, "image_url" => systemimageblock, "input_image" => systemimageblock)
systembase(::Nothing) = ""
systembase(text::AbstractString) = String(text)
systembase(blocks::AbstractVector) = join(Iterators.flatten(systemblock.(blocks)), "\n")
sectionvalues(::Nothing) = ()
sectionvalues(sections::AbstractDict) = values(sections)

argument(::Nothing) = 0
argument(text::AbstractString) = units(text)

callunits(call::Conversation.ToolCall) = units(call.name) + argument(call.arguments)
callunits(call::AbstractDict) = functionunits(call["function"])
functionunits(data::AbstractDict) = units(get(data, "name", nothing)) + argument(get(data, "arguments", nothing))

thinking() = 0
thinking(text::AbstractString, rest...) = isempty(text) ? thinking(rest...) : units(text)
thinking(value::Integer) = value
thinking(value, rest...) = thinking(rest...)
anthropicthinking(blocks::AbstractVector) = sum(reasoningblock, blocks; init=0)
anthropicthinking(value) = 0
reasoningblock(block) = 0
reasoningblock(block::AbstractDict) = get(reasoningblocks, get(block, "type", ""), reasoningother)(block)
reasoningother(block) = 0
reasoningtext(block) = units(get(block, "thinking", nothing))
reasoningredacted(block) = units("[Reasoning redacted]")
const reasoningblocks = Dict("thinking" => reasoningtext, "redacted_thinking" => reasoningredacted)
reasoningunits(metadata::AbstractDict) = thinking(get(metadata, "reasoning_content", nothing), get(metadata, "reasoning", nothing), get(metadata, "reasoning_text", nothing), anthropicthinking(get(metadata, "anthropic_content", nothing)))
assistantunits(content, calls, metadata) = units(content) + reasoningunits(metadata) + sum(callunits, calls; init=0)
tokens(message::Conversation.Assistant) = cld(2 * assistantunits(message.content, message.calls, message.metadata), 7)
tokens(message::Conversation.ToolMessage) = cld(2 * (units(message.content) + attached(message.image)), 7)

section!(parts, ::Nothing) = nothing
function section!(parts, text::AbstractString)
    isempty(text) || push!(parts, text)
    nothing
end

function systemtext(data)
    parts = String[]
    section!(parts, systembase(get(data, "content", nothing)))
    foreach(text -> section!(parts, text), sectionvalues(get(data, "sections", nothing)))
    join(parts, "\n\n")
end

tooltokens(::Nothing) = 0
tooltokens(tools::Union{Tuple, AbstractVector}) = isempty(tools) ? 0 : tokens(JSON3.write(tools))
systemtokens(data) = tokens(systemtext(data)) + tooltokens(get(data, "toolsAdded", nothing)) + tooltokens(get(data, "toolsRemoved", nothing))
imageunits(::Nothing) = 0
imageunits(images::Union{Tuple, AbstractVector}) = 4800 * length(images)
usertokens(data) = cld(2 * (units(get(data, "content", nothing)) + imageunits(get(data, "images", nothing))), 7)
toolmessagetokens(data) = cld(2 * (units(get(data, "content", nothing)) + attached(get(data, "image", nothing))), 7)
assistanttokens(data) = cld(2 * assistantunits(get(data, "content", nothing), get(data, "tool_calls", ()), data), 7)
const roles = Dict("system" => systemtokens, "user" => usertokens, "assistant" => assistanttokens, "tool" => toolmessagetokens)
tokens(message::Conversation.RawMessage) = roles[message.value["role"]](message.value)

declaration(tool::Tool) = (; name=name(tool), description=description(tool), parameters=schema(tool))
declared(tools::AbstractDict) = declared(values(tools))
declared(tools) = tooltokens(declaration.(tools))
reported(usage::Usage) = iszero(usage.total) ? usage.input + usage.output + usage.cache_read + usage.cache_write : usage.total

"""
    estimate(messages[, index => usage]; tools=())

Estimate a native conversation. An optional one-based `index => usage` identifies
the message whose prefix the caller knows the provider usage covers. Without it,
every message is estimated; `tools` adds declarations to that unreported prefix.
"""
function estimate(messages::AbstractVector{<:Conversation.Message}; tools=())
    total = sum(tokens, messages; init=0) + declared(tools)
    Estimate(total, 0, total, nothing)
end

function estimate(messages::AbstractVector{<:Conversation.Message}, anchor::Pair{<:Integer, Usage}; tools=())
    index = Int(first(anchor))
    measured(messages, messages[index], index, last(anchor); tools)
end

function measured(messages, ::Conversation.Message, index, usage; tools)
    used = reported(usage)
    used > 0 || return estimate(messages; tools)
    trailing = sum(tokens, @view(messages[index+1:end]); init=0)
    Estimate(used + trailing, used, trailing, index)
end

end
