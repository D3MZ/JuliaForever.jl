using Test, JuliaForever, JSON3

struct StoreGate <: JuliaForever.Tool
    entered::Channel{Int}
    gates::Vector{Channel{Nothing}}
end
StoreGate() = StoreGate(Channel{Int}(2), [Channel{Nothing}(1) for _ in 1:2])
JuliaForever.name(::StoreGate) = "store_gate"
JuliaForever.description(::StoreGate) = "Pause a store test."
JuliaForever.schema(::StoreGate) = Dict("type" => "object")
function JuliaForever.execute(gate::StoreGate, args)
    id = Int(args.id)
    put!(gate.entered, id)
    take!(gate.gates[id])
    ToolResult("released")
end

if haskey(ENV, "PI_SOURCE")
    include("codemode_store_differential.jl")
end
