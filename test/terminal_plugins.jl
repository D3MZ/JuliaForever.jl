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

@testset "explicit native CLI plugins" begin
    fixture = joinpath(@__DIR__, "fixtures")
    selected = ["--plugin-env", fixture, "--plugin", "GreetingPlugin"]
    result = plugin_process([selected; "start"])
    @test result.status == 0
    @test result.output == "Before\nplugin:Hello, Ada!\n"
    @test result.events == ["agent_start", "tool_execution_end", "agent_end"]
    @test occursin("[tool] greet: started", result.diagnostics)
    @test occursin("[tool] greet: ok", result.diagnostics)

    restarted = plugin_process(["--no-session"; selected]; input="one\n/new\ntwo\n/exit\n")
    @test restarted.status == 0
    @test restarted.output == "Before\nplugin:Hello, Ada!\nBefore\nplugin:Hello, Ada!\n"
    @test restarted.events == repeat(["agent_start", "tool_execution_end", "agent_end"], 2)

    mktempdir() do dir
        cp(joinpath(fixture, "GreetingPlugin"), joinpath(dir, "GreetingPlugin"))
        fresh = plugin_process(["--plugin-env", dir, "--plugin", "GreetingPlugin", "start"]; compile=true, depot=joinpath(dir, "depot"))
        @test fresh.status == 0
        @test fresh.output == "Before\nplugin:Hello, Ada!\n"
        @test fresh.events == ["agent_start", "tool_execution_end", "agent_end"]
    end

    code = plugin_process(["--codemode"; selected; "start"]; mode="codeplugin")
    @test code.status == 0
    @test code.output == "Before\nplugin:Hello, Ada!\n"
    @test occursin("[tool] codemode: ok", code.diagnostics)

    two = plugin_process([selected; ["--plugin", "FollowPlugin", "start"]]; mode="two-plugins")
    @test two.status == 0
    @test two.output == "Before\nplugin:Hello, Ada!\n"
    @test two.events == ["agent_start", "follow:agent_start", "tool_execution_end", "follow:tool_execution_end", "agent_end", "follow:agent_end"]
    two_collision = plugin_process([selected; ["--plugin", "FollowPlugin", "start"]]; follow="collision")
    @test two_collision.status == 2
    @test occursin("FollowPlugin: duplicate_tool greet", two_collision.diagnostics)

    mktempdir() do dir
        history = joinpath(dir, "history.sqlite")
        recorded = plugin_process([selected; "start"]; history)
        @test recorded.status == 0
        @test recorded.events == ["agent_start", "tool_execution_end", "agent_end"]
        resumed = plugin_process([selected; "again"]; history)
        @test resumed.status == 0
        @test resumed.events == ["agent_start", "tool_execution_end", "agent_end"]
        inspected = plugin_process([selected; "--inspect-history"]; mode="echo", plugin="factory", history)
        @test inspected.status == 0
        @test isempty(inspected.events)
    end

    broken_hook = plugin_process([selected; "start"]; plugin="hook")
    @test broken_hook.status == 0
    @test broken_hook.events == ["agent_start", "tool_execution_end", "agent_end"]
    @test occursin("GreetingPlugin", broken_hook.diagnostics)
    @test occursin("agent_start", broken_hook.diagnostics)
    @test occursin("hook failure: [redacted]", broken_hook.diagnostics)
    @test !occursin("synthetic-secret", broken_hook.diagnostics)

    for mode in ("factory", "contribution")
        broken = plugin_process([selected; "start"]; plugin=mode)
        @test broken.status == 2
        @test occursin("GreetingPlugin", broken.diagnostics)
        @test occursin("$mode failure: [redacted]", broken.diagnostics)
        @test !occursin("synthetic-secret", broken.diagnostics)
        @test isempty(broken.events)
    end
    missing = plugin_process(["--plugin", "DoesNotExist", "start"])
    @test missing.status == 2
    @test occursin("DoesNotExist", missing.diagnostics)
    @test isempty(missing.output)
    collision = plugin_process([selected; "start"]; plugin="collision")
    @test collision.status == 2
    @test occursin("duplicate_tool", collision.diagnostics)
    @test occursin("read", collision.diagnostics)
    duplicate = plugin_process([selected; ["--plugin", "GreetingPlugin", "start"]])
    @test duplicate.status == 2
    @test occursin("duplicate_plugin", duplicate.diagnostics)
    @test isempty(duplicate.events)
    for option in ("--plugin", "--plugin-env")
        absent = plugin_process([option]; mode="echo")
        @test absent.status == 2
        @test occursin("requires", absent.diagnostics)
    end
    unselected = plugin_process(["--plugin-env", fixture, "ordinary"]; mode="echo", plugin="factory")
    @test unselected.status == 0
    @test unselected.output == "reply:ordinary\n"
    @test isempty(unselected.events)
end
