using Test, JuliaForever

import JuliaForever.Kernel as K
import JuliaForever.Conversation as C

mutable struct FailsOnce
    calls::Int
end

function JuliaForever.complete(provider::FailsOnce, messages, tools)
    provider.calls += 1
    provider.calls == 1 && error("synthetic failure")
    completion("recovered")
end
