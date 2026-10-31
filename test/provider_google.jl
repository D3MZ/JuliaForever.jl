using HTTP, JSON3

googlesse(data) = "data: $(JSON3.write(data))\n\n"

function google_chunks()
    [
        Dict("candidates" => [Dict("content" => Dict("role" => "model", "parts" => [Dict("thought" => true, "text" => "thinking")]))]),
        Dict("candidates" => [Dict("content" => Dict("role" => "model", "parts" => [Dict("text" => "hello")]))]),
        Dict("candidates" => [Dict("content" => Dict("role" => "model", "parts" => [Dict("functionCall" => Dict("id" => "call-1", "name" => "write", "args" => Dict("path" => "a.txt", "content" => "ok")), "thoughtSignature" => "c2lnbmVk")]), "finishReason" => "STOP")], "usageMetadata" => Dict("promptTokenCount" => 20, "cachedContentTokenCount" => 3, "candidatesTokenCount" => 4, "thoughtsTokenCount" => 2, "totalTokenCount" => 26))
    ]
end

if haskey(ENV, "PI_SOURCE")
    include("provider_google_differential.jl")
end
