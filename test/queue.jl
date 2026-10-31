using Test, JSON3, JuliaForever
import JuliaForever.History as QueueHistory

mutable struct QueueProvider
    started::Channel{Nothing}
    release::Channel{Nothing}
    requests::Vector{Any}
end

function JuliaForever.stream(provider::QueueProvider, messages, tools; parameters=Dict(), on_event=identity)
    push!(provider.requests, deepcopy(messages))
    if length(provider.requests) == 1
        put!(provider.started, nothing)
        take!(provider.release)
    end
    text = "answer"
    on_event((; type=:text, text))
    Completion(Dict{String, Any}("role" => "assistant", "content" => text), nothing, "stop", true, nothing)
end

function queuestart(provider, task)
    @test timedwait(() -> isready(provider.started) || istaskdone(task), 10; pollint=0.01) == :ok
    @test isready(provider.started)
    isready(provider.started) || return false
    take!(provider.started)
    true
end

queuerelease!(provider) = isready(provider.release) || put!(provider.release, nothing)
function queuefinish(provider, task)
    queuerelease!(provider)
    @test timedwait(() -> istaskdone(task), 10; pollint=0.01) == :ok
    istaskdone(task) ? fetch(task) : nothing
end
