using Test, JuliaForever

@testset "ChatGPT terminal model selection" begin
    mktempdir() do directory
        store = JuliaForever.ChatGPT.Store(directory)
        C = JuliaForever.ChatGPT
        credential = C.Session("client", C.Identity("subject", nothing), "access", "refresh", "id", C.direct, 2000.0)
        C.save(store, credential)
        model = JuliaForever.ManagedChatGPT(store, "client", "subject", "first-model", String[]; now=() -> 1000.0, catalog=session -> ["first-model", "second-model"])
        @test [item.id for item in JuliaForever.LiveTerminal.modeloptions(nothing, model)] == ["first-model", "second-model"]
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
        end
    end
end
