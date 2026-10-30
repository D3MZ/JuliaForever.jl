module SkillCommandTests

using Test, JuliaForever, JSON3
const H = JuliaForever.History
const C = JuliaForever.Conversation

function putskill(root, name, body; explicit=false)
    path = joinpath(root, ".pi", "skills", name, "SKILL.md")
    mkpath(dirname(path))
    flag = explicit ? "disable-model-invocation: true\n" : ""
    write(path, "\ufeff---\r\nname: $name\r\ndescription: example $name\r\n" * replace(flag, "\n" => "\r\n") * "---\r\n\r\n" * body * "\r\n")
    path
end

function session(root, agentdir, requestfile, history, commands; options=String[], fixture="session_cli_process.jl")
    project = dirname(@__DIR__)
    script = joinpath(@__DIR__, fixture)
    cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project $script $options --history $history`; dir=root)
    cmd = addenv(cmd, "HOME" => dirname(root), "JULIA_DEPOT_PATH" => join(DEPOT_PATH, Sys.iswindows() ? ';' : ':'), "PI_CODING_AGENT_DIR" => agentdir, "JF_PROVIDER" => "openai", "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => "synthetic", "JF_SESSION_REQUESTS" => requestfile, "JF_SESSION_DIR" => joinpath(dirname(root), "sessions"), "JF_SKILL_WORKSPACE" => root, "JF_INSTRUCTIONS_DIR" => nothing)
    mktempdir() do io
        input, output, diagnostics = joinpath.((io,), ("stdin", "stdout", "stderr"))
        write(input, join(commands, "\n") * "\n/exit\n")
        process = run(pipeline(ignorestatus(cmd); stdin=input, stdout=output, stderr=diagnostics))
        (; status=process.exitcode, output=read(output, String), diagnostics=read(diagnostics, String))
    end
end

block(name, path, body) = "<skill name=\"$name\" location=\"$path\">\nReferences are relative to $(dirname(path)).\n\n$body\n</skill>"

@testset "explicit skills reach the terminal and survive SQLite replay" begin
    mktempdir() do root
        workspace = joinpath(root, "work")
        mkpath(workspace)
        workspace = realpath(workspace)
        agentdir = joinpath(root, "agent")
        normal = putskill(workspace, "normal", "# Heading\n\nFollow the instructions.")
        hidden = putskill(workspace, "hidden", "Only when requested."; explicit=true)
        commands = ["/skill:normal first  input", "/skill:hidden do it", "/skill:missing nope", "/skill:normal\tno", "/skill:normal"]
        normalblock = block("normal", normal, "# Heading\n\nFollow the instructions.")
        hiddenblock = block("hidden", hidden, "Only when requested.")
        expected = [normalblock * "\n\nfirst  input", hiddenblock * "\n\ndo it", commands[3], commands[4], normalblock]
        if haskey(ENV, "PI_SOURCE")
            source = ENV["PI_SOURCE"]
            @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
            mktemp() do path, io
                JSON3.write(io, (; cwd=workspace, agentDir=agentdir, commands))
                flush(io)
                cmd = addenv(`node $(joinpath(@__DIR__, "skill_commands_reference.mjs")) $source $path`, "HOME" => root, "PI_CODING_AGENT_DIR" => agentdir)
                @test JSON3.read(read(cmd, String), Vector{String}) == expected
            end
        end
        requests = joinpath(root, "requests.jsonl")
        historypath = joinpath(root, "history.sqlite")
        result = session(workspace, agentdir, requests, historypath, commands)
        @test result.status == 0
        observed = JSON3.read.(readlines(requests))
        prompts = [last([message.content for message in request if message.role == "user"]) for request in observed]
        @test prompts == expected
        system = join([message.content for message in first(observed) if message.role == "system"], "\n")
        @test occursin("<name>normal</name>", system)
        @test !occursin("<name>hidden</name>", system)
        history = open(H.SQLite, historypath)
        try
            restored = Agent(nothing, []; history)
            @test [message.content for message in restored.state.messages if message isa C.User] == expected
        finally
            close(history)
        end
    end
end

@testset "skill command snapshots update on new session and reload" begin
    mktempdir() do root
        workspace = joinpath(root, "work")
        mkpath(workspace)
        workspace = realpath(workspace)
        normal = putskill(workspace, "normal", "Original body.")
        hidden = putskill(workspace, "hidden", "Hidden body."; explicit=true)
        putskill(workspace, "broken", "Valid body.")
        added = joinpath(workspace, ".pi", "skills", "added", "SKILL.md")
        later = joinpath(workspace, ".pi", "skills", "later", "SKILL.md")
        requests = joinpath(root, "requests.jsonl")
        commands = ["/skill:normal first", "/skill:normal second", "/skill:added before", "/skill:hidden removed", "/skill:broken invalid", "/new", "/skill:added after-new", "/skill:later before", "/reload", "/skill:later after", "/skill:hidden after"]
        result = session(workspace, joinpath(root, "agent"), requests, joinpath(root, "history.sqlite"), commands; fixture="skill_commands_process.jl")
        @test result.status == 0
        captured = JSON3.read.(readlines(requests))
        prompts = [last([message.content for message in request if message.role == "user"]) for request in captured]
        @test prompts == [block("normal", normal, "Original body.") * "\n\nfirst", block("normal", normal, "Updated body.") * "\n\nsecond", "/skill:added before", "/skill:hidden removed", "/skill:broken invalid", block("added", added, "Added body.") * "\n\nafter-new", "/skill:later before", block("later", later, "Later body.") * "\n\nafter", "/skill:hidden after"]
        if length(captured) == 9
            system = join([message.content for message in captured[8] if message.role == "system"], "\n")
            @test occursin("<name>added</name>", system)
            @test !occursin("<name>later</name>", system)
        end
        @test occursin("Reloaded skills.", result.diagnostics)
        @test occursin("Could not read requested skill", result.diagnostics)
        @test occursin("Could not parse requested skill", result.diagnostics)
    end
end

@testset "skill commands expand in JSON mode" begin
    mktempdir() do root
        workspace = joinpath(root, "work")
        mkpath(workspace)
        workspace = realpath(workspace)
        path = putskill(workspace, "hidden", "JSON instructions."; explicit=true)
        requests = joinpath(root, "requests.jsonl")
        project = dirname(@__DIR__)
        script = joinpath(@__DIR__, "session_cli_process.jl")
        cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project $script --mode json --no-session '/skill:hidden use JSON'`; dir=workspace)
        cmd = addenv(cmd, "HOME" => root, "JULIA_DEPOT_PATH" => join(DEPOT_PATH, Sys.iswindows() ? ';' : ':'), "PI_CODING_AGENT_DIR" => joinpath(root, "agent"), "JF_PROVIDER" => "openai", "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => "synthetic", "JF_SESSION_REQUESTS" => requests, "JF_INSTRUCTIONS_DIR" => nothing)
        input, output, diagnostics = joinpath.((root,), ("stdin", "stdout", "stderr"))
        write(input, "")
        process = run(pipeline(ignorestatus(cmd); stdin=input, stdout=output, stderr=diagnostics))
        @test success(process)
        records = JSON3.read.(readlines(output))
        message = only(record.message for record in records if record.type == "message_end" && record.message.role == "user")
        expected = block("hidden", path, "JSON instructions.") * "\n\nuse JSON"
        @test message.content[1].text == expected
        request = JSON3.read(only(readlines(requests)))
        @test last([item.content for item in request if item.role == "user"]) == expected
    end
end

mutable struct FailingHistory <: H.Store
    memory::H.Memory
    fail::Bool
end
H.snapshot(history::FailingHistory) = H.snapshot(history.memory)
function H.append!(history::FailingHistory, revision::Integer, batch::Vector)
    history.fail && throw(SystemError("fixture", Int32(5)))
    H.append!(history.memory, revision, batch)
end

@testset "failed reload preserves skill commands" begin
    mktempdir() do path
        root = realpath(path)
        cd(root) do
            withenv("HOME" => root, "PI_CODING_AGENT_DIR" => joinpath(root, "agent"), "JF_INSTRUCTIONS_DIR" => nothing) do
                old = putskill(root, "old", "Old body.")
                skills = JuliaForever.Skills
                resources = skills.Resources(Dict{String, String}(), skills.load(root))
                history = FailingHistory(H.Memory(), false)
                terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), String[])
                seed = Agent(nothing, [])
                agent = Agent(nothing, [], JuliaForever.initial(seed, nothing); history)
                before = deepcopy(agent.messages)
                putskill(root, "added", "Added body.")
                history.fail = true
                _, _, status = JuliaForever.reload!(terminal, agent, history, resources)
                @test status == 1 && agent.messages == before
                @test JuliaForever.Prompts.expand("/skill:old", resources) == block("old", old, "Old body.")
                @test JuliaForever.Prompts.expand("/skill:added", resources) == "/skill:added"
            end
        end
    end
end

end
