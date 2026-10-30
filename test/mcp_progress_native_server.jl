using JSON3

const writer = ReentrantLock()
const pending = Dict{Int, Bool}()
const concurrent = Dict{Int, Int}()
const blocked_sent = Channel{Nothing}(1)
const overflow_sent = Channel{Nothing}(1)
function send(message)
    lock(writer) do
        println(stdout, JSON3.write(message))
        flush(stdout)
    end
end
reply(id, result) = send(Dict("jsonrpc" => "2.0", "id" => id, "result" => result))
progress(id, value) = send(Dict("jsonrpc" => "2.0", "method" => "notifications/progress", "params" => Dict("progressToken" => id, "progress" => value)))
function later(f, delay)
    @async begin
        sleep(delay)
        f()
    end
end

for line in eachline(stdin)
    message = JSON3.read(line, Dict{String, Any})
    method = get(message, "method", "")
    params = get(message, "params", Dict())
    id = get(message, "id", 0)
    if method == "initialize"
        reply(id, Dict("protocolVersion" => "2025-11-25", "capabilities" => Dict("tools" => Dict()), "serverInfo" => Dict("name" => "progress", "version" => "1")))
    elseif method == "notifications/cancelled"
        requestid = params["requestId"]
        if pop!(pending, requestid, false)
            progress(requestid, 99)
        end
    elseif method == "tools/call"
        later(() -> progress(id, 1), 0.02)
        later(() -> reply(id, Dict("content" => [], "structuredContent" => Dict("params" => params))), 0.1)
    elseif method == "metadata"
        reply(id, Dict("params" => params))
    elseif method == "nested"
        reply(id, Dict("nested" => true))
    elseif method == "concurrent"
        let requestid = id, label = params["label"]
            concurrent[label] = requestid
            later(() -> progress(requestid, label), 0.02 * (1 + mod(label, 4)))
        end
    elseif method == "ack"
        label = params["label"]
        reply(id, Dict("acknowledged" => label))
        reply(pop!(concurrent, label), Dict("label" => label))
    elseif method == "reentrant"
        later(() -> progress(id, 1), 0.02)
        later(() -> reply(id, Dict("done" => true)), 0.3)
    elseif method == "invalid-timeout"
        pending[id] = true
        for index in 1:12
            later(() -> progress(id, "invalid"), index * 0.18)
        end
    elseif method == "hold"
        pending[id] = true
        later(() -> progress(id, 1), 0.02)
    elseif method == "blocked"
        later(() -> progress(id, 1), 0.02)
        later(() -> (progress(id, 2); progress(id, 3)), 0.08)
        later(() -> (reply(id, Dict("done" => true)); put!(blocked_sent, nothing)), 0.15)
    elseif method == "blocked-barrier"
        @async begin
            take!(blocked_sent)
            reply(id, Dict("done" => true))
        end
    elseif method == "blocked-eof"
        later(() -> progress(id, 1), 0.02)
        later(0.1) do
            progress(id, 2)
            reply(id, Dict("done" => true))
            exit(0)
        end
    elseif method == "overflow"
        pending[id] = true
        later(() -> progress(id, 1), 0.02)
        later(0.08) do
            for index in 2:80
                progress(id, index)
            end
        end
        later(() -> (reply(id, Dict("done" => true)); put!(overflow_sent, nothing)), 0.3)
    elseif method == "overflow-barrier"
        @async begin
            take!(overflow_sent)
            reply(id, Dict("done" => true))
        end
    elseif method == "eof"
        later(() -> progress(id, 1), 0.02)
        later(() -> exit(0), 0.5)
    elseif method == "barrier"
        later(() -> reply(id, Dict("done" => true)), 0.1)
    end
end
