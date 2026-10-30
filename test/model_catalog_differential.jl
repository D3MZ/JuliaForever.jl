using Test, JuliaForever, JSON3, HTTP

function modelreference(source, data, parse=JSON3.read)
    mktemp() do path, io
        JSON3.write(io, data)
        close(io)
        script = joinpath(@__DIR__, "model_catalog_pi.mjs")
        parse(read(`node --conditions=source --experimental-strip-types $script $source $path`))
    end
end

modelrow(model) = (; provider=String(model.provider), id=String(model.id), contextWindow=Int(model.context), maxTokens=Int(model.maxoutput), reasoning=Bool(model.reasoning), input=Bool(model.images) ? ["text", "image"] : ["text"])

@testset "Pi model references" begin
    source = ENV["PI_SOURCE"]
    @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    fixture = [
        (; provider="openai", id="alpha", name="Alpha"),
        (; provider="gateway", id="openai/alpha", name="Gateway Alpha"),
        (; provider="gateway", id="vendor/model:exacto", name="Vendor Model"),
        (; provider="one", id="shared", name="Shared"),
        (; provider="two", id="shared", name="Shared"),
        (; provider="anthropic", id="sonnet-4-20250929", name="Sonnet 4 snapshot"),
        (; provider="anthropic", id="sonnet-4", name="Sonnet 4"),
        (; provider="punct", id="sample:beta", name="Sample beta"),
        (; provider="punct", id="sample.beta", name="Sample beta"),
    ]
    cases = [
        (; text="alpha", provider=nothing, usable=["openai"]),
        (; text="OPENAI/ALPHA", provider=nothing, usable=["openai"]),
        (; text="openai/alpha", provider=nothing, usable=["gateway"]),
        (; text="shared", provider=nothing, usable=["one"]),
        (; text="shared", provider=nothing, usable=["one", "two"]),
        (; text="shared", provider=nothing, usable=String[]),
        (; text="vendor/model:exacto", provider=nothing, usable=["gateway"]),
        (; text="sonnet", provider="anthropic", usable=String[]),
        (; text="sonnet-4:high", provider="anthropic", usable=String[]),
        (; text="anthropic/new-model:high", provider=nothing, usable=String[]),
        (; text="unknown", provider=nothing, usable=String[]),
        (; text="sample", provider="punct", usable=String[]),
    ]
    reference = modelreference(source, (; models=fixture, cases), text -> JSON3.read(text, Vector{Dict{String, Any}}))
    @test getindex.(reference, "status") == ["resolved", "resolved", "resolved", "resolved", "ambiguous", "ambiguous", "resolved", "resolved", "resolved", "not-found", "not-found", "resolved"]
    M = JuliaForever.Models
    models = [M.Model(row.provider, row.id, row.name) for row in fixture]
    target(::Nothing) = nothing
    target(value::M.Target) = Dict("provider" => value.provider, "id" => value.id, "thinking" => value.thinking)
    describe(value::M.Resolved) = Dict("status" => "resolved", "provider" => value.model.provider, "id" => value.model.id, "thinking" => value.thinking)
    describe(value::M.Ambiguous) = Dict("status" => "ambiguous", "candidates" => sort([model.provider * "/" * model.id for model in value.models]), "usable" => value.usable, "thinking" => value.thinking)
    describe(value::M.Unmatched) = Dict("status" => "not-found", "target" => target(value.target))
    observed = [describe(M.resolve(case.text, models, Set(case.usable); provider=case.provider)) for case in cases]
    @test observed == reference

    catalog = JSON3.read(read(joinpath(@__DIR__, "..", "data", "models.json")))
    available = [modelrow(model) for model in catalog if model.provider == "anthropic"]
    listing = "anthropic opus"
    expected = modelreference(source, (; models=available, listing))
    mktempdir() do dir
        project = dirname(@__DIR__)
        cmd = `$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --list-models $listing`
        cmd = addenv(cmd, "PI_CODING_AGENT_DIR" => dir, "ANTHROPIC_API_KEY" => "fixture", "OPENAI_API_KEY" => nothing, "OPENROUTER_API_KEY" => nothing, "GEMINI_API_KEY" => nothing)
        output, diagnostics = joinpath(dir, "output"), joinpath(dir, "diagnostics")
        process = run(pipeline(ignorestatus(cmd); stdout=output, stderr=diagnostics))
        @test (process.exitcode, read(output, String), read(diagnostics, String)) == (0, expected, "")
        jsoncmd = `$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode json --list-models $listing`
        jsoncmd = addenv(jsoncmd, "PI_CODING_AGENT_DIR" => dir, "ANTHROPIC_API_KEY" => "fixture", "OPENAI_API_KEY" => nothing, "OPENROUTER_API_KEY" => nothing, "GEMINI_API_KEY" => nothing)
        process = run(pipeline(ignorestatus(jsoncmd); stdout=output, stderr=diagnostics))
        @test (process.exitcode, read(output, String), read(diagnostics, String)) == (0, expected, "")
        unfiltered = modelreference(source, (; models=available, listing=""))
        for next in ("--no-session", "@ignored", "--")
            cmd = `$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --list-models $next`
            cmd = addenv(cmd, "PI_CODING_AGENT_DIR" => dir, "ANTHROPIC_API_KEY" => "fixture", "OPENAI_API_KEY" => nothing, "OPENROUTER_API_KEY" => nothing, "GEMINI_API_KEY" => nothing)
            process = run(pipeline(ignorestatus(cmd); stdout=output, stderr=diagnostics))
            @test (process.exitcode, read(output, String), read(diagnostics, String)) == (0, unfiltered, "")
        end
        help = `$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --list-models --help`
        process = run(pipeline(ignorestatus(help); stdout=output, stderr=diagnostics))
        @test process.exitcode == 0 && startswith(read(output, String), "jf [") && isempty(read(diagnostics, String))
    end

    router = filter(model -> model.provider == "openrouter", catalog)
    available = modelrow.(router)
    expected = modelreference(source, (; models=available, listing="openrouter"))
    actual = split(sprint(M.list, filter(model -> model.provider == "openrouter", M.catalog()), "openrouter"), '\n')
    wanted = split(expected, '\n')
    @test length(actual) == length(wanted)
    differences = [(index, left, right) for (index, (left, right)) in enumerate(zip(actual, wanted)) if left != right]
    @test first(differences, 5) == []

    query = "anthropic/claude-opus"
    modelcase = [(; text=query, provider=nothing, usable=["anthropic"])]
    choice = only(modelreference(source, (; models=catalog, cases=modelcase)))
    requests = []
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        body = JSON3.read(codeunits(String(request.body)))
        push!(requests, (; path=request.target, model=String(body.model)))
        if request.target == "/responses"
            delta = JSON3.write((; type="response.output_text.delta", delta="ok"))
            output = [(; type="message", content=[(; type="output_text", text="ok")])]
            done = JSON3.write((; type="response.completed", response=(; status="completed", output)))
            return HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $delta\n\ndata: $done\n\n")
        end
        events = [Dict("type" => "message_start", "message" => Dict("usage" => Dict())), Dict("type" => "content_block_start", "index" => 0, "content_block" => Dict("type" => "text", "text" => "ok")), Dict("type" => "content_block_stop", "index" => 0), Dict("type" => "message_delta", "delta" => Dict("stop_reason" => "end_turn")), Dict("type" => "message_stop")]
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], join("data: $(JSON3.write(event))\n\n" for event in events))
    end
    try
        mktempdir() do dir
            project = dirname(@__DIR__)
            cmd = `$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --no-session --model $query hello`
            cmd = addenv(cmd, "PI_CODING_AGENT_DIR" => dir, "ANTHROPIC_API_KEY" => "fixture", "ANTHROPIC_BASE_URL" => "http://$(HTTP.server_addr(server))", "OPENAI_API_KEY" => nothing, "OPENROUTER_API_KEY" => nothing, "GEMINI_API_KEY" => nothing, "JF_INSTRUCTIONS_DIR" => dir)
            output, diagnostics = joinpath(dir, "output"), joinpath(dir, "diagnostics")
            input = joinpath(dir, "input")
            write(input, "")
            process = run(pipeline(ignorestatus(cmd); stdin=input, stdout=output, stderr=diagnostics))
            @test (process.exitcode, read(output, String), read(diagnostics, String)) == (0, "ok\n", "")
            @test requests == [(; path="/v1/messages", model=String(choice.id))]

            modelcase = [(; text="claude-opus", provider="ANTHROPIC", usable=["anthropic"])]
            uppercase_choice = only(modelreference(source, (; models=catalog, cases=modelcase)))
            cmd = `$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --no-session --provider ANTHROPIC --model claude-opus hello`
            cmd = addenv(cmd, "PI_CODING_AGENT_DIR" => dir, "ANTHROPIC_API_KEY" => "fixture", "ANTHROPIC_BASE_URL" => "http://$(HTTP.server_addr(server))", "OPENAI_API_KEY" => nothing, "OPENROUTER_API_KEY" => nothing, "GEMINI_API_KEY" => nothing, "JF_INSTRUCTIONS_DIR" => dir)
            before = length(requests)
            process = run(pipeline(ignorestatus(cmd); stdin=input, stdout=output, stderr=diagnostics))
            @test (process.exitcode, read(output, String), read(diagnostics, String)) == (0, "ok\n", "")
            @test length(requests) == before + 1 && last(requests) == (; path="/v1/messages", model=String(uppercase_choice.id))

            query = "openai/gpt-4"
            modelcase = [(; text=query, provider=nothing, usable=["openai"])]
            reference = only(modelreference(source, (; models=catalog, cases=modelcase)))
            cmd = `$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --no-session --model $query hello`
            cmd = addenv(cmd, "PI_CODING_AGENT_DIR" => dir, "OPENAI_API_KEY" => "fixture", "OPENAI_BASE_URL" => "http://$(HTTP.server_addr(server))", "ANTHROPIC_API_KEY" => nothing, "OPENROUTER_API_KEY" => nothing, "GEMINI_API_KEY" => nothing, "JF_INSTRUCTIONS_DIR" => dir)
            process = run(pipeline(ignorestatus(cmd); stdin=input, stdout=output, stderr=diagnostics))
            @test (process.exitcode, read(output, String), read(diagnostics, String)) == (0, "ok\n", "")
            @test last(requests) == (; path="/responses", model=String(reference.id))
        end
    finally
        close(server)
        wait(server)
    end
end
