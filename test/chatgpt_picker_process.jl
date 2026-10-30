using JuliaForever

const J = JuliaForever
root = ARGS[1]
store = J.ChatGPT.Store(joinpath(root, "picker-account"))
session = J.ChatGPT.Session("picker-client", J.ChatGPT.Identity("picker-subject", nothing), "fixture-access", "fixture-refresh", "fixture-id", J.ChatGPT.direct, time() + 3600)
J.ChatGPT.save(store, session)
catalog = session -> J.modeldata(Dict("models" => [Dict("visibility" => "list", "slug" => "first-model", "display_name" => "First Friendly"), Dict("visibility" => "list", "slug" => "second-model", "display_name" => "Second Friendly")]))
model = J.ManagedChatGPT(store, session.client, session.identity.subject, "first-model", String[]; catalog)
terminal = J.Terminal(stdout, stderr, model.secrets)
extensions = J.Extensions.snapshot(J.Extensions.Registry())
exit(J.runsession!(nothing, terminal, model, extensions, String[], root, nothing))
