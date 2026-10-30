using JSON3

mutable struct ShellProvider
    replies::Vector{Any}
end

JuliaForever.complete(provider::ShellProvider, messages, tools) = popfirst!(provider.replies)

function shellreply(commands)
    calls = [Dict("id" => "shell-$i", "type" => "function", "function" => Dict("name" => "bash", "arguments" => JSON3.write((; command)))) for (i, command) in enumerate(commands)]
    Dict("role" => "assistant", "content" => nothing, "tool_calls" => calls)
end

@testset "agent shell cancellation" begin
    if !Sys.iswindows()
        for (mode, recorded) in ((:sequential, false), (:parallel, false), (:sequential, true))
            mktempdir() do dir
                count = mode == :parallel ? 2 : 1
                commands = [shellfixture(dir, i) for i in 1:count]
                provider = ShellProvider(Any[shellreply(commands), Dict("role" => "assistant", "content" => "continued")])
                history = recorded ? JuliaForever.History.Memory() : nothing
                agent = Agent(provider, [Bash(dir)]; history)
                task = Threads.@spawn respond!(agent, "run"; tool_execution=mode)
                pids = Vector{Int}[]
                try
                    ready = timedwait(() -> all(i -> isfile(joinpath(dir, "ready-$i")), 1:count), 10)
                    @test ready == :ok
                    if ready == :ok
                        pids = [shellpids(dir, i) for i in 1:count]
                        @test cancel!(agent) === true
                        finished = timedwait(() -> istaskdone(task), 4)
                        @test finished == :ok
                        if finished != :ok
                            foreach(ids -> ccall(:kill, Cint, (Cint, Cint), -first(ids), 9), pids)
                        end
                        @test fetch(task) == :cancelled
                        @test timedwait(() -> all(ids -> all(gone, ids) && gone(-first(ids)), pids), 5) == :ok
                        messages = [message for message in agent.messages if message["role"] == "tool"]
                        @test length(messages) == count
                        @test all(message -> occursin("Command aborted", message["content"]), messages)
                        @test all(i -> !isfile(joinpath(dir, "late-$i")), 1:count)
                        @test respond!(agent, "continue") == "continued"
                        if recorded
                            restored = Agent(provider, [Bash(dir)]; history)
                            @test restored.messages == agent.messages
                        end
                    end
                finally
                    if !istaskdone(task)
                        cancel!(agent)
                        if timedwait(() -> istaskdone(task), 1) != :ok
                            foreach(ids -> ccall(:kill, Cint, (Cint, Cint), -first(ids), 9), pids)
                        end
                    end
                    wait(task)
                end
            end
        end
    end
end

@testset "streamed shell cancellation reaches plugin listeners" begin
    if !Sys.iswindows()
        mktempdir() do dir
            registry = JuliaForever.Extensions.Registry()
            seen = Symbol[]
            JuliaForever.Extensions.register!(registry, :observer, JuliaForever.Extensions.Plugin(; hooks=(:tool_execution_update => (event -> push!(seen, event.type)), :tool_execution_end => (event -> push!(seen, event.type)))))
            provider = ShellProvider(Any[shellreply(["printf ready; sleep 30"]), Dict("role" => "assistant", "content" => "continued")])
            agent = Agent(provider, JuliaForever.Extensions.snapshot(registry))
            agent.tools["bash"] = Bash(dir)
            events = Any[]
            listener = JuliaForever.Extensions.listen(JuliaForever.Extensions.snapshot(registry); on_event=event -> begin
                push!(events, event)
                event.type == :tool_execution_update && occursin("ready", event.partial_result.text) && cancel!(agent)
            end)
            @test respond!(agent, "run"; on_agent_event=listener) == :cancelled
            @test :tool_execution_update in seen
            @test last(seen) == :tool_execution_end
            @test any(event -> event.type == :tool_execution_end && event.result.iserror, events)
            @test isempty(JuliaForever.Extensions.failures(listener))
        end
    end
end
