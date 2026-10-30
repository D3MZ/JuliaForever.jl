using Test, Distributed, JuliaForever, Serialization, HTTP, JSON3

import JuliaForever.Execution as CE
import JuliaForever.Conversation as CC
import JuliaForever.Kernel as CK

include("conversation_execution_cases.jl")
const CEC = ConversationExecutionCases

function conversation_execution(pid)
    mktempdir() do dir
        requests = RemoteChannel(() -> Channel{Any}(16))
        started = RemoteChannel(() -> Channel{Int}(1))
        release = RemoteChannel(() -> Channel{Nothing}(1))
        context = "conversation-test-$pid"
        @test remotecall_fetch(CEC.install, pid, context, dir, requests, started, release)
        @test !remotecall_fetch(CEC.install, pid, context, dir, requests, started, release)
        pool = CE.Executor(pid; capacity=1)
        try
            input = CK.step(CC.State("session"), CC.Input(0, "create"))
            pending = only(input.effects)
            work = CE.Work(context, pending.effect)
            detailed_work = CE.Work(context, pending.effect; detailed=true)
            @test !work.detailed && detailed_work.detailed
            @test work.result === CK.Observation && detailed_work.result === CE.ModelResult
            @test CE.Work(context, pending.effect, true).detailed
            bytes = IOBuffer()
            serialize(bytes, work)
            @test !occursin("private-fixture-marker", String(take!(bytes)))
            first = fetch(CE.submit!(pool, pending, 1, context))
            @test first isa CE.Completed
            @test (first.id, first.attempt, first.worker) == (pending.id, 1, pid)
            @test first.value isa CC.ModelReply
            reply = first.value.message
            @test reply.finish == "tool_calls" && reply.done
            @test reply.metadata["response_output"][1]["encrypted_content"] == "encrypted-reasoning"
            @test reply.calls[1].id == "call-1"
            first_request = take!(requests)
            @test first_request.worker == pid
            @test first_request.tools == ["read", "write"]
            @test first_request.parameters == Dict("temperature" => 0.2)
            @test last(first_request.messages)["content"] == "create"

            planned = CK.step(input.state, CK.Observe(input.state.revision, first.id, first.value))
            tool = only(planned.effects)
            @test tool.effect isa CC.ToolRequest
            performed = fetch(CE.submit!(pool, tool, 1, context))
            @test performed isa CE.Completed
            @test performed.value isa CC.ToolReply
            @test (performed.value.text, performed.value.iserror) == ("Successfully wrote to output.txt", false)
            @test read(joinpath(dir, "output.txt"), String) == "hello"
            continued = CK.step(planned.state, CK.Observe(planned.state.revision, performed.id, performed.value))
            final = fetch(CE.submit!(pool, only(continued.effects), 1, context))
            @test final isa CE.Completed
            @test (final.value.message.content, final.value.message.finish, final.value.message.done) == ("done", "stop", true)
            next_request = take!(requests)
            assistant = only(message for message in next_request.messages if message["role"] == "assistant")
            @test assistant["response_output"][1]["encrypted_content"] == "encrypted-reasoning"
            @test assistant["response_output"][2]["call_id"] == "call-1"
            @test last(next_request.messages)["content"] == "Successfully wrote to output.txt"
            finished = CK.step(continued.state, CK.Observe(continued.state.revision, final.id, final.value))
            @test finished.state.phase == CC.Complete

            missing = CC.ToolRequest(CC.ToolCall("bad", "read", "{\"path\":\"absent.txt\"}"))
            failed_tool = fetch(CE.submit!(pool, "missing", 1, CE.Work(context, missing)))
            @test failed_tool isa CE.Completed
            @test failed_tool.value isa CC.ToolReply && failed_tool.value.iserror
            @test occursin("absent.txt", failed_tool.value.text)
            malformed = CC.ToolRequest(CC.ToolCall("bad", "write", "{"))
            failed_json = fetch(CE.submit!(pool, "malformed", 1, CE.Work(context, malformed)))
            @test failed_json isa CE.Completed && failed_json.value.iserror
            metadata = Dict{String, Any}("id" => "other", "function" => Dict("name" => "write", "arguments" => "{\"path\":\"misdirected.txt\",\"content\":\"bad\"}"))
            typed_call = CC.ToolCall("typed", "write", "{\"path\":\"typed.txt\",\"content\":\"correct\"}"; metadata)
            typed = fetch(CE.submit!(pool, "typed", 1, CE.Work(context, CC.ToolRequest(typed_call))))
            @test typed isa CE.Completed && !typed.value.iserror
            @test read(joinpath(dir, "typed.txt"), String) == "correct"
            @test !isfile(joinpath(dir, "misdirected.txt"))
            skipped = CC.SkipRequest(CC.ToolCall("skip", "write", "{\"path\":\"skipped.txt\",\"content\":\"bad\"}"))
            skip = fetch(CE.submit!(pool, "skip", 1, CE.Work(context, skipped)))
            @test skip isa CE.Completed && skip.value.iserror
            @test occursin("output token limit", skip.value.text)
            @test !isfile(joinpath(dir, "skipped.txt"))

            fail_input = CK.step(CC.State("failure"), CC.Input(0, "fail"))
            failure = fetch(CE.submit!(pool, only(fail_input.effects), 1, context))
            @test failure isa CE.Completed && failure.value isa CC.ModelFailure
            @test failure.value.reason == "provider did not return"
            @test !occursin("private-fixture-marker", repr(failure))
            take!(requests)
            detailed_failure = fetch(CE.submit!(pool, only(fail_input.effects), 1, context; detailed=true))
            @test detailed_failure.value isa CE.ModelResult
            @test detailed_failure.value.observation isa CC.ModelFailure
            @test detailed_failure.value.usage === nothing && detailed_failure.value.error === nothing
            @test !occursin("private-fixture-marker", repr(detailed_failure))
            take!(requests)
            failed_state = CK.step(fail_input.state, CK.Observe(fail_input.state.revision, failure.id, failure.value))
            @test failed_state.state.phase == CC.Incomplete

            partial_input = CK.step(CC.State("incomplete"), CC.Input(0, "incomplete"))
            partial = fetch(CE.submit!(pool, only(partial_input.effects), 1, context))
            @test partial isa CE.Completed && partial.value isa CC.ModelReply
            @test !partial.value.message.done
            partial_state = CK.step(partial_input.state, CK.Observe(partial_input.state.revision, partial.id, partial.value))
            @test partial_state.state.phase == CC.Incomplete && isempty(partial_state.effects)
            take!(requests)

            mktempdir() do otherdir
                other = "$context-other"
                @test remotecall_fetch(CEC.install, pid, other, otherdir, requests, started, release)
                try
                    call = CC.ToolRequest(CC.ToolCall("other", "write", "{\"path\":\"isolated.txt\",\"content\":\"other\"}"))
                    isolated = fetch(CE.submit!(pool, "other", 1, CE.Work(other, call)))
                    @test isolated isa CE.Completed && !isolated.value.iserror
                    @test read(joinpath(otherdir, "isolated.txt"), String) == "other"
                    @test !isfile(joinpath(dir, "isolated.txt"))
                finally
                    remotecall_wait(CE.uninstall!, pid, other)
                end
            end

            block = CK.step(CC.State("blocked"), CC.Input(0, "block"))
            active = CE.submit!(pool, only(block.effects), 1, context)
            @test take!(started) == pid
            queued_call = CC.ToolRequest(CC.ToolCall("queued", "write", "{\"path\":\"queued.txt\",\"content\":\"bad\"}"))
            queued = CE.submit!(pool, "queued", 1, CE.Work(context, queued_call))
            CE.cancel!(queued)
            CE.cancel!(active)
            put!(release, nothing)
            @test fetch(active) isa CE.Completed
            @test fetch(queued) isa CE.Cancelled
            @test !isfile(joinpath(dir, "queued.txt"))
            take!(requests)

            remotecall_wait(CE.uninstall!, pid, context)
            missing_context = fetch(CE.submit!(pool, only(input.effects), 2, context))
            @test missing_context isa CE.Failed
            @test missing_context.worker == pid
            @test !occursin("private-fixture-marker", missing_context.message)
        finally
            close(pool)
            remotecall_wait(CE.uninstall!, pid, context)
        end
    end
end

function responses_execution(pid)
    requests = Channel{Any}(2)
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        body = JSON3.read(String(request.body), Dict{String, Any})
        put!(requests, (; target=request.target, auth=HTTP.header(request, "Authorization"), body))
        output = if any(item -> get(item, "type", nothing) == "function_call_output", body["input"])
            Any[Dict("type" => "message", "id" => "msg", "content" => [Dict("type" => "output_text", "text" => "done")])]
        else
            Any[Dict("type" => "reasoning", "id" => "reason", "encrypted_content" => "synthetic-ciphertext"), Dict("type" => "function_call", "id" => "item", "call_id" => "call", "name" => "write", "arguments" => "{\"path\":\"real.txt\",\"content\":\"hello\"}", "status" => "completed")]
        end
        HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(Dict("status" => "completed", "output" => output)))
    end
    try
        mktempdir() do dir
            context = "responses-test-$pid"
            base = "http://$(HTTP.server_addr(server))/v1"
            @test remotecall_fetch(CEC.install_responses, pid, context, dir, base)
            pool = CE.Executor(pid)
            try
                input = CK.step(CC.State("responses"), CC.Input(0, "create"))
                model = fetch(CE.submit!(pool, only(input.effects), 1, context))
                @test model isa CE.Completed && model.value isa CC.ModelReply
                @test model.value.message.metadata["response_output"][1]["encrypted_content"] == "synthetic-ciphertext"
                request = take!(requests)
                @test (request.target, request.auth) == ("/v1/responses", "Bearer synthetic-key")
                @test request.body["reasoning"]["effort"] == "low"
                planned = CK.step(input.state, CK.Observe(input.state.revision, model.id, model.value))
                tool = fetch(CE.submit!(pool, only(planned.effects), 1, context))
                @test tool isa CE.Completed && !tool.value.iserror
                @test read(joinpath(dir, "real.txt"), String) == "hello"
                next = CK.step(planned.state, CK.Observe(planned.state.revision, tool.id, tool.value))
                final = fetch(CE.submit!(pool, only(next.effects), 1, context))
                @test final isa CE.Completed && final.value.message.content == "done"
                request = take!(requests)
                @test request.body["input"][2]["encrypted_content"] == "synthetic-ciphertext"
                @test request.body["input"][3]["call_id"] == "call"
                @test request.body["input"][4]["output"] == "Successfully wrote to real.txt"
                @test CK.step(next.state, CK.Observe(next.state.revision, final.id, final.value)).state.phase == CC.Complete
            finally
                close(pool)
                remotecall_wait(CE.uninstall!, pid, context)
            end
        end
    finally
        close(server)
        wait(server)
    end
end

@testset "conversation effects on local worker" begin
    conversation_execution(myid())
    responses_execution(myid())
end

@testset "conversation effects on distributed worker" begin
    project = dirname(@__DIR__)
    pid = only(addprocs(1; exeflags=`--startup-file=no --project=$project`))
    try
        remotecall_wait(Core.eval, pid, Main, :(using JuliaForever))
        remotecall_wait(Base.include, pid, Main, joinpath(@__DIR__, "conversation_execution_cases.jl"))
        conversation_execution(pid)
        responses_execution(pid)
    finally
        rmprocs(pid)
    end
end
