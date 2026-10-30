using JSON3

value = "\U00010000\U0010fffd"
for line in eachline(stdin)
    request = JSON3.read(codeunits(line), Dict{String, Any})
    haskey(request, "id") || continue
    result = if request["method"] == "initialize"
        Dict("protocolVersion" => "2025-11-25", "capabilities" => Dict("tools" => Dict()), "serverInfo" => Dict("name" => "fixture", "version" => "1"))
    else
        Dict("content" => [Dict("type" => "text", "text" => value)])
    end
    response = JSON3.write(Dict("jsonrpc" => "2.0", "id" => request["id"], "result" => result))
    if Sys.isunix() && occursin(value, response)
        write(response * "\n", "{}")
    end
    println(response)
    flush(stdout)
end
