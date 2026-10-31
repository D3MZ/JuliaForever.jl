using Test, JuliaForever, HTTP, JSON3

function terminal_http(base, prompt; provider="openai", history=nothing, options=nothing)
    project = dirname(@__DIR__)
    options = isnothing(options) ? (isnothing(history) ? ["--no-session"] : ["--history", history]) : options
    cmd = addenv(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project -m JuliaForever $options $prompt`, "JF_PROVIDER" => provider, "OPENAI_BASE_URL" => base, "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => "synthetic-secret")
    mktempdir() do dir
        output, diagnostics = joinpath.((dir,), ("output", "diagnostics"))
        process = run(pipeline(ignorestatus(cmd); stdout=output, stderr=diagnostics))
        (; status=process.exitcode, output=read(output, String), diagnostics=read(diagnostics, String))
    end
end
