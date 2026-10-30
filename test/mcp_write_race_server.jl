using JSON3

reply(id, result) = (println(stdout, JSON3.write(Dict("jsonrpc" => "2.0", "id" => id, "result" => result))); flush(stdout))
for line in eachline(stdin)
    message = JSON3.read(line, Dict{String, Any})
    method = get(message, "method", "")
    if method == "initialize"
        reply(message["id"], Dict("protocolVersion" => "2025-11-25", "capabilities" => Dict(), "serverInfo" => Dict("name" => "race", "version" => "1")))
    elseif method == "hold"
        if !isfile(ARGS[1])
            open(ARGS[1], "w") do io
                print(io, message["id"])
            end
        end
    elseif method == "release"
        id = parse(Int, read(ARGS[1], String))
        if length(ARGS) > 2
            close(stdin)
            @static if Sys.iswindows()
                ccall(:_close, Cint, (Cint,), 0)
            else
                ccall(:close, Cint, (Cint,), 0)
            end
        end
        println(stdout, JSON3.write(Dict("jsonrpc" => "2.0", "id" => 99, "method" => "ping")))
        reply(id, Dict("done" => true))
        open(ARGS[2], "w") do io
            print(io, "ready")
        end
        if length(ARGS) > 2
            while !isfile(ARGS[3])
                sleep(0.01)
            end
        end
        exit()
    end
end
