using Test, JSON3

@testset "headless ChatGPT provider" begin
    mktempdir() do directory
        project = dirname(@__DIR__)
        script = joinpath(@__DIR__, "headless_chatgpt_process.jl")
        function runmode(mode, input)
            cmd = `$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project $script $mode`
            cmd = addenv(cmd, "HOME" => directory, "USERPROFILE" => directory, "PI_CODING_AGENT_DIR" => joinpath(directory, "agent"), "JF_INSTRUCTIONS_DIR" => directory)
            infile, outfile, errfile = joinpath.((directory,), (mode * "-in", mode * "-out", mode * "-err"))
            write(infile, input)
            process = run(pipeline(ignorestatus(cmd); stdin=infile, stdout=outfile, stderr=errfile))
            (; status=process.exitcode, output=read(outfile, String), diagnostics=read(errfile, String))
        end
        records(result) = [JSON3.read(line, Dict{String, Any}) for line in split(chomp(result.output), '\n') if !isempty(line)]
        json = runmode("json", "")
        @test json.status == 0
        @test any(item -> get(item, "type", "") == "agent_settled", records(json))
        @test any(item -> get(item, "type", "") == "message_end" && get(get(item, "message", Dict()), "model", "") == "fixture-model", records(json))
        cmd = `$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project $script rpc`
        cmd = addenv(cmd, "HOME" => directory, "USERPROFILE" => directory, "PI_CODING_AGENT_DIR" => joinpath(directory, "agent"), "JF_INSTRUCTIONS_DIR" => directory)
        process = open(pipeline(cmd; stderr=joinpath(directory, "rpc-error")), "r+")
        channel = Channel{Dict{String, Any}}(Inf)
        reader = @async for line in eachline(process)
            put!(channel, JSON3.read(line, Dict{String, Any}))
        end
        observed = Dict{String, Any}[]
        function receive(predicate)
            while true
                timedwait(() -> isready(channel), 45) == :ok || error("Timed out waiting for headless output")
                item = take!(channel)
                push!(observed, item)
                predicate(item) && return item
            end
        end
        try
            send(value) = (println(process, JSON3.write(value)); flush(process))
            send((; id="state", type="get_state"))
            state = receive(item -> get(item, "id", "") == "state")
            send((; id="models", type="get_available_models"))
            models = receive(item -> get(item, "id", "") == "models")
            send((; id="prompt", type="prompt", message="hello"))
            receive(item -> get(item, "type", "") == "agent_settled")
            @test state["data"]["model"] == Dict("id" => "fixture-model", "provider" => "chatgpt", "api" => "openai-responses", "baseUrl" => "https://api.openai.com/v1")
            @test !models["success"]
            @test any(item -> get(item, "type", "") == "message_end" && get(get(item, "message", Dict()), "model", "") == "fixture-model", observed)
        finally
            close(process.in)
            timedwait(() -> process_exited(process), 5) == :ok || kill(process)
            wait(process)
            wait(reader)
        end
    end
end
