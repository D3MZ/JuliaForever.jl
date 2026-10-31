using Test, JuliaForever

function plugin_process(args; mode="plugin", plugin="", follow="", input="", history=nothing, compile=false, depot=nothing)
    project = dirname(@__DIR__)
    script = joinpath(@__DIR__, "terminal_process.jl")
    mktempdir() do dir
        events = joinpath(dir, "events")
        stdinpath, stdoutpath, stderrpath = joinpath.((dir,), ("stdin", "stdout", "stderr"))
        write(stdinpath, input)
        pathargs = isnothing(history) ? String[] : ["--history", history]
        compiled = compile ? String[] : ["--compiled-modules=existing"]
        cmd = `$(Base.julia_cmd()) --startup-file=no $compiled --project=$project $script $pathargs $args`
        separator = Sys.iswindows() ? ';' : ':'
        cmd = addenv(cmd, "JF_FIXTURE" => mode, "JF_PROVIDER" => "openai", "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => "synthetic-secret", "JF_TEST_PLUGIN" => plugin, "JF_TEST_FOLLOW" => follow, "JF_TEST_EVENTS" => events, "JULIA_LOAD_PATH" => join(("@", "@stdlib"), separator), "JF_INSTRUCTIONS_DIR" => dir)
        isnothing(depot) || (cmd = addenv(cmd, "JULIA_DEPOT_PATH" => join([depot; DEPOT_PATH], separator)))
        process = run(pipeline(ignorestatus(cmd); stdin=stdinpath, stdout=stdoutpath, stderr=stderrpath))
        (; status=process.exitcode, output=read(stdoutpath, String), diagnostics=read(stderrpath, String), events=isfile(events) ? readlines(events) : String[])
    end
end
