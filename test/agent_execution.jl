using Test, Distributed, JuliaForever, Serialization, HTTP, JSON3

import JuliaForever.Execution as AE
import JuliaForever.Conversation as AC
import JuliaForever.Kernel as AK
import JuliaForever.History as AH

include("agent_execution_cases.jl")
const AEC = AgentExecutionCases

function agent_execution(pid)
    mktempdir() do dir
        requests = RemoteChannel(() -> Channel{Any}(16))
        started = RemoteChannel(() -> Channel{Int}(2))
        release = RemoteChannel(() -> Channel{Nothing}(2))
        context = "agent-execution-$pid"
        @test remotecall_fetch(AEC.install, pid, context, dir, requests, started, release)
        pool = AE.Executor(pid; capacity=1)
        try
            agent = Agent(nothing, [])
            events = []
            result = respond!(agent, "two"; executor=pool, context, on_agent_event=event -> begin
                push!(events, event)
                event.type == :tool_execution_start && event.tool_call_id == "one" && JuliaForever.steer!(agent, "steer")
                event.type == :tool_execution_end && @test agent.state.phase == AC.WaitingTools
            end)
            @test result isa AE.Turn && result.value == "done"
            @test length(result.models) == 2 && all(model -> isnothing(model.usage), result.models)
            @test read(joinpath(dir, "a.txt"), String) == "hello"
            @test [message["role"] for message in agent.messages] == ["user", "assistant", "tool", "tool", "user", "assistant"]
            @test startswith(agent.messages[4]["content"], "Error:")
            @test [event.type for event in events] == [:agent_start, :turn_start, :message_start, :message_end, :message_start, :message_end, :tool_execution_start, :tool_execution_end, :message_start, :message_end, :tool_execution_start, :tool_execution_end, :message_start, :message_end, :turn_end, :turn_start, :message_start, :message_end, :message_start, :message_end, :turn_end, :agent_end]
            first = take!(requests)
            second = take!(requests)
            @test first.worker == second.worker == pid
            @test first.parameters == Dict("temperature" => 0.2)
            @test second.messages[2]["response_output"][1]["encrypted_content"] == "synthetic-encrypted"
            @test [message["content"] for message in second.messages if message["role"] == "user"] == ["two", "steer"]
            @test [message["tool_call_id"] for message in second.messages if message["role"] == "tool"] == ["one", "two"]
            before = read(joinpath(dir, "a.txt"), String)
            rm(joinpath(dir, "a.txt"))
            replay = collect(AK.Replay(agent.initial, agent.events))
            @test last(replay).state.phase == AC.Complete
            @test before == "hello" && !isfile(joinpath(dir, "a.txt"))
            @test !isready(requests)
            bytes = IOBuffer()
            serialize(bytes, (agent.initial, agent.events))
            @test !occursin("fixture-secret", String(take!(bytes)))

            agent = Agent(nothing, [])
            @test respond!(agent, "length"; executor=pool, context).value == "done"
            @test !isfile(joinpath(dir, "a.txt"))
            take!(requests)
            @test occursin("output token limit", last(take!(requests).messages)["content"])

            agent = Agent(nothing, [])
            @test respond!(agent, "fail"; executor=pool, context).value == AE.Rejected(:provider_failure)
            @test agent.state.phase == AC.Incomplete
            @test !occursin("fixture-secret", repr(agent.events))
            take!(requests)

            agent = Agent(nothing, [])
            usage = respond!(agent, "usage"; executor=pool, context)
            @test usage.value == "done"
            @test only(usage.models).usage.total == 2
            @test agent.state.phase == AC.Complete
            take!(requests)

            for prompt in ("error-metadata", "incomplete")
                agent = Agent(nothing, [])
                partial = respond!(agent, prompt; executor=pool, context)
                @test partial.value == AE.Rejected(:incomplete_model)
                @test only(partial.models).error == (prompt == "error-metadata" ? "private error detail" : nothing)
                @test agent.state.phase == AC.Incomplete
                @test !isfile(joinpath(dir, "a.txt"))
                @test last(collect(AK.Replay(agent.initial, agent.events))).state.phase == AC.Incomplete
                take!(requests)
            end

            agent = Agent(nothing, [])
            @test respond!(agent, "x"; executor=pool, context, on_event=identity) == AE.Rejected(:streaming)
            @test respond!(agent, "x"; executor=pool, context, tool_execution=:parallel) == AE.Rejected(:parallel_tools)
            @test respond!(agent, "x"; executor=pool, context, parameters=Dict("x" => 1)) == AE.Rejected(:parameters)
            @test respond!(agent, "x"; executor=pool) == AE.Rejected(:context)
            @test respond!(agent, "x"; context) == AE.Rejected(:executor)
            @test isempty(agent.events) && !isready(requests)

            missing = Agent(nothing, [])
            outcome = respond!(missing, "x"; executor=pool, context="missing-context")
            @test outcome.value isa AE.Failed
            @test outcome.value.worker == pid
            @test missing.state.phase == AC.Incomplete
            @test last(collect(AK.Replay(missing.initial, missing.events))).state.phase == AC.Incomplete

            agent = Agent(nothing, [])
            active = @async respond!(agent, "block"; executor=pool, context)
            @test take!(started) == pid
            @test JuliaForever.cancel!(agent)
            put!(release, nothing)
            cancelled = fetch(active)
            @test cancelled.value == :cancelled
            @test length(cancelled.models) == 1
            @test !isfile(joinpath(dir, "a.txt"))
            @test occursin("cancelled", last(agent.messages)["content"])
            @test agent.state.phase == AC.Cancelled
            @test last(collect(AK.Replay(agent.initial, agent.events))).state.phase == AC.Cancelled
            take!(requests)

            pending = only(AK.step(AC.State("occupy"), AC.Input(0, "block")).effects)
            blocker = AE.submit!(pool, pending, 1, context)
            @test take!(started) == pid
            filler = only(AK.step(AC.State("filler"), AC.Input(0, "filler")).effects)
            waiting = AE.submit!(pool, filler, 1, context)
            agent = Agent(nothing, [])
            queued = @async respond!(agent, "two"; executor=pool, context)
            @test timedwait(() -> lock(() -> !isnothing(agent.handle), agent.lock), 10) == :ok
            @test !istaskdone(queued) && isready(pool.queue)
            @test JuliaForever.cancel!(agent)
            put!(release, nothing)
            @test fetch(blocker) isa AE.Completed
            @test fetch(waiting) isa AE.Completed
            @test fetch(queued).value == :cancelled
            @test agent.state.phase == AC.Cancelled
            @test !isfile(joinpath(dir, "a.txt"))
            take!(requests)
            take!(requests)
            @test !isready(requests)

            agent = Agent(nothing, [])
            @test_throws ErrorException respond!(agent, "two"; executor=pool, context, on_agent_event=event -> event.type == :tool_execution_start && error("callback failure"))
            @test agent.state.phase == AC.Incomplete && !agent.running
            @test last(collect(AK.Replay(agent.initial, agent.events))).state.phase == AC.Incomplete
            @test !isfile(joinpath(dir, "a.txt"))
            take!(requests)
        finally
            close(pool)
            remotecall_wait(AE.uninstall!, pid, context)
        end
    end
end

@testset "worker loss leaves an uncertain interrupted effect" begin
    project = dirname(@__DIR__)
    pid = only(addprocs(1; exeflags=`--startup-file=no --project=$project`))
    pool = AE.Executor(pid; capacity=1)
    try
        remotecall_wait(Core.eval, pid, Main, :(using JuliaForever))
        remotecall_wait(Base.include, pid, Main, joinpath(@__DIR__, "agent_execution_cases.jl"))
        mktempdir() do dir
            requests = RemoteChannel(() -> Channel{Any}(4))
            started = RemoteChannel(() -> Channel{Int}(1))
            release = RemoteChannel(() -> Channel{Nothing}(1))
            context = "agent-crash-$pid"
            @test remotecall_fetch(AEC.install, pid, context, dir, requests, started, release)
            agent = Agent(nothing, [])
            active = @async respond!(agent, "block"; executor=pool, context)
            @test take!(started) == pid
            rmprocs(pid)
            @test timedwait(() -> istaskdone(active), 15) == :ok
            result = fetch(active)
            @test result.value isa AE.Failed
            @test result.value.worker == pid
            @test agent.state.phase == AC.Incomplete && !agent.running
            @test last(collect(AK.Replay(agent.initial, agent.events))).state.phase == AC.Incomplete
            @test !isfile(joinpath(dir, "a.txt"))
        end
    finally
        close(pool)
        pid in workers() && rmprocs(pid)
    end
end

@testset "worker loss after a tool effect is not reported as a tool result" begin
    project = dirname(@__DIR__)
    pid = only(addprocs(1; exeflags=`--startup-file=no --project=$project`))
    pool = AE.Executor(pid; capacity=1)
    try
        remotecall_wait(Core.eval, pid, Main, :(using JuliaForever))
        remotecall_wait(Base.include, pid, Main, joinpath(@__DIR__, "agent_execution_cases.jl"))
        mktempdir() do dir
            requests = RemoteChannel(() -> Channel{Any}(4))
            started = RemoteChannel(() -> Channel{Int}(1))
            release = RemoteChannel(() -> Channel{Nothing}(1))
            context = "agent-tool-crash-$pid"
            @test remotecall_fetch(AEC.install_delayed, pid, context, dir, requests, started, release)
            agent = Agent(nothing, [])
            events = []
            active = @async respond!(agent, "crash-tool"; executor=pool, context, on_agent_event=event -> push!(events, event))
            @test take!(started) == pid
            @test read(joinpath(dir, "a.txt"), String) == "hello"
            rmprocs(pid)
            @test timedwait(() -> istaskdone(active), 15) == :ok
            result = fetch(active)
            @test result.value isa AE.Failed
            @test agent.state.phase == AC.Incomplete && !agent.running
            @test isempty(filter(event -> event.type == :tool_execution_end, events))
            @test isempty(filter(event -> event isa AK.Observe && event.observation isa AC.ToolReply, agent.events))
            @test last(collect(AK.Replay(agent.initial, agent.events))).state.phase == AC.Incomplete
        end
    finally
        close(pool)
        pid in workers() && rmprocs(pid)
    end
end

@testset "agent execution on local worker" begin
    agent_execution(myid())
end

@testset "closed executor does not fall back" begin
    pool = AE.Executor(myid())
    close(pool)
    agent = Agent(nothing, [])
    result = respond!(agent, "start"; executor=pool, context="unused")
    @test result.value == AE.Rejected(:submission)
    @test agent.state.phase == AC.Incomplete
    @test last(collect(AK.Replay(agent.initial, agent.events))).state.phase == AC.Incomplete
end

@testset "agent execution on distributed worker" begin
    project = dirname(@__DIR__)
    pid = only(addprocs(1; exeflags=`--startup-file=no --project=$project`))
    try
        remotecall_wait(Core.eval, pid, Main, :(using JuliaForever))
        remotecall_wait(Base.include, pid, Main, joinpath(@__DIR__, "agent_execution_cases.jl"))
        agent_execution(pid)
    finally
        rmprocs(pid)
    end
end

@testset "provider usage and reasoning survive agent execution" begin
    requests = Channel{Any}(3)
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        body = JSON3.read(String(request.body), Dict{String, Any})
        put!(requests, body)
        if request.target == "/v1/chat/completions"
            output = Dict("choices" => [Dict("message" => Dict("role" => "assistant", "content" => "chat done"), "finish_reason" => "stop")], "usage" => Dict("prompt_tokens" => 4, "completion_tokens" => 2))
            return HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(output))
        end
        output = if any(item -> get(item, "type", nothing) == "function_call_output", body["input"])
            Any[Dict("type" => "message", "id" => "msg", "content" => [Dict("type" => "output_text", "text" => "done")])]
        else
            Any[Dict("type" => "reasoning", "id" => "reason", "encrypted_content" => "synthetic-ciphertext"), Dict("type" => "function_call", "id" => "item", "call_id" => "call", "name" => "write", "arguments" => "{\"path\":\"real.txt\",\"content\":\"hello\"}", "status" => "completed")]
        end
        usage = Dict("input_tokens" => 7, "output_tokens" => 3, "total_tokens" => 10)
        HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(Dict("status" => "completed", "output" => output, "usage" => usage)))
    end
    try
        mktempdir() do dir
            context = "agent-responses"
            base = "http://$(HTTP.server_addr(server))/v1"
            @test AEC.install_responses(context, dir, base)
            pool = AE.Executor(myid())
            try
                agent = Agent(nothing, [])
                turn = respond!(agent, "create"; executor=pool, context)
                @test turn.value == "done"
                @test [model.usage.total for model in turn.models] == [10, 10]
                @test read(joinpath(dir, "real.txt"), String) == "hello"
                take!(requests)
                body = take!(requests)
                @test body["input"][2]["encrypted_content"] == "synthetic-ciphertext"
                @test body["input"][3]["call_id"] == "call"
                @test body["input"][4]["output"] == "Successfully wrote to real.txt"
                @test last(collect(AK.Replay(agent.initial, agent.events))).state.phase == AC.Complete
            finally
                close(pool)
                AE.uninstall!(context)
            end
            context = "agent-chat"
            @test AEC.install_chat(context, base)
            pool = AE.Executor(myid())
            try
                agent = Agent(nothing, [])
                turn = respond!(agent, "chat"; executor=pool, context)
                @test turn.value == "chat done"
                @test only(turn.models).usage.total == 6
                @test agent.state.phase == AC.Complete
                @test take!(requests)["messages"][end]["content"] == "chat"
            finally
                close(pool)
                AE.uninstall!(context)
            end
        end
    finally
        close(server)
        wait(server)
    end
end
