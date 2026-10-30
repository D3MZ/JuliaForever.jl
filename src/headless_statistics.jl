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
function statistics(session, ::AvailableStatistics)
    totals = Statistics()
    for message in session.messages
        totals.total += 1
        count!(totals, get(roles, message.role, nothing), message)
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
count!(totals, ::User, message) = (totals.user += 1; nothing)
count!(totals, ::Tool, message) = (totals.results += 1; nothing)
const toolblocks = Dict("toolCall" => 1)
function count!(totals, ::Assistant, message)
    totals.assistant += 1
    totals.calls += sum(block -> get(toolblocks, block.type, 0), message.content; init=0)
    countusage!(totals, get(message, :usage, nothing))
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
