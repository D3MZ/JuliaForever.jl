using Test, JuliaForever, HTTP, JSON3

function instructions_process(base, workspace, piagent; provider="openai", agentdir=nothing, input=nothing, options=String[])
    project = dirname(@__DIR__)
    session = "--history" in options ? String[] : ["--no-session"]
    args = [session; options; isnothing(input) ? ["inspect"] : String[]]
    cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project -m JuliaForever $args`; dir=workspace)
    cmd = addenv(cmd, "HOME" => piagent, "JULIA_DEPOT_PATH" => join(DEPOT_PATH, Sys.iswindows() ? ';' : ':'), "JF_PROVIDER" => provider, "OPENAI_BASE_URL" => base, "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => "synthetic-secret", "PI_CODING_AGENT_DIR" => piagent, "JF_INSTRUCTIONS_DIR" => agentdir)
    mktempdir() do dir
        stdinpath, output, diagnostics = joinpath.((dir,), ("stdin", "output", "diagnostics"))
        write(stdinpath, something(input, ""))
        process = run(pipeline(ignorestatus(cmd); stdin=stdinpath, stdout=output, stderr=diagnostics))
        (; status=process.exitcode, output=read(output, String), diagnostics=read(diagnostics, String))
    end
end

function check_tool_guidance(context, definitions)
    listed = [match.captures[1] for match in eachmatch(r"(?m)^- ([^:\n]+): ", context)]
    @test Set(listed) == Set(String(tool.name) for tool in definitions)
    for tool in definitions
        @test occursin("- $(tool.name): $(first(split(tool.description, '\n')))", context)
    end
end
