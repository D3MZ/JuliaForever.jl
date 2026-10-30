mutable struct Statistics
    user::Int
    assistant::Int
    calls::Int
    results::Int
    total::Int
    input::Int
    output::Int
    cache_read::Int
    cache_write::Int
    cost::Float64
end
Statistics() = Statistics(0, 0, 0, 0, 0, 0, 0, 0, 0, 0.0)

recordprice!(session, ::Nothing) = nothing
recordprice!(session, usage::J.Usage) = recordprice!(session, usage, usage.cost)
recordprice!(session, usage::J.Usage, ::Float64) = nothing
function recordprice!(session, usage::J.Usage, ::Nothing)
    tokens = usage.input + usage.output + usage.cache_read + usage.cache_write
    iszero(tokens) || (session.statistics = UnavailableStatistics())
    nothing
end

statistics(session, ::UnavailableStatistics) = Failure("Complete session usage and pricing are unavailable")
function statistics(session, ::RestoredStatistics)
    totals = lock(session.agent.lock) do
        J.SessionInfo.counts(session.agent, session.store[])
    end
    restoredstatistics(session, totals)
end
restoredstatistics(session, rejected::J.History.Rejected) = Failure("Could not read session statistics: " * String(rejected.reason))
restoredstatistics(session, totals::J.SessionInfo.Counts) = restoredstatistics(session, totals, totals.usage)
restoredstatistics(session, totals, ::J.SessionInfo.UnknownUsage) = Failure("Complete session usage and pricing are unavailable")
restoredstatistics(session, totals, usage::J.SessionInfo.KnownUsage) = restoredstatistics(session, totals, usage, usage.cost)
restoredstatistics(session, totals, usage, ::Nothing) = Failure("Complete session usage and pricing are unavailable")
function restoredstatistics(session, totals, usage, cost::Float64)
    data = Dict{String, Any}(
        "sessionId" => session.id, "userMessages" => totals.user, "assistantMessages" => totals.assistant,
        "toolCalls" => totals.calls, "toolResults" => totals.results, "totalMessages" => totals.total,
        "tokens" => (; input=usage.input, output=usage.output, cacheRead=usage.cache_read, cacheWrite=usage.cache_write, total=usage.input + usage.output + usage.cache_read + usage.cache_write),
        "cost" => cost,
    )
    Success((; data=optional!(data, "sessionFile", sessionfile(session.store[]))))
end
const statisticsroles = Dict("user" => LiveJSON.UserRole(), "assistant" => LiveJSON.AssistantRole(), "toolResult" => LiveJSON.ToolRole())
function statistics(session, ::AvailableStatistics)
    totals = Statistics()
    for message in session.messages
        totals.total += 1
        count!(totals, get(statisticsroles, message["role"], nothing), message)
    end
    data = Dict{String, Any}(
        "sessionId" => session.id, "userMessages" => totals.user, "assistantMessages" => totals.assistant,
        "toolCalls" => totals.calls, "toolResults" => totals.results, "totalMessages" => totals.total,
        "tokens" => (; input=totals.input, output=totals.output, cacheRead=totals.cache_read, cacheWrite=totals.cache_write, total=totals.input + totals.output + totals.cache_read + totals.cache_write),
        "cost" => totals.cost,
    )
    Success((; data=optional!(data, "sessionFile", sessionfile(session.store[]))))
end

count!(totals, role, message) = nothing
count!(totals, ::LiveJSON.UserRole, message) = (totals.user += 1; nothing)
count!(totals, ::LiveJSON.ToolRole, message) = (totals.results += 1; nothing)
const toolblocks = Dict("toolCall" => 1)
function count!(totals, ::LiveJSON.AssistantRole, message)
    totals.assistant += 1
    totals.calls += sum(block -> get(toolblocks, block["type"], 0), message["content"]; init=0)
    countusage!(totals, get(message, "usage", nothing))
end
countusage!(totals, ::Nothing) = nothing
function countusage!(totals, usage)
    totals.input += usage.input
    totals.output += usage.output
    totals.cache_read += usage.cacheRead
    totals.cache_write += usage.cacheWrite
    totals.cost += usage.cost.total
    nothing
end
