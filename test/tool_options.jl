using Test, JuliaForever, JSON3

@testset "CLI tool loadouts match Pi" begin
    cases = [String[], ["--no-tools"], ["--no-builtin-tools"], ["--tools", "read,grep"], ["--tools", "gr*"], ["--tools", "+grep,-write"], ["--tools", "+grep,-greet"], ["--exclude-tools", "*it*,greet"], ["--no-tools", "--tools", "+read,+greet"], ["--no-builtin-tools", "--tools", "+grep"], ["--no-tools", "--tools", "read,grep"], ["--tools", ""], ["--tools", "read,+grep"], ["--tools", "-gr*"], ["--tools", "greet", "--exclude-tools", "gr*"], ["--tools", "read", "--tools", "write"], ["-nt"], ["-nbt"], ["-t", "powershell"], ["-t", "+grep,-write", "-xt", "gre*"], ["-t", "*", "-xt", "g*"], ["--tools", "read,+grep", "--tools", "read"], ["--exclude-tools", "read", "--exclude-tools", "write"], ["--no-tools", "--no-builtin-tools"], ["--tools", "r.ead"], ["--tools", "--no-tools"], ["--tools", "read", "--exclude-tools", "--no-tools"], ["--no-tools", "--tools", "--no-builtin-tools"]]
    @testset "Pi oracle" begin
        expected = [(; tools=["bash", "edit", "greet", "read", "write"]), (; tools=String[]), (; tools=["greet"]), (; tools=["grep", "read"]), (; tools=["greet", "grep"]), (; tools=["bash", "edit", "greet", "grep", "read"]), (; tools=["bash", "edit", "greet", "grep", "read", "write"]), (; tools=["bash", "read"]), (; tools=["greet", "read"]), (; tools=["greet", "grep"]), (; tools=["grep", "read"]), (; tools=String[]), (; errors=["mixed"]), (; errors=["wildcard modifier"]), (; tools=String[]), (; tools=["write"]), (; tools=String[]), (; tools=["greet"]), (; tools=["powershell"]), (; tools=["bash", "edit", "read"]), (; tools=["bash", "edit", "find", "ls", "powershell", "read", "write"]), (; errors=["mixed"]), (; tools=["bash", "edit", "greet", "read"]), (; tools=String[]), (; tools=String[]), (; tools=["bash", "edit", "greet", "read", "write"]), (; tools=["read"]), (; tools=String[])]
        if haskey(ENV, "PI_SOURCE")
            pi = ENV["PI_SOURCE"]
            @test readchomp(`git -C $pi rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
            script = joinpath(@__DIR__, "tool_options_pi.mjs")
            expected = JSON3.read(read(`node $script $pi $(JSON3.write(cases))`, String))
        end
        mktempdir() do root
            casesfile = joinpath(root, "cases.json")
            observations = joinpath(root, "observations.jsonl")
            statuses = joinpath(root, "statuses.jsonl")
            write(casesfile, JSON3.write(cases))
            project = dirname(@__DIR__)
            script = joinpath(@__DIR__, "tool_options_process.jl")
            cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project $script $casesfile`; dir=root)
            cmd = addenv(cmd, "JF_PROVIDER" => "openai", "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => "synthetic", "JF_TOOL_OBSERVATIONS" => observations, "JF_TOOL_STATUSES" => statuses, "JF_TEST_PLUGIN" => nothing, "JF_TOOL_EVENTS" => joinpath(root, "events-"), "JF_TEST_EVENTS" => nothing, "JF_INSTRUCTIONS_DIR" => root, "PI_CODING_AGENT_DIR" => joinpath(root, "agent"))
            process = run(pipeline(ignorestatus(cmd); stdout=devnull, stderr=devnull))
            @test process.exitcode == 0
            status = Dict(row.case => row.status for row in JSON3.read.(readlines(statuses)))
            observed = Dict(row.case => row for row in JSON3.read.(readlines(observations)))
            @test readlines(joinpath(root, "events-2")) == ["agent_start", "agent_end"]
            for (index, reference) in enumerate(expected)
                if haskey(reference, :errors)
                    @test status[index] != 0
                    @test !haskey(observed, index)
                else
                    @test status[index] == 0
                    @test sort!(String[observed[index].tools...]) == sort!(String[reference.tools...])
                    for name in observed[index].tools
                        @test occursin("- $name:", observed[index].system)
                    end
                    for name in setdiff(["read", "bash", "edit", "write", "ls", "find", "grep", "powershell", "greet"], String[observed[index].tools...])
                        @test !occursin("- $name:", observed[index].system)
                    end
                end
            end
        end
    end
end

@testset "tool flags restrict model and CodeMode tool calls" begin
    mktempdir() do root
        project = dirname(@__DIR__)
        script = joinpath(@__DIR__, "tool_policy_process.jl")
        output = joinpath(root, "outcomes.jsonl")
        statuses = joinpath(root, "statuses.jsonl")
        cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project $script`; dir=root)
        cmd = addenv(cmd, "JF_PROVIDER" => "openai", "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => "synthetic", "JF_POLICY_LOG" => output, "JF_POLICY_STATUSES" => statuses, "JF_POLICY_SESSIONS" => joinpath(root, "sessions"), "JF_INSTRUCTIONS_DIR" => root, "PI_CODING_AGENT_DIR" => joinpath(root, "agent"))
        process = run(pipeline(ignorestatus(cmd); stdout=devnull, stderr=devnull))
        @test process.exitcode == 0
        results = Dict(row.case => row.result for row in JSON3.read.(readlines(output)))
        codes = Dict(row.case => row.status for row in JSON3.read.(readlines(statuses)))
        @test all(iszero, values(codes))
        @test results[1].is_error && !isfile(joinpath(root, "direct-denied.txt"))
        @test !results[2].is_error && read(joinpath(root, "direct-allowed.txt"), String) == "written"
        @test occursin("Unknown tool: write", results[3].content) && !isfile(joinpath(root, "nested-denied.txt"))
        @test !results[4].is_error && read(joinpath(root, "nested-allowed.txt"), String) == "written"
        @test !results[5].is_error && read(joinpath(root, "saved-allowed.txt"), String) == "written"
        @test results[6].is_error && !isfile(joinpath(root, "resumed-denied.txt"))
        @test results[7].is_error && !isfile(joinpath(root, "mode-denied.txt"))
    end
end
