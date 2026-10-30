using Test, JuliaForever, HTTP, JSON3

@testset "ChatGPT login options reject mixed providers" begin
    mktempdir() do directory
        project = dirname(@__DIR__)
        for args in (["--login-chatgpt", "--login-openrouter"], ["--login-openrouter", "--login-chatgpt"])
            cmd = `$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever $args`
            cmd = addenv(cmd, "JF_CHATGPT_DIR" => directory)
            diagnostics = joinpath(directory, "error.txt")
            process = run(pipeline(ignorestatus(cmd); stdout=devnull, stderr=diagnostics))
            @test process.exitcode == 2
            @test occursin("login mode", read(diagnostics, String))
        end
    end
end

@testset "ChatGPT terminal model selection" begin
    mktempdir() do directory
        store = JuliaForever.ChatGPT.Store(directory)
        C = JuliaForever.ChatGPT
        credential = C.Session("client", C.Identity("subject", nothing), "access", "refresh", "id", C.direct, 2000.0)
        C.save(store, credential)
        requests = []
        request = (url, headers; kwargs...) -> begin
            push!(requests, (; url, headers))
            models = [(; visibility="hidden", slug="hidden", display_name="Hidden"), (; visibility="list", slug="first-model", display_name="First Model"), (; visibility="list", slug="second-model")]
            HTTP.Response(200, [], JSON3.write((; models)))
        end
        model = JuliaForever.ManagedChatGPT(store, "client", "subject", "first-model", String[]; now=() -> 1000.0, catalog=session -> JuliaForever.chatgptmodels(session; request))
        options = JuliaForever.LiveTerminal.modeloptions(nothing, model)
        @test options == [(; id="first-model", name="First Model"), (; id="second-model", name="second-model")]
        @test JuliaForever.choosechatgptmodel(options) == "first-model"
        @test only(requests).url == "https://api.openai.com/v1/models"
        @test only(requests).headers == ["Authorization" => "Bearer access"]
        agent = Agent(model, JuliaForever.Tool[])
        terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), String[])
        @test JuliaForever.LiveTerminal.modelname(model) == "first-model"
        changed, _, status = JuliaForever.setmodel!(terminal, agent, nothing, "second-model")
        @test status == 0
        @test changed.provider.model == "second-model"
        @test changed.provider.client == model.client && changed.provider.store === model.store
    end
end

@testset "ChatGPT terminal modes" begin
    if Sys.isunix()
        mktempdir() do directory
            C = JuliaForever.ChatGPT
            store = C.Store(joinpath(directory, "chatgpt"))
            credential = C.Session("client", C.Identity("subject", nothing), "fixture-access", "fixture-refresh", "fixture-id", C.direct, time() + 3600)
            C.save(store, credential)
            cmd = `python3 $(joinpath(@__DIR__, "chatgpt_ui_pty.py")) $(first(Base.julia_cmd().exec)) $(dirname(@__DIR__)) $directory`
            @test occursin("terminal modes passed", read(cmd, String))
            picker = `python3 $(joinpath(@__DIR__, "chatgpt_picker_pty.py")) $(first(Base.julia_cmd().exec)) $(dirname(@__DIR__)) $directory`
            @test occursin("model picker passed", read(picker, String))
        end
    end
end
