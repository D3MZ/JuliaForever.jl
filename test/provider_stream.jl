using HTTP, JSON3, Base64, SHA

sse(data) = "data: $(JSON3.write(data))\n\n"

if haskey(ENV, "PI_SOURCE")
    include("provider_differential.jl")
end
