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

mutable struct FailingHistory <: H.Store
    memory::H.Memory
    fail::Bool
end
H.snapshot(history::FailingHistory) = H.snapshot(history.memory)
function H.append!(history::FailingHistory, revision::Integer, batch::Vector)
    history.fail && throw(SystemError("fixture", Int32(5)))
    H.append!(history.memory, revision, batch)
end

end
