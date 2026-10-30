using JSON3

# Input is the generated data distributed with the pinned Pi package.
const providers = (
    "anthropic" => "anthropic-messages",
    "google" => "google-generative-ai",
    "openai" => "openai-responses",
    "openrouter" => "openai-completions",
)

function catalog(directory)
    models = JSON3.Object[]
    for (provider, api) in providers
        groups = JSON3.read(read(joinpath(directory, provider * ".json")))
        for model in values(groups[api])
            get(model, "type", "") == "chat" && push!(models, model)
        end
    end
    models
end

open(ARGS[2], "w") do io
    models = catalog(ARGS[1])
    println(io, "[")
    for (index, model) in enumerate(models)
        print(io, "  ", JSON3.write(model))
        println(io, index == length(models) ? "" : ",")
    end
    println(io, "]")
end
