module TerminalExportTests

using Test, JuliaForever, JSON3, Base64

const project = dirname(@__DIR__)
const process = joinpath(@__DIR__, "terminal_process.jl")

function runterminal(directory, args, input; fixture="tool")
    capture = joinpath(directory, "capture.jsonl")
    cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project $process $args`; dir=directory)
    cmd = addenv(cmd, "JF_INSTRUCTIONS_DIR" => directory, "JF_SESSION_DIR" => joinpath(directory, "sessions"), "JF_FIXTURE" => fixture, "JF_CAPTURE" => capture, "JF_PROVIDER" => "openai", "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => "synthetic-secret")
    out, err = IOBuffer(), IOBuffer()
    result = run(pipeline(ignorestatus(cmd); stdin=IOBuffer(input), stdout=out, stderr=err))
    (; status=result.exitcode, output=String(take!(out)), diagnostics=String(take!(err)), capture)
end

@testset "export active terminal session" begin
    mktempdir() do root
        history = joinpath(root, "history.sqlite")
        html = joinpath(root, "saved view.html")
        jsonl = joinpath(root, "nested", "saved branch.jsonl")
        existing = joinpath(root, "existing.html")
        write(existing, "keep")
        alias = joinpath(root, "alias.jsonl")
        Sys.isunix() && symlink(existing, alias)
        linkcommand = Sys.isunix() ? "/export \"$alias\"\n" : ""
        commands = "inspect\n/export\n/export \"$html\"\n/export '$jsonl'\n/export \"$existing\"\n" * linkcommand * "/export \"unterminated\n/exit\n"
        result = runterminal(root, ["--history", history], commands)
        @test isfile(joinpath(root, "pi-session-history.html"))
        @test isfile(html)
        @test isfile(jsonl)
        @test read(existing, String) == "keep"
        @test !ispath(joinpath(root, "\"unterminated"))
        @test occursin("Session exported to:", result.diagnostics)
        @test length(readlines(result.capture)) == 2
        if isfile(html)
            page = read(html, String)
            @test occursin("inspect", page) && occursin("Before", page) && occursin("after", page)
        end
        if isfile(jsonl)
            entries = [JSON3.read(line) for line in readlines(jsonl)]
            @test entries[1].type == "session" && entries[1].version == 3
            @test [entry.message.role for entry in entries[2:end] if entry.type == "message"] == ["user", "assistant", "toolResult", "assistant"]
            if haskey(ENV, "PI_SOURCE")
                oracle = JSON3.read(read(`node $(joinpath(@__DIR__, "terminal_export_pi.mjs")) $(ENV["PI_SOURCE"]) $jsonl`, String))
                @test oracle.roles == ["user", "assistant", "toolResult", "assistant"]
                @test oracle.contents[1][1].text == "inspect"
                @test oracle.contents[end][1].text == "after"
            end
        end
    end
    mktempdir() do root
        html = joinpath(root, "no-session.html")
        jsonl = joinpath(root, "memory.jsonl")
        second = joinpath(root, "memory-again.jsonl")
        result = runterminal(root, ["--no-session"], "/export $html\n/export $jsonl\n/export $second\n/exit\n"; fixture="echo")
        @test !isfile(html)
        @test isfile(jsonl)
        @test occursin("in-memory session", result.diagnostics)
        if isfile(jsonl)
            @test JSON3.read(first(readlines(jsonl))).type == "session"
        end
        if isfile(jsonl) && isfile(second)
            @test JSON3.read(first(readlines(jsonl))).id == JSON3.read(first(readlines(second))).id
        end
    end
    mktempdir() do root
        image = joinpath(root, "image.png")
        encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFgAI/ScL8AAAAAElFTkSuQmCC"
        write(image, base64decode(encoded))
        history = joinpath(root, "image.sqlite")
        first = runterminal(root, ["--history", history, "@image.png", "describe"], ""; fixture="echo")
        @test first.status == 0
        path = joinpath(root, "image.jsonl")
        runterminal(root, ["--history", history], "/export $path\n/exit\n"; fixture="echo")
        @test isfile(path)
        if isfile(path)
            entry = JSON3.read(readlines(path)[2])
            @test any(block -> block.type == "image" && block.mimeType == "image/png" && block.data == encoded, entry.message.content)
        end
    end
    mktempdir() do root
        path = joinpath(root, "blocks.jsonl")
        raw = Dict{String, Any}("role" => "user", "content" => [Dict("type" => "text", "text" => "look"), Dict("type" => "image_url", "image_url" => Dict("url" => "data:image/png;base64,aGVsbG8="))])
        call = Dict{String, Any}("role" => "assistant", "content" => [Dict("type" => "text", "text" => "Reading"), Dict("type" => "thinking", "thinking" => "Plan")], "tool_calls" => [Dict("id" => "one", "type" => "function", "function" => Dict("name" => "read", "arguments" => "{}"))])
        tool = Dict{String, Any}("role" => "tool", "tool_call_id" => "one", "content" => "image", "image" => Dict("mime" => "image/png", "data" => "aGVsbG8="))
        agent = Agent(nothing, JuliaForever.Tool[], [raw, call, tool])
        terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), String[])
        command = JuliaForever.terminalcommand("/export $path")
        JuliaForever.command!(command, terminal, agent, nothing, IOBuffer(), root, nothing)
        entry = JSON3.read(readlines(path)[2])
        @test entry.message.content[1].text == "look"
        @test entry.message.content[2].type == "image" && entry.message.content[2].data == "aGVsbG8="
        rows = JSON3.read.(readlines(path))
        @test rows[3].message.stopReason == "toolUse"
        @test rows[3].message.content[2].thinking == "Plan" && rows[3].message.content[3].name == "read"
        @test rows[4].message.toolName == "read" && rows[4].message.content[2].data == "aGVsbG8="
        if haskey(ENV, "PI_SOURCE")
            oracle = JSON3.read(read(`node $(joinpath(@__DIR__, "terminal_export_pi.mjs")) $(ENV["PI_SOURCE"]) $path`, String))
            @test oracle.roles == ["user", "assistant", "toolResult"]
            @test oracle.contents[1][2].data == "aGVsbG8=" && oracle.contents[3][2].data == "aGVsbG8="
        end
    end
end

end
