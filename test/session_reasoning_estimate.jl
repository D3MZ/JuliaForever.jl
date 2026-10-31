using Test, JuliaForever, HTTP, JSON3

function session_estimate_process(base, workspace, sessions, args)
    project = dirname(@__DIR__)
    cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project -m JuliaForever $args`; dir=workspace)
    cmd = addenv(cmd, "JF_SESSION_DIR" => sessions, "JF_INSTRUCTIONS_DIR" => nothing, "JF_PROVIDER" => "openai", "OPENAI_BASE_URL" => base, "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => "synthetic-session-key", "PI_SOURCE" => nothing)
    output = joinpath(workspace, "stdout")
    diagnostics = joinpath(workspace, "stderr")
    process = run(pipeline(ignorestatus(cmd); stdin=devnull, stdout=output, stderr=diagnostics))
    (; status=process.exitcode, output=read(output, String), diagnostics=read(diagnostics, String))
end
