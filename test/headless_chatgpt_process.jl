using JuliaForever

const J = JuliaForever

function J.stream(provider::J.ManagedChatGPT, messages, tools; parameters=Dict(), on_event=identity)
    on_event((; type=:text, text="fixture reply"))
    Completion(Dict{String, Any}("role" => "assistant", "content" => "fixture reply"), nothing, "stop", true, nothing)
end

runmode(mode::J.JSONMode, terminal, agent, snapshot, history, directory) = J.LiveJSON.runmode!(terminal, agent, "hello", snapshot, identity, mode)
runmode(mode::J.RPCMode, terminal, agent, snapshot, history, directory) = J.Headless.rpc!(terminal, agent, snapshot, Ref(history), String[], directory, Dict{String, Any}())

mktempdir() do directory
    store = J.ChatGPT.Store(directory)
    provider = J.ManagedChatGPT(store, "fixture-client", "fixture-subject", "fixture-model", String[])
    snapshot = J.Extensions.snapshot(J.Extensions.Registry())
    history = J.History.Tree(J.History.Memory())
    agent = Agent(provider, snapshot; history)
    mode = Dict("json" => J.JSONMode("chatgpt"), "rpc" => J.RPCMode("chatgpt"))[ARGS[1]]
    terminal = J.Terminal(stdout, stderr, String[], mode)
    runmode(mode, terminal, agent, snapshot, history, directory)
end
