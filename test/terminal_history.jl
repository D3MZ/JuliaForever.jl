using Test, JuliaForever, HTTP, JSON3, SQLite

function history_process(base, workspace, args; input="", configured=true)
    project = dirname(@__DIR__)
    cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project -m JuliaForever $args`; dir=workspace)
    cmd = addenv(cmd, "JF_PROVIDER" => "openai", "OPENAI_BASE_URL" => base, "OPENAI_MODEL" => configured ? "fixture" : nothing, "OPENAI_API_KEY" => configured ? "synthetic-history-secret" : nothing, "JF_INSTRUCTIONS_DIR" => nothing)
    mktempdir() do dir
        stdinpath, output, diagnostics = joinpath.((dir,), ("stdin", "output", "diagnostics"))
        write(stdinpath, input)
        process = run(pipeline(ignorestatus(cmd); stdin=stdinpath, stdout=output, stderr=diagnostics))
        status = process.termsignal == 0 ? process.exitcode : 128 + process.termsignal
        (; status, output=read(output, String), diagnostics=read(diagnostics, String))
    end
end

@testset "CLI history resume and interrupted effect" begin
    requests = Any[]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        body = JSON3.read(String(request.body))
        push!(requests, body)
        prompt = body.messages[end].content
        if prompt == "interrupt"
            arguments = JSON3.write((; command="printf x >> effect.txt; kill -KILL \"\$PPID\""))
            call = Dict("index" => 0, "id" => "one", "type" => "function", "function" => Dict("name" => "bash", "arguments" => arguments))
            chunk = (; choices=[(; index=0, delta=(; tool_calls=[call]), finish_reason="tool_calls")])
        elseif prompt == "after"
            messages = body.messages
            if length(messages) < 3 || messages[end-1].role != "tool" || messages[end-1].tool_call_id != "one" || messages[end-1].content != "Error: Tool outcome unknown; abandoned: effect inspected"
                return HTTP.Response(400, "missing tool reply")
            end
            chunk = (; choices=[(; index=0, delta=(; content="reply:" * prompt), finish_reason="stop")])
        else
            chunk = (; choices=[(; index=0, delta=(; content="reply:" * prompt), finish_reason="stop")])
        end
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $(JSON3.write(chunk))\n\ndata: [DONE]\n\n")
    end
    try
        mktempdir() do workspace
            base = "http://$(HTTP.server_addr(server))/v1"
            path = joinpath(workspace, "session.sqlite")
            write(joinpath(workspace, "AGENTS.md"), "initial instruction")
            first = history_process(base, workspace, ["--history", path, "one"])
            @test first == (; status=0, output="reply:one\n", diagnostics="")
            @test isfile(path)
            write(joinpath(workspace, "AGENTS.md"), "changed instruction")
            second = history_process(base, workspace, ["--history", path, "two"])
            @test second == (; status=0, output="reply:two\n", diagnostics="")
            @test length(requests) == 2
            messages = requests[2].messages
            @test [message.role for message in messages] == ["system", "user", "assistant", "user"]
            @test occursin("initial instruction", messages[1].content)
            @test !occursin("changed instruction", messages[1].content)
            @test [message.content for message in messages[2:end]] == ["one", "reply:one", "two"]
            if haskey(ENV, "PI_SOURCE")
                @test readchomp(`git -C $(ENV["PI_SOURCE"]) rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
                script = joinpath(@__DIR__, "terminal_history_pi.mjs")
                reference = JSON3.read(read(`node $script $(ENV["PI_SOURCE"]) $workspace`, String), Vector{Vector{String}})
                @test [[message.role, message.content] for message in messages[2:end]] == reference
            end
            @test !occursin("synthetic-history-secret", String(read(path)))

            missing = history_process(base, workspace, ["--history"])
            @test missing.status == 2
            @test occursin("--history requires a path", missing.diagnostics)
            no_history = joinpath(workspace, "not-created.sqlite")
            @test open(History.SQLite, no_history; create=false) == History.Rejected(:history_missing)
            @test !isfile(no_history)
            missing = history_process(base, workspace, ["--history", no_history, "--abandon", "inspected"]; configured=false)
            @test missing.status == 2
            @test occursin("existing", missing.diagnostics)
            @test !isfile(no_history)
            @test history_process(base, workspace, ["--abandon", "inspected"]; configured=false).status == 2
            @test history_process(base, workspace, ["--history", path, "--abandon", "inspected"]; configured=false).status == 1

            empty = joinpath(workspace, "empty.sqlite")
            write(empty, UInt8[])
            foreign = joinpath(workspace, "foreign.sqlite")
            db = SQLite.DB(foreign)
            SQLite.execute(db, "CREATE TABLE unrelated (value TEXT)")
            close(db)
            textfile = joinpath(workspace, "unrelated.txt")
            write(textfile, "unrelated text")
            for file in (empty, foreign, textfile)
                original = read(file)
                for action in (["--inspect-history"], ["--abandon", "inspected"])
                    rejected = history_process(base, workspace, ["--history", file, action...]; configured=false)
                    @test rejected.status == 1
                    @test occursin("history_format", rejected.diagnostics)
                    @test read(file) == original
                end
            end
            executable = realpath(joinpath(Sys.BINDIR, Base.julia_exename()))
            userdir = realpath(homedir())
            if Sys.isunix() && startswith(executable, joinpath(userdir, ""))
                relative = relpath(executable, userdir)
                tildepath = joinpath("~", relative)
                @test open(History.SQLite, tildepath; create=false) == History.Rejected(:history_format)
                inspected = history_process(base, workspace, ["--history", tildepath, "--inspect-history"]; configured=false)
                @test inspected.status == 1
                @test occursin("history_format", inspected.diagnostics)
            end

            incomplete = joinpath(workspace, "incomplete.sqlite")
            store = open(History.SQLite, incomplete)
            agent = Agent(nothing, []; history=store)
            @test History.append!(store, agent.history_revision, Any[History.encode(Conversation.Input(0, "unfinished"))]) == 2
            close(store)
            before = length(requests)
            blocked = history_process(base, workspace, ["--history", incomplete, "again"])
            @test blocked.status == 1
            @test occursin("incomplete turn", blocked.diagnostics)
            @test length(requests) == before

            if Sys.isunix()
                interrupted = joinpath(workspace, "interrupted.sqlite")
                killed = history_process(base, workspace, ["--history", interrupted, "interrupt"])
                @test killed.status != 0
                @test read(joinpath(workspace, "effect.txt"), String) == "x"
                store = open(History.SQLite, interrupted)
                snapshot = History.snapshot(store)
                close(store)
                before = length(requests)
                recovered = history_process(base, workspace, ["--provider", "openai", "--model", "recovery-model", "--history", interrupted, "again"])
                @test recovered.status == 1
                @test occursin("uncertain", recovered.diagnostics)
                @test occursin("not retried", recovered.diagnostics)
                @test length(requests) == before
                @test read(joinpath(workspace, "effect.txt"), String) == "x"
                inspected = history_process(base, workspace, ["--provider", "openai", "--model", "recovery-model", "--history", interrupted, "--inspect-history"]; configured=false)
                @test inspected.status == 0
                @test occursin("uncertain_effect", inspected.output)
                @test occursin("bash", inspected.output)
                @test occursin("effect.txt", inspected.output)
                @test length(requests) == before
                store = open(History.SQLite, interrupted)
                @test History.snapshot(store).batches == snapshot.batches
                close(store)
                blocked = history_process(base, workspace, ["--history", interrupted, "--abandon", "effect inspected", "extra"]; configured=false)
                @test blocked.status == 2
                @test length(requests) == before
                abandoned = history_process(base, workspace, ["--provider", "openai", "--model", "recovery-model", "--history", interrupted, "--abandon", "effect inspected"]; configured=false)
                @test abandoned == (; status=0, output="Interrupted turn abandoned. No effect was retried or undone.\n", diagnostics="")
                @test length(requests) == before
                @test read(joinpath(workspace, "effect.txt"), String) == "x"
                continued = history_process(base, workspace, ["--provider", "openai", "--model", "recovery-model", "--history", interrupted, "after"])
                @test continued == (; status=0, output="reply:after\n", diagnostics="")
                @test requests[end].model == "recovery-model"
                @test requests[end].messages[end-1].tool_call_id == "one"
                @test requests[end].messages[end-1].content == "Error: Tool outcome unknown; abandoned: effect inspected"
                @test read(joinpath(workspace, "effect.txt"), String) == "x"
            end
        end
    finally
        close(server)
        wait(server)
    end
end
