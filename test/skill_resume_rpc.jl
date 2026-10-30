module SkillResumeRPCTests

using Test, JuliaForever, JSON3, HTTP

function receive!(channel, predicate)
    while true
        timedwait(() -> isready(channel), 45) == :ok || error("Timed out waiting for skill RPC output")
        record = take!(channel)
        predicate(record) && return record
    end
end

function skillfile(workspace, name)
    path = joinpath(workspace, ".pi", "skills", name, "SKILL.md")
    mkpath(dirname(path))
    write(path, "---\nname: $name\ndescription: $name metadata\n---\nprivate $name instructions\n")
    path
end

function exchange(cmd, env, workspace; checkfailed=false)
    mktempdir() do dir
        diagnostics = joinpath(dir, "diagnostics")
        process = open(pipeline(addenv(cmd, env...); stderr=diagnostics), "r+")
        channel = Channel{Any}(Inf)
        observed = String[]
        reader = @async for line in eachline(process)
            push!(observed, line)
            put!(channel, JSON3.read(line, Dict{String, Any}))
        end
        try
            send(value) = (println(process, JSON3.write(value)); flush(process))
            response(id) = receive!(channel, value -> get(value, "id", "") == id)
            prompt(id, message) = (send((; id, type="prompt", message)); receive!(channel, value -> get(value, "type", "") == "agent_settled"))
            send((; id="before", type="get_commands"))
            before = response("before")
            prompt("seed", "seed")
            send((; id="state", type="get_state"))
            state = response("state")
            send((; id="model", type="set_model", provider="openai", modelId="gpt-4.1-mini"))
            model = response("model")
            send((; id="modelstate", type="get_state"))
            modelstate = response("modelstate")
            send((; id="newsession", type="new_session"))
            new = response("newsession")
            rm(joinpath(workspace, ".pi", "skills", "old"); recursive=true)
            skillfile(workspace, "new")
            failed = if checkfailed
                saved = read(state["data"]["sessionFile"])
                send((; id="current", type="get_state"))
                current = response("current")
                send((; id="invalid", type="switch_session", sessionPath=workspace))
                invalid = response("invalid")
                send((; id="unchanged", type="get_state"))
                unchanged = response("unchanged")
                send((; id="commands-unchanged", type="get_commands"))
                commands = response("commands-unchanged")
                (; current, invalid, unchanged, commands, target_unchanged=read(state["data"]["sessionFile"]) == saved)
            else
                nothing
            end
            send((; id="switch", type="switch_session", sessionPath=state["data"]["sessionFile"]))
            switched = response("switch")
            send((; id="after", type="get_commands"))
            after = response("after")
            prompt("skill", "/skill:new hello")
            rm(joinpath(workspace, ".pi", "skills", "new"); recursive=true)
            skillfile(workspace, "third")
            send((; id="same", type="switch_session", sessionPath=state["data"]["sessionFile"]))
            same = response("same")
            send((; id="samecommands", type="get_commands"))
            samecommands = response("samecommands")
            prompt("again", "/skill:third again")
            (; before, state, model, modelstate, new, switched, after, same, samecommands, failed, observed, diagnostics=read(diagnostics, String))
        finally
            close(process.in)
            timedwait(() -> process_exited(process), 5) == :ok || kill(process)
            wait(process)
            wait(reader)
            success(process) || error("Skill RPC failed: $(read(diagnostics, String))")
        end
    end
end

@testset "RPC session switches refresh skill commands and context" begin
    requests = Any[]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        push!(requests, (; target=request.target, auth=HTTP.header(request, "authorization", ""), body=JSON3.read(String(request.body), Dict{String, Any})))
        delta = JSON3.write((; type="response.output_text.delta", delta="answer"))
        done = JSON3.write((; type="response.completed", response=(; status="completed", output=[(; type="message", content=[(; type="output_text", text="answer")])])) )
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $delta\n\ndata: $done\n\n")
    end
    try
        mktempdir() do root
            base = "http://$(HTTP.server_addr(server))/v1"
            project = dirname(@__DIR__)
            env(workspace, agentdir) = ["HOME" => workspace, "USERPROFILE" => workspace, "PI_CODING_AGENT_DIR" => agentdir, "PI_OFFLINE" => "1", "JF_INSTRUCTIONS_DIR" => workspace, "JF_CHATGPT_DIR" => joinpath(workspace, "chatgpt"), "JF_OPENROUTER_DIR" => joinpath(workspace, "router"), "OPENAI_API_KEY" => "synthetic-skill-key", "OPENAI_BASE_URL" => base, "OPENROUTER_API_KEY" => nothing, "ANTHROPIC_API_KEY" => nothing, "GEMINI_API_KEY" => nothing, "TERM" => "dumb"]
            names(record) = Set(command["name"] for command in record["data"]["commands"])
            outcomes = []
            for kind in (haskey(ENV, "PI_SOURCE") ? (:pi, :julia) : (:julia,))
                workspace = joinpath(root, String(kind))
                mkpath(workspace)
                skillfile(workspace, "old")
                agentdir = joinpath(workspace, "agent")
                mkpath(agentdir)
                if kind == :pi
                    source = ENV["PI_SOURCE"]
                    @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
                    write(joinpath(agentdir, "models.json"), JSON3.write((; providers=(; openai=(; baseUrl=base)))))
                    cmd = Cmd(`node $(joinpath(@__DIR__, "headless_reference.mjs")) $source --mode rpc --session-dir $(joinpath(workspace, "sessions")) --model openai/gpt-4.1 --approve`; dir=workspace)
                else
                    cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode rpc --session-dir $(joinpath(workspace, "sessions")) --model openai/gpt-4.1`; dir=workspace)
                end
                before = length(requests)
                result = exchange(cmd, env(workspace, agentdir), workspace; checkfailed=kind == :julia)
                captured = requests[before+1:end]
                @test result.new["success"] && result.switched["success"] && result.same["success"]
                @test result.model["success"] && result.modelstate["data"]["model"]["id"] == "gpt-4.1-mini"
                @test "skill:old" in names(result.before)
                if kind == :julia
                    @test !result.failed.invalid["success"] && result.failed.target_unchanged
                    @test result.failed.current["data"]["sessionId"] == result.failed.unchanged["data"]["sessionId"]
                    @test names(result.failed.commands) == names(result.before)
                end
                @test "skill:new" in names(result.after) && !("skill:old" in names(result.after))
                @test "skill:third" in names(result.samecommands) && !("skill:new" in names(result.samecommands))
                @test length(captured) == 3
                if length(captured) == 3
                    @test all(r -> r.target == "/v1/responses" && r.auth == "Bearer synthetic-skill-key", captured)
                    @test [r.body["model"] for r in captured] == fill("gpt-4.1", 3)
                    @test occursin("new metadata", JSON3.write(captured[2].body))
                    @test occursin("private new instructions", JSON3.write(captured[2].body))
                    @test occursin("third metadata", JSON3.write(captured[3].body))
                    @test occursin("private third instructions", JSON3.write(captured[3].body))
                end
                @test !occursin("synthetic-skill-key", join(result.observed) * result.diagnostics)
                push!(outcomes, (; names=names(result.after), samenames=names(result.samecommands)))
            end
            if length(outcomes) == 2
                @test ("skill:new" in outcomes[1].names) == ("skill:new" in outcomes[2].names)
                @test ("skill:third" in outcomes[1].samenames) == ("skill:third" in outcomes[2].samenames)
            end
        end
    finally
        close(server)
        wait(server)
    end
end

end
