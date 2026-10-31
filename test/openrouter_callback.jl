using HTTP, JSON3, SHA, Base64

if haskey(ENV, "PI_SOURCE")
    include("openrouter_differential.jl")
end
