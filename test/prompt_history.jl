module PromptHistoryTests

using Test, JuliaForever, JSON3, REPL
const C = JuliaForever.Conversation
const L = JuliaForever.LiveTerminal

@testset "restored user history matches Pi" begin
    user(text) = Dict{String, Any}("role" => "user", "content" => text, "timestamp" => 1)
    text(value) = Dict{String, Any}("type" => "text", "text" => value)
    image = Dict{String, Any}("type" => "image", "data" => "AA==", "mimeType" => "image/png")
    assistant = Dict{String, Any}("role" => "assistant", "content" => [text("not a prompt")], "api" => "openai-completions", "provider" => "fixture", "model" => "fixture", "stopReason" => "stop", "timestamp" => 2)
    records = [user("  first  "), assistant, user(Any[text("α"), image, text("β")]), user("repeat"), user("repeat"), user("  ")]
    messages = C.Message[C.User("  first  "), C.RawMessage(assistant), C.RawMessage(records[3]), C.User("repeat"), C.ImageUser("repeat", JuliaForever.Image[]), C.User("  ")]
    manyrecords = [user("prompt-$index") for index in 1:105]
    manymessages = C.Message[C.User("prompt-$index") for index in 1:105]
    cases = [(; records, messages, count=3), (; records=manyrecords, messages=manymessages, count=100)]
    actual = map(cases) do case
        history = REPL.REPLHistoryProvider(Dict{Symbol, REPL.LineEdit.Prompt}())
        foreach(message -> L.prompt!(history, message), case.messages)
        reverse(history.history)
    end
    @test actual[1] == ["repeat", "αβ", "first"]
    @test length(actual[2]) == 100 && first(actual[2]) == "prompt-105" && last(actual[2]) == "prompt-6"
    if haskey(ENV, "PI_SOURCE")
        source = ENV["PI_SOURCE"]
        @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
        mktemp() do path, io
            JSON3.write(io, [(; messages=case.records, count=case.count) for case in cases])
            flush(io)
            oracle = JSON3.read(read(`node $(joinpath(@__DIR__, "prompt_history_pi.mjs")) $source $path`, String), Vector{Vector{String}})
            @test actual == oracle
        end
    end
end

end
