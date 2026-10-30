abstract type ThinkingChoices end
struct FixedThinking <: ThinkingChoices end
struct ReasoningChoices <: ThinkingChoices
    levels::Vector{String}
    efforts::Dict{String, String}
    wire::Union{J.DirectThinking, J.UpdateThinking}
end

const thinkinglevels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]

function reasoningchoices(levels::AbstractDict)
    entries = Pair{String, String}[]
    wire = J.thinkingwire(levels)
    for level in thinkinglevels
        addeffort!(entries, level, get(levels, level, nothing), wire)
    end
    reasoningchoices(entries, wire)
end
reasoningchoices(entries::Vector{Pair{String, String}}, wire::J.ThinkingWire) = isempty(entries) ? FixedThinking() : ReasoningChoices(first.(entries), Dict(entries), wire)
addeffort!(entries, level, ::Nothing, wire::J.ThinkingWire) = nothing
addeffort!(entries, level, effort::AbstractString, wire::J.ThinkingWire) = addeffort!(entries, level, effort, J.supportedthinking(wire, effort))
addeffort!(entries, level, effort::AbstractString, ::J.Models.InvalidConfig) = nothing
addeffort!(entries, level, effort::AbstractString, ::J.Models.ValidConfig) = (push!(entries, level => String(effort)); nothing)

const responsechoices = Dict{String, Union{FixedThinking, ReasoningChoices}}(name => reasoningchoices(levels) for (name, levels) in J.responselevels)
const googlechoices = Dict{String, Union{FixedThinking, ReasoningChoices}}(name => reasoningchoices(delete!(copy(levels), "off")) for (name, levels) in J.googlelevels)
const emptychoices = Dict{String, Union{FixedThinking, ReasoningChoices}}()
const thinkingcatalogs = Dict("openai" => responsechoices, "google" => googlechoices)
thinkingchoices(provider) = FixedThinking()
thinkingchoices(provider::J.Google) = googlethinkingchoices(provider.route, provider.model)
googlethinkingchoices(::J.DirectRoute, model) = get(googlechoices, model, FixedThinking())
googlethinkingchoices(route::J.CatalogRoute, model) = catalogchoices(get(route.registry.providers, route.name, nothing), route.name, model)
thinkingchoices(provider::J.OpenAIResponses) = permittedchoices(provider, thinkingchoices(provider.route, provider.model))
thinkingchoices(::J.DirectRoute, model) = get(responsechoices, model, FixedThinking())
thinkingchoices(route::J.CatalogRoute, model) = catalogchoices(get(route.registry.providers, route.name, nothing), route.name, model)
catalogchoices(settings, name, model) = FixedThinking()
catalogchoices(::Nothing, name, model) = get(get(thinkingcatalogs, name, emptychoices), model, FixedThinking())
permittedchoices(provider, choices::FixedThinking) = choices
permittedchoices(provider, choices::ReasoningChoices) = permittedchoices(provider, choices, choices.wire)
permittedchoices(provider, choices::ReasoningChoices, ::J.DirectThinking) = choices
function permittedchoices(provider, choices::ReasoningChoices, wire::J.UpdateThinking)
    entries = Pair{String, String}[]
    for level in choices.levels
        effort = choices.efforts[level]
        addeffort!(entries, level, effort, J.authorizedthinking(wire, provider, effort))
    end
    reasoningchoices(entries, wire)
end

levels(::FixedThinking) = ["off"]
levels(choices::ReasoningChoices) = choices.levels
defaultthinking(::FixedThinking) = "off"
defaultthinking(choices::ReasoningChoices) = "medium" in choices.levels ? "medium" : first(choices.levels)
requestedthinking(choices, ::Nothing) = defaultthinking(choices)
requestedthinking(choices, level::String) = level

clampthinking(level, available) = clampthinking(findfirst(isequal(level), thinkinglevels), available)
clampthinking(::Nothing, available) = first(available)
function clampthinking(index::Int, available)
    for level in @view thinkinglevels[index:end]
        if level in available
            return level
        end
    end
    last(available)
end

function initialthinking!(agent, requested)
    choices = thinkingchoices(agent.provider)
    level = clampthinking(requestedthinking(choices, requested), levels(choices))
    applylevel!(agent, choices, level)
    level
end
applylevel!(agent, ::FixedThinking, level) = nothing
function applylevel!(agent, choices::ReasoningChoices, level)
    lock(agent.lock) do
        agent.provider = J.applythinking(agent.provider, choices.efforts[level])
    end
    nothing
end

handle!(session, ::GetThinkingLevels) = Success((; data=(; levels=levels(thinkingchoices(session.agent.provider)))))
handle!(session, command::SetThinking) = setthinking!(session, command.level)
handle!(session, ::CycleThinking) = cyclethinking!(session, thinkingchoices(session.agent.provider))
cyclethinking!(session, ::FixedThinking) = Success((; data=nothing))
function cyclethinking!(session, choices::ReasoningChoices)
    index = something(findfirst(isequal(session.thinking), choices.levels), 0)
    level = choices.levels[mod1(index + 1, length(choices.levels))]
    cycleresult(setthinking!(session, level), level)
end
cycleresult(::Success, level) = Success((; data=(; level)))
cycleresult(failure::Failure, level) = failure

function setthinking!(session, requested)
    lock(session.lock) do
        choices = thinkingchoices(session.agent.provider)
        level = clampthinking(requested, levels(choices))
        changethinking!(session, choices, level)
    end
end
function changethinking!(session, choices, level)
    level == session.thinking && return Success()
    saved = recordentry!(session, J.Conversation.ThinkingEntry(level))
    thinkingrecorded!(session, choices, level, saved)
end
thinkingrecorded!(session, choices, level, rejected::J.History.Rejected) = Failure(string(rejected.reason))
function thinkingrecorded!(session, choices, level, ::Nothing)
    applylevel!(session.agent, choices, level)
    session.thinking = level
    write!(session, (; type="thinking_level_changed", level))
    Success()
end

entrythinking(level, entry) = level
entrythinking(level, entry::J.Conversation.SessionRecord{J.Conversation.ThinkingEntry}) = entry.entry.level
restorethinking!(session, level::String) = nothing
function restorethinking!(session, ::Nothing)
    isempty(session.messages) && return nothing
    choices = thinkingchoices(session.agent.provider)
    level = clampthinking(foldl(entrythinking, session.entries; init=session.thinking), levels(choices))
    applylevel!(session.agent, choices, level)
    session.thinking = level
    nothing
end
