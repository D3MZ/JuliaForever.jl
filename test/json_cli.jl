using Test, JSON3, HTTP, Base64

function json_cli(dir, scenario, args...; input="", session=["--no-session"], provider="openai")
    root = dirname(@__DIR__)
    script = joinpath(@__DIR__, "json_cli_process.jl")
    output, diagnostics, stdinpath = joinpath.((dir,), ("output", "diagnostics", "stdin"))
    write(stdinpath, input)
    cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$root $script --mode json $session $args`; dir=dir)
    cmd = addenv(cmd, "HOME" => dir, "JF_PROVIDER" => provider, "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => "fixture-key", "OPENROUTER_MODEL" => "fixture", "OPENROUTER_API_KEY" => "fixture-key", "ANTHROPIC_MODEL" => "fixture", "ANTHROPIC_API_KEY" => "fixture-key", "GEMINI_MODEL" => "fixture", "GEMINI_API_KEY" => "fixture-key", "JF_JSON_SCENARIO" => scenario, "JF_INSTRUCTIONS_DIR" => dir, "PI_CODING_AGENT_DIR" => joinpath(dir, "pi"))
    process = run(pipeline(ignorestatus(cmd); stdin=stdinpath, stdout=output, stderr=diagnostics))
    lines = readlines(output)
    records = try
        JSON3.read.(lines)
    catch
        nothing
    end
    (; status=process.exitcode, records, diagnostics=read(diagnostics, String), output=read(output, String))
end

@testset "JSON invocation, provider and session boundaries" begin
    mktempdir() do dir
        empty = json_cli(dir, "text")
        @test empty.status == 0 && length(empty.records) == 1 && only(empty.records).type == "session"
        invalid = json_cli(dir, "text", "--mode", "rpc", "hello")
        @test invalid.status == 2 && isempty(invalid.records) && occursin("--mode requires text or json", invalid.diagnostics)
        repeated = json_cli(dir, "text", "--mode", "invalid", "--mode", "json", "hello")
        @test repeated.status == 2 && isempty(repeated.records)
        piped = json_cli(dir, "noisy", "first", "second"; input="piped ")
        @test piped.status == 0 && piped.records !== nothing
        if piped.records !== nothing
            users = [record.message.content for record in piped.records if record.type == "message_end" && record.message.role == "user"]
            @test users == ["pipedfirst", "second"]
            @test count(record -> record.type == "session", piped.records) == 1
            @test count(record -> record.type == "agent_settled", piped.records) == 2
            @test count(==("provider diagnostic"), split(chomp(piped.diagnostics), '\n')) == 2
        end
        special = json_cli(dir, "text", "one\ntwo\u2028three")
        @test special.status == 0 && special.records !== nothing
        @test only(record.assistantMessageEvent.delta for record in special.records if record.type == "message_update" && record.assistantMessageEvent.type == "text_delta") == "reply:one\ntwo\u2028three"
        sessions = joinpath(dir, "sessions")
        first = json_cli(dir, "text", "first"; session=["--session-dir", sessions])
        resumed = json_cli(dir, "text", "second"; session=["--session-dir", sessions, "--continue"])
        @test first.status == 0 && resumed.status == 0
        @test first.records[1].id == resumed.records[1].id
        @test only(record.message.content for record in resumed.records if record.type == "message_end" && record.message.role == "user") == "second"
        gif = "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=="
        write(joinpath(dir, "picture.gif"), base64decode(gif))
        pictured = json_cli(dir, "text", "@picture.gif", "inspect")
        @test pictured.status == 0 && pictured.records !== nothing
        user = only(record.message for record in pictured.records if record.type == "message_end" && record.message.role == "user")
        @test user.content[2].type == "image" && user.content[2].mimeType == "image/gif" && user.content[2].data == gif
        for (provider, api, label) in (("openai-responses", "openai-responses", "openai"), ("openrouter", "openai-completions", "openrouter"), ("anthropic", "anthropic-messages", "anthropic"), ("google", "google-generative-ai", "google"))
            result = json_cli(dir, "text", "hello"; provider)
            @test result.status == 0 && result.records !== nothing
            assistant = only(record.message for record in result.records if record.type == "message_end" && record.message.role == "assistant")
            @test assistant.api == api && assistant.provider == label
        end
    end
end

@testset "Pi JSON mode" begin
    mktempdir() do dir
        observed = json_cli(dir, "text", "hello")
        @test observed.status == 0
        @test observed.records !== nothing
        if observed.records !== nothing
            records = observed.records
            @test first(records).type == "session"
            @test first(records).version == 3 && realpath(first(records).cwd) == realpath(dir)
            types = [record.type for record in records[2:end]]
            reference = if haskey(ENV, "PI_SOURCE")
                pi = ENV["PI_SOURCE"]
                @test readchomp(`git -C $pi rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
                JSON3.read(read(`node $(joinpath(@__DIR__, "json_cli_pi.mjs")) $pi`, String))
            else
                [(; type) for type in ("agent_start", "turn_start", "message_start", "message_end", "message_start", "message_update", "message_update", "message_update", "message_end", "turn_end", "agent_end", "agent_settled")]
            end
            @test types == [record.type for record in reference]
            updates = [record.assistantMessageEvent for record in records if record.type == "message_update"]
            @test [update.type for update in updates] == ["text_start", "text_delta", "text_end"]
            @test updates[2].delta == "reply:hello" && updates[3].content == "reply:hello"
            @test all(!haskey(record, :message) && !haskey(record.assistantMessageEvent, :partial) for record in records if record.type == "message_update")
            messages = [record.message for record in records if record.type == "message_end"]
            @test messages[1].role == "user" && messages[1].content == "hello"
            @test messages[2].role == "assistant" && messages[2].content[1].text == "reply:hello"
            @test messages[2].model == "fixture" && messages[2].usage.totalTokens == 5 && messages[2].stopReason == "stop"
            @test records[end-1].willRetry == false && records[end].aborted == false
            @test isempty(observed.diagnostics)
        end
    end
end

@testset "JSON tool and failure events" begin
    mktempdir() do dir
        write(joinpath(dir, "sample.txt"), "file content")
        observed = json_cli(dir, "tool", "hello")
        @test observed.status == 0 && observed.records !== nothing
        if observed.records !== nothing
            records = observed.records
            if haskey(ENV, "PI_SOURCE")
                pi = ENV["PI_SOURCE"]
                reference = JSON3.read(read(`node $(joinpath(@__DIR__, "json_cli_pi.mjs")) $pi tool`, String))
                @test [record.type for record in records[2:end]] == [record.type for record in reference]
                @test [record.assistantMessageEvent.type for record in records if record.type == "message_update"] == [record.assistantMessageEvent.type for record in reference if record.type == "message_update"]
            end
            updates = [record.assistantMessageEvent for record in records if record.type == "message_update"]
            start = only(update for update in updates if update.type == "toolcall_start")
            finish = only(update for update in updates if update.type == "toolcall_end")
            @test start.id == "call-1" && start.toolName == "read"
            @test finish.toolCall.arguments.path == "sample.txt"
            toolstart = only(record for record in records if record.type == "tool_execution_start")
            toolend = only(record for record in records if record.type == "tool_execution_end")
            @test toolstart.toolCallId == "call-1" && toolstart.args.path == "sample.txt"
            @test toolend.toolCallId == "call-1" && !toolend.isError
            @test any(record.type == "message_end" && record.message.role == "toolResult" && record.message.toolName == "read" for record in records if haskey(record, :message))
            @test last(records).type == "agent_settled"
        end
        failed = json_cli(dir, "incomplete", "hello")
        @test failed.status == 0 && failed.records !== nothing
        if failed.records !== nothing
            assistant = last(record.message for record in failed.records if record.type == "message_end" && record.message.role == "assistant")
            @test assistant.stopReason == "error"
            @test assistant.errorMessage == "[redacted]" && !occursin("fixture-key", failed.output)
            @test last(failed.records).type == "agent_settled"
        end
        invalid = json_cli(dir, "badargs", "hello")
        @test invalid.status == 0 && invalid.records !== nothing
        call = only(record.assistantMessageEvent.toolCall for record in invalid.records if record.type == "message_update" && record.assistantMessageEvent.type == "toolcall_end")
        @test isempty(call.arguments) && occursin("{broken", call.argumentsError)
        @test only(record for record in invalid.records if record.type == "tool_execution_end").isError
        thought = json_cli(dir, "thinking", "hello")
        @test thought.status == 0 && thought.records !== nothing
        updates = [record.assistantMessageEvent.type for record in thought.records if record.type == "message_update"]
        @test updates == ["thinking_start", "thinking_delta", "thinking_end", "text_start", "text_delta", "text_end"]
        assistant = last(record.message for record in thought.records if record.type == "message_end" && record.message.role == "assistant")
        @test assistant.content[1].thinking == "consider" && assistant.content[2].text == "answer"
        reconciled = json_cli(dir, "reconcile", "hello")
        @test reconciled.status == 0 && reconciled.records !== nothing
        updates = [record.assistantMessageEvent for record in reconciled.records if record.type == "message_update"]
        @test updates[end].content == "final"
        @test last(record.message for record in reconciled.records if record.type == "message_end" && record.message.role == "assistant").content[1].text == "final"
    end
    requests = []
    sse(value) = "data: " * JSON3.write(value) * "\n\n"
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        body = JSON3.read(String(request.body))
        push!(requests, body)
        data = if length(requests) == 1
            sse((; choices=[(; delta=(; content="read "), finish_reason=nothing)])) *
            sse((; choices=[(; delta=(; tool_calls=[Dict("index" => 0, "id" => "actual-call", "type" => "function", "function" => Dict("name" => "read", "arguments" => "{\"path\":\"sample.txt\"}"))]), finish_reason="tool_calls")]))
        else
            sse((; choices=[(; delta=(; content="finished"), finish_reason="stop")]))
        end
        data *= sse((; choices=[], usage=(; prompt_tokens=8, completion_tokens=3, total_tokens=11))) * "data: [DONE]\n\n"
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], data)
    end
    try
        mktempdir() do dir
            write(joinpath(dir, "sample.txt"), "real file")
            root = dirname(@__DIR__)
            output, diagnostics, input = joinpath.((dir,), ("output", "diagnostics", "stdin"))
            write(input, "")
            cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$root -m JuliaForever --mode json --no-session hello`; dir=dir)
            cmd = addenv(cmd, "HOME" => dir, "JF_PROVIDER" => "openai", "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => "fixture-key", "OPENAI_BASE_URL" => "http://$(HTTP.server_addr(server))/v1", "JF_INSTRUCTIONS_DIR" => dir, "PI_CODING_AGENT_DIR" => joinpath(dir, "pi"))
            process = run(pipeline(ignorestatus(cmd); stdin=input, stdout=output, stderr=diagnostics))
            @test process.exitcode == 0
            records = JSON3.read.(readlines(output))
            @test length(requests) == 2
            @test only(record for record in records if record.type == "tool_execution_start").args.path == "sample.txt"
            tool = only(record.message for record in records if record.type == "message_end" && record.message.role == "toolResult")
            @test tool.toolCallId == "actual-call" && occursin("real file", tool.content[1].text)
            assistant = last(record.message for record in records if record.type == "message_end" && record.message.role == "assistant")
            @test assistant.content[1].text == "finished" && assistant.usage.totalTokens == 11
            @test isempty(read(diagnostics, String))
        end
    finally
        close(server)
        wait(server)
    end
end
