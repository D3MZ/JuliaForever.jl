using JSON3

# Input: pinned pi-ai dist/providers/data/openai.json.
source = JSON3.read(read(ARGS[1]), Dict{String, Any})
models = source["openai-responses"]
levels = Dict(model["id"] => model["thinkingLevelMap"] for model in values(models) if get(model, "reasoning", false) && haskey(model, "thinkingLevelMap"))
open(ARGS[2], "w") do io
    JSON3.pretty(io, levels)
    println(io)
end
