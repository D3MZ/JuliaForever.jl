module HeadlessDifferentialTests

using Test, JSON3, HTTP, Base64

function runprocess(cmd, input, env)
    mktempdir() do dir
        infile, outfile, errfile = joinpath.((dir,), ("input", "output", "error"))
        write(infile, input)
        process = run(pipeline(ignorestatus(addenv(cmd, env...)); stdin=infile, stdout=outfile, stderr=errfile))
        (; status=process.exitcode, output=read(outfile, String), diagnostics=read(errfile, String))
    end
end

function records(output)
    try
        [JSON3.read(line, Dict{String, Any}) for line in split(chomp(output), '\n') if !isempty(line)]
    catch
        Dict{String, Any}[]
    end
end

function responses(output)
    Dict(record["id"] => record for record in records(output) if get(record, "type", "") == "response" && haskey(record, "id"))
end

function receive!(channel, observed, predicate)
    while true
        timedwait(() -> isready(channel), 45) == :ok || error("Timed out waiting for RPC output")
        value = take!(channel)
        push!(observed, value)
        predicate(value) && return value
    end
end

function exchange(cmd, env; switching=false, protect=false)
    mktempdir() do dir
        diagnostics = joinpath(dir, "error")
        process = open(pipeline(addenv(cmd, env...); stderr=diagnostics), "r+")
        channel = Channel{Any}(Inf)
        reader = @async for line in eachline(process)
            put!(channel, JSON3.read(line, Dict{String, Any}))
        end
        observed = Any[]
        try
            println(process, JSON3.write((; id="prompt", type="prompt", message="hello")))
            flush(process)
            receive!(channel, observed, value -> value["type"] == "agent_settled")
            println(process, JSON3.write((; id="messages", type="get_messages")))
            flush(process)
            messages = receive!(channel, observed, value -> get(value, "id", "") == "messages")
            println(process, JSON3.write((; id="name", type="set_session_name", name=" Example ")))
            flush(process)
            name = receive!(channel, observed, value -> get(value, "id", "") == "name")
            println(process, JSON3.write((; id="state", type="get_state")))
            flush(process)
            state = receive!(channel, observed, value -> get(value, "id", "") == "state")
            println(process, JSON3.write((; id="stats", type="get_session_stats")))
            flush(process)
            stats = receive!(channel, observed, value -> get(value, "id", "") == "stats")
            exported = switching ? exportsession(process, channel, observed, state; protect) : nothing
            println(process, JSON3.write((; id="clone", type="clone")))
            flush(process)
            clone = receive!(channel, observed, value -> get(value, "id", "") == "clone")
            println(process, JSON3.write((; id="clone-state", type="get_state")))
            flush(process)
            clonestate = receive!(channel, observed, value -> get(value, "id", "") == "clone-state")
            fork = forksession(process, channel, observed)
            println(process, JSON3.write((; id="new", type="new_session")))
            flush(process)
            new = receive!(channel, observed, value -> get(value, "id", "") == "new")
            println(process, JSON3.write((; id="new-state", type="get_state")))
            flush(process)
            newstate = receive!(channel, observed, value -> get(value, "id", "") == "new-state")
            switched = switching ? switchback(process, channel, observed, state) : nothing
            (; observed, messages, name, state, stats, exported, clone, clonestate, fork, new, newstate, switched)
        finally
            close(process.in)
            timedwait(() -> process_exited(process), 5) == :ok || kill(process)
            wait(process)
            wait(reader)
        end
    end
end

function forksession(process, channel, observed)
    send(value) = (println(process, JSON3.write(value)); flush(process))
    send((; id="fork-entries", type="get_entries"))
    records = receive!(channel, observed, value -> get(value, "id", "") == "fork-entries")
    send((; id="fork-messages", type="get_fork_messages"))
    messages = receive!(channel, observed, value -> get(value, "id", "") == "fork-messages")
    entries = get(get(messages, "data", Dict()), "messages", [])
    entry = isempty(entries) ? "missing" : first(entries)["entryId"]
    send((; id="fork", type="fork", entryId=entry))
    reply = receive!(channel, observed, value -> get(value, "id", "") == "fork")
    send((; id="fork-state", type="get_state"))
    state = receive!(channel, observed, value -> get(value, "id", "") == "fork-state")
    send((; id="fork-invalid", type="fork", entryId="missing-entry"))
    invalid = receive!(channel, observed, value -> get(value, "id", "") == "fork-invalid")
    send((; id="fork-after-invalid", type="get_state"))
    after = receive!(channel, observed, value -> get(value, "id", "") == "fork-after-invalid")
    (; records, messages, reply, state, invalid, after)
end

function exportsession(process, channel, observed, state; protect=false)
    path = joinpath(dirname(state["data"]["sessionFile"]), "report.html")
    send(value) = (println(process, JSON3.write(value)); flush(process))
    send((; id="export", type="export_html", outputPath=path))
    reply = receive!(channel, observed, value -> get(value, "id", "") == "export")
    html = isfile(path) ? read(path, String) : ""
    send((; id="export-invalid", type="export_html", outputPath=joinpath(dirname(path), "missing", "report.html")))
    invalid = receive!(channel, observed, value -> get(value, "id", "") == "export-invalid")
    source = state["data"]["sessionFile"]
    before = protect ? read(source) : UInt8[]
    overwrite = if protect
        send((; id="export-source", type="export_html", outputPath=source))
        receive!(channel, observed, value -> get(value, "id", "") == "export-source")
    else
        nothing
    end
    unchanged = protect ? read(source) == before : true
    (; path, reply, html, invalid, overwrite, unchanged)
end
function pihtml(html)
    data = match(r"<script id=\"session-data\" type=\"application/json\">([^<]+)</script>", html)
    isnothing(data) ? "" : String(base64decode(data[1]))
end

function switchback(process, channel, observed, state)
    path = state["data"]["sessionFile"]
    send(value) = (println(process, JSON3.write(value)); flush(process))
    send((; id="switch", type="switch_session", sessionPath=path))
    reply = receive!(channel, observed, value -> get(value, "id", "") == "switch")
    send((; id="switched-state", type="get_state"))
    restored = receive!(channel, observed, value -> get(value, "id", "") == "switched-state")
    send((; id="switch-invalid", type="switch_session", sessionPath=dirname(path)))
    invalid = receive!(channel, observed, value -> get(value, "id", "") == "switch-invalid")
    send((; id="switch-after-invalid", type="get_state"))
    after = receive!(channel, observed, value -> get(value, "id", "") == "switch-after-invalid")
    (; reply, restored, invalid, after)
end

function exchangequeued(cmd, env, arrivals; image=false, protect=false)
    mktempdir() do dir
        process = open(pipeline(addenv(cmd, env...); stderr=joinpath(dir, "error")), "r+")
        channel = Channel{Any}(Inf)
        reader = @async for line in eachline(process)
            put!(channel, JSON3.read(line, Dict{String, Any}))
        end
        observed = Any[]
        held = Channel{Nothing}[]
        try
            send(value) = (println(process, JSON3.write(value)); flush(process))
            send((; id="prompt", type="prompt", message="hello"))
            first = receive!(channel, observed, value -> get(value, "id", "") == "prompt")
            timedwait(() -> isready(arrivals), 45) == :ok || error("Provider request did not start")
            firstgate = take!(arrivals)
            push!(held, firstgate)
            images = image ? [(; type="image", mimeType="image/png", data="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/aX0AAAAASUVORK5CYII=")] : []
            send((; id="steer", type="steer", message="change", images))
            steer = receive!(channel, observed, value -> get(value, "id", "") == "steer")
            send((; id="follow", type="follow_up", message="after", images))
            follow = receive!(channel, observed, value -> get(value, "id", "") == "follow")
            send((; id="busy", type="prompt", message="overlap"))
            busy = receive!(channel, observed, value -> get(value, "id", "") == "busy")
            if image
                send((; id="stream-image", type="prompt", message="stream", streamingBehavior="followUp", images))
                receive!(channel, observed, value -> get(value, "id", "") == "stream-image")
            end
            if protect
                for (id, type) in (("protected-clear", "clear_queue"), ("protected-clone", "clone"), ("protected-new", "new_session"))
                    send((; id, type))
                    reply = receive!(channel, observed, value -> get(value, "id", "") == id)
                    @test reply["success"] == false
                end
            end
            put!(firstgate, nothing)
            while true
                timedwait(() -> isready(arrivals) || isready(channel), 45) == :ok || error("RPC run did not settle")
                isready(arrivals) && put!(take!(arrivals), nothing)
                isready(channel) || continue
                event = take!(channel)
                push!(observed, event)
                event["type"] == "agent_settled" && break
            end
            send((; id="messages", type="get_messages"))
            messages = receive!(channel, observed, value -> get(value, "id", "") == "messages")
            send((; id="queue-entries", type="get_entries"))
            entries = receive!(channel, observed, value -> get(value, "id", "") == "queue-entries")
            send((; id="queue-forks", type="get_fork_messages"))
            forks = receive!(channel, observed, value -> get(value, "id", "") == "queue-forks")
            (; first, steer, follow, busy, messages, entries, forks, observed)
        finally
            for gate in held
                isready(gate) || put!(gate, nothing)
            end
            while isready(arrivals)
                put!(take!(arrivals), nothing)
            end
            close(process.in)
            timedwait(() -> process_exited(process), 5) == :ok || kill(process)
            wait(process)
            wait(reader)
        end
    end
end

function saveimagequeue(cmd, env, image)
    mktempdir() do dir
        process = open(pipeline(addenv(cmd, env...); stderr=joinpath(dir, "error")), "r+")
        channel = Channel{Any}(Inf)
        reader = @async for line in eachline(process)
            put!(channel, JSON3.read(line, Dict{String, Any}))
        end
        observed = Any[]
        try
            send(value) = (println(process, JSON3.write(value)); flush(process))
            send((; id="seed", type="prompt", message="seed"))
            receive!(channel, observed, value -> get(value, "type", "") == "agent_settled")
            send((; id="queue", type="steer", message="saved", images=[image]))
            receive!(channel, observed, value -> get(value, "id", "") == "queue")
        finally
            close(process.in)
            timedwait(() -> process_exited(process), 5) == :ok || kill(process)
            wait(process)
            wait(reader)
        end
    end
end

function exchangereplay(cmd, env)
    mktempdir() do dir
        process = open(pipeline(addenv(cmd, env...); stderr=joinpath(dir, "error")), "r+")
        channel = Channel{Any}(Inf)
        reader = @async for line in eachline(process)
            put!(channel, JSON3.read(line, Dict{String, Any}))
        end
        observed = Any[]
        try
            send(value) = (println(process, JSON3.write(value)); flush(process))
            send((; id="state", type="get_state"))
            state = receive!(channel, observed, value -> get(value, "id", "") == "state")
            send((; id="clear", type="clear_queue"))
            clear = receive!(channel, observed, value -> get(value, "id", "") == "clear")
            send((; id="prompt", type="prompt", message="resume"))
            receive!(channel, observed, value -> get(value, "type", "") == "agent_settled")
            send((; id="messages", type="get_messages"))
            messages = receive!(channel, observed, value -> get(value, "id", "") == "messages")
            (; state, clear, messages, observed)
        finally
            close(process.in)
            timedwait(() -> process_exited(process), 5) == :ok || kill(process)
            wait(process)
            wait(reader)
        end
    end
end

function exchangeallqueued(cmd, env, arrivals)
    mktempdir() do dir
        process = open(pipeline(addenv(cmd, env...); stderr=joinpath(dir, "error")), "r+")
        channel = Channel{Any}(Inf)
        reader = @async for line in eachline(process)
            put!(channel, JSON3.read(line, Dict{String, Any}))
        end
        observed = Any[]
        held = Channel{Nothing}[]
        try
            send(value) = (println(process, JSON3.write(value)); flush(process))
            for (id, type) in (("steer-mode", "set_steering_mode"), ("follow-mode", "set_follow_up_mode"))
                send((; id, type, mode="all"))
                receive!(channel, observed, value -> get(value, "id", "") == id)
            end
            send((; id="prompt", type="prompt", message="hello"))
            receive!(channel, observed, value -> get(value, "id", "") == "prompt")
            timedwait(() -> isready(arrivals), 45) == :ok || error("Provider request did not start")
            gate = take!(arrivals)
            push!(held, gate)
            for (id, type, message) in (("s1", "steer", "steer one"), ("s2", "steer", "steer two"), ("f1", "follow_up", "follow one"), ("f2", "follow_up", "follow two"))
                send((; id, type, message))
                receive!(channel, observed, value -> get(value, "id", "") == id)
            end
            put!(gate, nothing)
            calls = 1
            while true
                timedwait(() -> isready(arrivals) || isready(channel), 45) == :ok || error("RPC run did not settle")
                if isready(arrivals)
                    put!(take!(arrivals), nothing)
                    calls += 1
                end
                isready(channel) || continue
                event = take!(channel)
                push!(observed, event)
                event["type"] == "agent_settled" && break
            end
            send((; id="messages", type="get_messages"))
            messages = receive!(channel, observed, value -> get(value, "id", "") == "messages")
            (; calls, messages, observed)
        finally
            for gate in held
                isready(gate) || put!(gate, nothing)
            end
            while isready(arrivals)
                put!(take!(arrivals), nothing)
            end
            close(process.in)
            timedwait(() -> process_exited(process), 5) == :ok || kill(process)
            wait(process)
            wait(reader)
        end
    end
end

function exchangeaborted(cmd, env, arrivals)
    mktempdir() do dir
        process = open(pipeline(addenv(cmd, env...); stderr=joinpath(dir, "error")), "r+")
        channel = Channel{Any}(Inf)
        reader = @async for line in eachline(process)
            put!(channel, JSON3.read(line, Dict{String, Any}))
        end
        observed = Any[]
        gate = nothing
        try
            println(process, JSON3.write((; id="prompt", type="prompt", message="hello")))
            flush(process)
            receive!(channel, observed, value -> get(value, "id", "") == "prompt")
            timedwait(() -> isready(arrivals), 45) == :ok || error("Provider request did not start")
            gate = take!(arrivals)
            println(process, JSON3.write((; id="abort", type="abort")))
            flush(process)
            reply = receive!(channel, observed, value -> get(value, "id", "") == "abort")
            settled = filter(value -> value["type"] == "agent_settled", observed)
            isempty(settled) && push!(settled, receive!(channel, observed, value -> value["type"] == "agent_settled"))
            (; reply, settled=only(settled), observed)
        finally
            isnothing(gate) || put!(gate, nothing)
            while isready(arrivals)
                put!(take!(arrivals), nothing)
            end
            close(process.in)
            timedwait(() -> process_exited(process), 5) == :ok || kill(process)
            wait(process)
            wait(reader)
        end
    end
end

function exchangebash(cmd, env; promptafter=false, sessiondir=nothing)
    mktempdir() do dir
        process = open(pipeline(addenv(cmd, env...); stderr=joinpath(dir, "error")), "r+")
        channel = Channel{Any}(Inf)
        reader = @async for line in eachline(process)
            put!(channel, JSON3.read(line, Dict{String, Any}))
        end
        observed = Any[]
        try
            send(value) = (println(process, JSON3.write(value)); flush(process))
            replies = Any[]
            for (id, command, exclude) in (("bash-ok", "printf 'hello\\n'", false), ("bash-fail", "printf 'bad\\n'; exit 7", true), ("bash-color", "printf '\\033[31mred\\033[0m\\r\\n'", false), ("bash-unicode", "printf '\\342\\202'; sleep 0.3; printf '\\254\\n'", false), ("bash-long", "printf '%051300d' 0", false))
                send((; id, type="bash", command, excludeFromContext=exclude))
                push!(replies, receive!(channel, observed, value -> get(value, "id", "") == id && value["type"] == "response"))
            end
            send((; id="bash-cancel", type="bash", command="printf ready; sleep 30"))
            receive!(channel, observed, value -> get(value, "id", "") == "bash-cancel" && value["type"] == "bash_execution_update")
            send((; id="bash-abort", type="abort_bash"))
            while count(value -> get(value, "id", "") in ("bash-cancel", "bash-abort") && value["type"] == "response", observed) < 2
                receive!(channel, observed, value -> get(value, "id", "") in ("bash-cancel", "bash-abort") && value["type"] == "response")
            end
            append!(replies, sort!([value for value in observed if get(value, "id", "") in ("bash-cancel", "bash-abort") && value["type"] == "response"]; by=value -> value["id"]))
            shellfile = !isnothing(sessiondir) && isdir(sessiondir) && !isempty(readdir(sessiondir))
            if promptafter
                send((; id="after-bash", type="prompt", message="continue"))
                receive!(channel, observed, value -> get(value, "type", "") == "agent_settled")
            end
            send((; id="bash-messages", type="get_messages"))
            messages = receive!(channel, observed, value -> get(value, "id", "") == "bash-messages")
            send((; id="bash-entries", type="get_entries"))
            entries = receive!(channel, observed, value -> get(value, "id", "") == "bash-entries")
            (; replies, messages, entries, observed, shellfile)
        finally
            close(process.in)
            timedwait(() -> process_exited(process), 5) == :ok || kill(process)
            wait(process)
            wait(reader)
        end
    end
end

function exchangebashduringturn(cmd, env, arrivals)
    mktempdir() do dir
        process = open(pipeline(addenv(cmd, env...); stderr=joinpath(dir, "error")), "r+")
        channel = Channel{Any}(Inf)
        reader = @async for line in eachline(process)
            put!(channel, JSON3.read(line, Dict{String, Any}))
        end
        observed = Any[]
        gate = nothing
        try
            send(value) = (println(process, JSON3.write(value)); flush(process))
            send((; id="prompt", type="prompt", message="hello"))
            receive!(channel, observed, value -> get(value, "id", "") == "prompt")
            timedwait(() -> isready(arrivals), 45) == :ok || error("Provider request did not start")
            gate = take!(arrivals)
            send((; id="bash", type="bash", command="printf pending"))
            reply = receive!(channel, observed, value -> get(value, "id", "") == "bash" && value["type"] == "response")
            send((; id="before", type="get_messages"))
            before = receive!(channel, observed, value -> get(value, "id", "") == "before")
            put!(gate, nothing)
            gate = nothing
            receive!(channel, observed, value -> get(value, "type", "") == "agent_settled")
            send((; id="after", type="get_messages"))
            after = receive!(channel, observed, value -> get(value, "id", "") == "after")
            (; reply, before, after)
        finally
            isnothing(gate) || put!(gate, nothing)
            close(process.in)
            timedwait(() -> process_exited(process), 5) == :ok || kill(process)
            wait(process)
            wait(reader)
        end
    end
end

function exchangeentries(cmd, env)
    mktempdir() do dir
        process = open(pipeline(addenv(cmd, env...); stderr=joinpath(dir, "error")), "r+")
        channel = Channel{Any}(Inf)
        reader = @async for line in eachline(process)
            put!(channel, JSON3.read(line, Dict{String, Any}))
        end
        observed = Any[]
        try
            send(value) = (println(process, JSON3.write(value)); flush(process))
            send((; id="entries", type="get_entries"))
            entries = receive!(channel, observed, value -> get(value, "id", "") == "entries")
            items = get(get(entries, "data", Dict()), "entries", [])
            firstid = isempty(items) ? "missing" : first(items)["id"]
            send((; id="since", type="get_entries", since=firstid))
            since = receive!(channel, observed, value -> get(value, "id", "") == "since")
            send((; id="invalid", type="get_entries", since="missing-entry"))
            invalid = receive!(channel, observed, value -> get(value, "id", "") == "invalid")
            send((; id="tree", type="get_tree"))
            tree = receive!(channel, observed, value -> get(value, "id", "") == "tree")
            (; entries, since, invalid, tree)
        finally
            close(process.in)
            timedwait(() -> process_exited(process), 5) == :ok || kill(process)
            wait(process)
            wait(reader)
        end
    end
end

function exchangethinking(cmd, env)
    mktempdir() do dir
        process = open(pipeline(addenv(cmd, env...); stderr=joinpath(dir, "error")), "r+")
        channel = Channel{Any}(Inf)
        reader = @async for line in eachline(process)
            put!(channel, JSON3.read(line, Dict{String, Any}))
        end
        observed = Any[]
        try
            send(value) = (println(process, JSON3.write(value)); flush(process))
            send((; id="low", type="set_thinking_level", level="low"))
            low = receive!(channel, observed, value -> get(value, "id", "") == "low")
            send((; id="prompt", type="prompt", message="hello"))
            receive!(channel, observed, value -> get(value, "type", "") == "agent_settled")
            send((; id="state", type="get_state"))
            state = receive!(channel, observed, value -> get(value, "id", "") == "state")
            send((; id="entries", type="get_entries"))
            entries = receive!(channel, observed, value -> get(value, "id", "") == "entries")
            send((; id="new", type="new_session"))
            new = receive!(channel, observed, value -> get(value, "id", "") == "new")
            send((; id="new-state", type="get_state"))
            newstate = receive!(channel, observed, value -> get(value, "id", "") == "new-state")
            send((; id="switch", type="switch_session", sessionPath=state["data"]["sessionFile"]))
            switched = receive!(channel, observed, value -> get(value, "id", "") == "switch")
            send((; id="restored", type="get_state"))
            restored = receive!(channel, observed, value -> get(value, "id", "") == "restored")
            (; low, state, entries, new, newstate, switched, restored)
        finally
            close(process.in)
            timedwait(() -> process_exited(process), 5) == :ok || kill(process)
            wait(process)
            wait(reader)
        end
    end
end

function exchangemodels(cmd, env; provider="fixture", target="beta", prompt=false)
    mktempdir() do dir
        process = open(pipeline(addenv(cmd, env...); stderr=joinpath(dir, "error")), "r+")
        channel = Channel{Any}(Inf)
        reader = @async for line in eachline(process)
            put!(channel, JSON3.read(line, Dict{String, Any}))
        end
        observed = Any[]
        try
            send(value) = (println(process, JSON3.write(value)); flush(process))
            function request(value)
                send(value)
                receive!(channel, observed, item -> get(item, "id", "") == value.id)
            end
            listed = request((; id="models", type="get_available_models"))
            changed = request((; id="set", type="set_model", provider, modelId=target))
            state = request((; id="state", type="get_state"))
            if prompt
                send((; id="prompt", type="prompt", message="hello"))
                receive!(channel, observed, item -> get(item, "type", "") == "agent_settled")
            end
            missing = request((; id="missing", type="set_model", provider, modelId="missing"))
            cycled = request((; id="cycle", type="cycle_model"))
            again = request((; id="again", type="get_state"))
            entries = request((; id="entries", type="get_entries"))
            (; listed, changed, state, missing, cycled, again, entries, observed)
        finally
            close(process.in)
            timedwait(() -> process_exited(process), 5) == :ok || kill(process)
            wait(process)
            wait(reader)
        end
    end
end

function exchangebusymodel(cmd, env, arrivals)
    mktempdir() do dir
        process = open(pipeline(addenv(cmd, env...); stderr=joinpath(dir, "error")), "r+")
        channel = Channel{Any}(Inf)
        reader = @async for line in eachline(process)
            put!(channel, JSON3.read(line, Dict{String, Any}))
        end
        observed = Any[]
        gate = nothing
        try
            send(value) = (println(process, JSON3.write(value)); flush(process))
            send((; id="prompt", type="prompt", message="hello"))
            receive!(channel, observed, item -> get(item, "id", "") == "prompt")
            timedwait(() -> isready(arrivals), 45) == :ok || error("Provider request did not start")
            body, gate = take!(arrivals)
            send((; id="set", type="set_model", provider="fixture", modelId="beta"))
            changed = receive!(channel, observed, item -> get(item, "id", "") == "set")
            send((; id="during", type="get_state"))
            during = receive!(channel, observed, item -> get(item, "id", "") == "during")
            put!(gate, nothing)
            gate = nothing
            receive!(channel, observed, item -> get(item, "type", "") == "agent_settled")
            send((; id="after", type="get_state"))
            after = receive!(channel, observed, item -> get(item, "id", "") == "after")
            (; body, changed, during, after)
        finally
            isnothing(gate) || put!(gate, nothing)
            close(process.in)
            timedwait(() -> process_exited(process), 5) == :ok || kill(process)
            wait(process)
            wait(reader)
        end
    end
end

function exchangecatalogsnapshot(cmd, path)
    mktempdir() do dir
        process = open(pipeline(cmd; stderr=joinpath(dir, "error")), "r+")
        channel = Channel{Any}(Inf)
        reader = @async for line in eachline(process)
            put!(channel, JSON3.read(line, Dict{String, Any}))
        end
        observed = Any[]
        try
            function request(id)
                println(process, JSON3.write((; id, type="get_available_models")))
                flush(process)
                receive!(channel, observed, item -> get(item, "id", "") == id)
            end
            before = request("before")
            mkpath(dirname(path))
            write(path, JSON3.write((; providers=(; fixture=(; baseUrl="https://example.invalid/v1", api="openai-responses", apiKey="fixture", models=[(; id="alpha")])))))
            after = request("after")
            (; before, after)
        finally
            close(process.in)
            timedwait(() -> process_exited(process), 5) == :ok || kill(process)
            wait(process)
            wait(reader)
        end
    end
end

@testset "Pi RPC subprocess protocol" begin
    source = ENV["PI_SOURCE"]
    @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    mktempdir() do workspace
        skill = joinpath(workspace, ".pi", "skills", "demo", "SKILL.md")
        template = joinpath(workspace, ".pi", "prompts", "fix.md")
        mkpath(dirname(skill))
        mkpath(dirname(template))
        write(skill, "---\nname: demo\ndescription: Demo skill\n---\n\nUse the demo.\n")
        write(template, "---\ndescription: Fix it\n---\n\nFix \$1.\n")
        project = dirname(@__DIR__)
        oracle = joinpath(@__DIR__, "headless_reference.mjs")
        pi = Cmd(`node $oracle $source --mode rpc --no-session --provider openai --model gpt-4.1-mini --approve`; dir=workspace)
        jf = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project $(joinpath(@__DIR__, "terminal_process.jl")) --mode rpc --no-session`; dir=workspace)
        env = ["PI_SOURCE" => source, "HOME" => workspace, "USERPROFILE" => workspace, "PI_CODING_AGENT_DIR" => joinpath(workspace, "agent"), "PI_OFFLINE" => "1", "JF_PROVIDER" => "openai", "OPENAI_MODEL" => "gpt-4.1-mini", "OPENAI_API_KEY" => "fixture", "JF_FIXTURE" => "text", "JF_INSTRUCTIONS_DIR" => workspace]
        commands = [(; id="state", type="get_state"), (; id="messages", type="get_messages"), (; id="commands", type="get_commands"), (; id="clear", type="clear_queue"), (; id="bad", type="no_such_command"), (; id="export-empty", type="export_html", outputPath=joinpath(workspace, "report.html")), (; id="levels", type="get_available_thinking_levels"), (; id="cycle", type="cycle_thinking_level"), (; id="thinking", type="set_thinking_level", level="off"), (; id="steering-mode", type="set_steering_mode", mode="one-at-a-time"), (; id="follow-mode", type="set_follow_up_mode", mode="one-at-a-time"), (; id="compaction", type="set_auto_compaction", enabled=false), (; id="retry", type="set_auto_retry", enabled=false), (; id="abort-retry", type="abort_retry"), (; id="abort-bash", type="abort_bash")]
        input = join(JSON3.write.(commands), "\n") * "\n{\n"
        expected = runprocess(pi, input, env)
        actual = runprocess(jf, input, env)
        @test expected.status == actual.status == 0
        reference = responses(expected.output)
        result = responses(actual.output)
        @test Set(keys(result)) == Set(keys(reference))
        for id in ("messages", "clear", "bad", "export-empty", "levels", "cycle", "thinking", "steering-mode", "follow-mode", "compaction", "retry", "abort-retry", "abort-bash")
            @test get(result, id, nothing) == reference[id]
        end
        expected_state = reference["state"]["data"]
        actual_state = get(get(result, "state", Dict()), "data", Dict())
        for key in ("thinkingLevel", "isStreaming", "isCompacting", "steeringMode", "followUpMode", "messageCount", "pendingMessageCount")
            @test get(actual_state, key, nothing) == expected_state[key]
        end
        @test actual_state["model"]["id"] == expected_state["model"]["id"]
        @test actual_state["model"]["provider"] == expected_state["model"]["provider"]
        projectcommands(response) = Dict(item["name"] => item for item in get(get(response, "data", Dict()), "commands", []) if item["name"] in ("fix", "skill:demo"))
        @test projectcommands(get(result, "commands", Dict())) == projectcommands(reference["commands"])
        parseerror(output) = only(record for record in records(output) if get(record, "command", "") == "parse")
        @test parseerror(actual.output)["success"] == parseerror(expected.output)["success"] == false
        @test startswith(parseerror(actual.output)["error"], "Failed to parse command")
        pi_help = Cmd(`node $oracle $source --mode json --help`; dir=workspace)
        jf_help = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode json --help`; dir=workspace)
        pi_metadata = runprocess(pi_help, "", env)
        jf_metadata = runprocess(jf_help, "", env)
        @test pi_metadata.status == jf_metadata.status == 0
        @test isempty(pi_metadata.output) && isempty(jf_metadata.output)
        @test !isempty(pi_metadata.diagnostics) && !isempty(jf_metadata.diagnostics)

        cleanenv = Dict("PATH" => ENV["PATH"], "HOME" => workspace, "PI_SOURCE" => source, "PI_CODING_AGENT_DIR" => joinpath(workspace, "empty-agent"), "PI_OFFLINE" => "1", "JF_FIXTURE" => "text", "JF_INSTRUCTIONS_DIR" => workspace, "JULIA_DEPOT_PATH" => get(ENV, "JULIA_DEPOT_PATH", ""))
        for key in ("SystemRoot", "WINDIR", "COMSPEC", "PATHEXT", "TMP", "TEMP")
            haskey(ENV, key) && (cleanenv[key] = ENV[key])
        end
        cleanenv["USERPROFILE"] = workspace
        empty_pi = setenv(Cmd(`node $oracle $source --mode rpc --no-session`; dir=workspace), cleanenv)
        empty_jf = setenv(Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project $(joinpath(@__DIR__, "terminal_process.jl")) --mode rpc --no-session`; dir=workspace), cleanenv)
        empty_input = join(JSON3.write.([(; id="state", type="get_state"), (; id="models", type="get_available_models"), (; id="prompt", type="prompt", message="hello")]), "\n") * "\n"
        pi_unconfigured = runprocess(empty_pi, empty_input, [])
        jf_unconfigured = runprocess(empty_jf, empty_input, [])
        @test jf_unconfigured.status == pi_unconfigured.status == 0
        expected_empty, actual_empty = responses(pi_unconfigured.output), responses(jf_unconfigured.output)
        @test get(get(get(actual_empty, "state", Dict()), "data", Dict()), "model", nothing) == expected_empty["state"]["data"]["model"]
        @test get(actual_empty, "models", nothing) == expected_empty["models"]
        @test get(get(actual_empty, "prompt", Dict()), "success", nothing) == expected_empty["prompt"]["success"] == false

        customdir = joinpath(workspace, "custom-provider")
        mkpath(customdir)
        write(joinpath(customdir, "models.json"), JSON3.write((; providers=(; fixture=(; baseUrl="https://example.invalid/v1", api="openai-responses", apiKey="fixture-key", models=[(; id="alpha")])))))
        customenv = vcat([pair for pair in env if !(first(pair) in ("PI_CODING_AGENT_DIR", "JF_PROVIDER"))], ["PI_CODING_AGENT_DIR" => customdir, "JF_PROVIDER" => "fixture"])
        custompi = Cmd(`node $oracle $source --mode rpc --no-session --provider fixture --model alpha --approve`; dir=workspace)
        customjf = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project $(joinpath(@__DIR__, "terminal_process.jl")) --mode rpc --no-session --provider fixture --model alpha`; dir=workspace)
        custominput = join(JSON3.write.([(; id="state", type="get_state"), (; id="entries", type="get_entries")]), "\n") * "\n"
        expected_custom = runprocess(custompi, custominput, customenv)
        actual_custom = runprocess(customjf, custominput, customenv)
        expected_custom_state, actual_custom_state = responses(expected_custom.output), responses(actual_custom.output)
        @test expected_custom.status == actual_custom.status == 0
        @test actual_custom_state["state"]["data"]["model"]["provider"] == expected_custom_state["state"]["data"]["model"]["provider"]
        modelentry(result) = only(entry["provider"] for entry in result["entries"]["data"]["entries"] if entry["type"] == "model_change")
        @test modelentry(actual_custom_state) == modelentry(expected_custom_state)

        modeldir = joinpath(workspace, "rpc-models")
        mkpath(modeldir)
        definitions = [(; id="alpha", name="Alpha", cost=(; input=1, output=2, cacheRead=0.1, cacheWrite=0), contextWindow=8000, maxTokens=2048), (; id="beta", name="Beta", contextWindow=16000, maxTokens=4096)]
        write(joinpath(modeldir, "models.json"), JSON3.write((; providers=(; fixture=(; baseUrl="https://example.invalid/v1", api="openai-responses", apiKey="fixture-key", models=definitions)))))
        modelenv = merge(cleanenv, Dict("PI_CODING_AGENT_DIR" => modeldir, "JF_PROVIDER" => "fixture"))
        modelpi = setenv(Cmd(`node $oracle $source --mode rpc --no-session --provider fixture --model alpha --approve`; dir=workspace), modelenv)
        modeljf = setenv(Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project $(joinpath(@__DIR__, "terminal_process.jl")) --mode rpc --no-session --provider fixture --model alpha`; dir=workspace), modelenv)
        expected_models = exchangemodels(modelpi, [])
        actual_models = exchangemodels(modeljf, [])
        @test actual_models.listed == expected_models.listed
        @test actual_models.changed == expected_models.changed && actual_models.missing == expected_models.missing && actual_models.cycled == expected_models.cycled
        @test [run["data"]["model"] for run in (actual_models.state, actual_models.again)] == [run["data"]["model"] for run in (expected_models.state, expected_models.again)]
        modelchanges(run) = [(entry["provider"], entry["modelId"]) for entry in run.entries["data"]["entries"] if entry["type"] == "model_change"]
        @test modelchanges(actual_models) == modelchanges(expected_models)

        crossdir = joinpath(workspace, "cross-api")
        mkpath(crossdir)
        crossmodels = [(; id="alpha", api="openai-responses"), (; id="beta", api="openai-completions")]
        write(joinpath(crossdir, "models.json"), JSON3.write((; providers=(; fixture=(; baseUrl="https://example.invalid/v1", api="openai-responses", apiKey="fixture-key", models=crossmodels)))))
        crossenv = merge(modelenv, Dict("PI_CODING_AGENT_DIR" => crossdir))
        crosspi = setenv(Cmd(`node $oracle $source --mode rpc --no-session --provider fixture --model alpha --approve`; dir=workspace), crossenv)
        crossjf = setenv(Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project $(joinpath(@__DIR__, "terminal_process.jl")) --mode rpc --no-session --provider fixture --model alpha`; dir=workspace), crossenv)
        reference_cross = exchangemodels(crosspi, [])
        actual_cross = exchangemodels(crossjf, [])
        @test reference_cross.changed["success"] && !actual_cross.changed["success"]
        @test actual_cross.state["data"]["model"]["id"] == "alpha" && modelchanges(actual_cross) == [("fixture", "alpha")]

        builtindir = joinpath(workspace, "rpc-builtin")
        builtinenvironment = merge(cleanenv, Dict("PI_CODING_AGENT_DIR" => builtindir, "JF_PROVIDER" => "openai", "OPENAI_API_KEY" => "sk-fixture"))
        builtinpi = setenv(Cmd(`node $oracle $source --mode rpc --no-session --model openai/gpt-5.2:high --approve`; dir=workspace), builtinenvironment)
        builtinjf = setenv(Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project $(joinpath(@__DIR__, "terminal_process.jl")) --mode rpc --no-session --model openai/gpt-5.2:high`; dir=workspace), builtinenvironment)
        expected_builtin = exchangemodels(builtinpi, []; provider="openai", target="gpt-4.1-mini")
        actual_builtin = exchangemodels(builtinjf, []; provider="openai", target="gpt-4.1-mini")
        @test actual_builtin.listed == expected_builtin.listed
        @test actual_builtin.changed == expected_builtin.changed && actual_builtin.missing == expected_builtin.missing && actual_builtin.cycled == expected_builtin.cycled
        @test [run["data"]["model"] for run in (actual_builtin.state, actual_builtin.again)] == [run["data"]["model"] for run in (expected_builtin.state, expected_builtin.again)]
        @test modelchanges(actual_builtin) == modelchanges(expected_builtin)
        pi_snapshot_dir, jf_snapshot_dir = joinpath(workspace, "pi-snapshot"), joinpath(workspace, "jf-snapshot")
        pi_snapshot_env = merge(builtinenvironment, Dict("PI_CODING_AGENT_DIR" => pi_snapshot_dir))
        jf_snapshot_env = merge(builtinenvironment, Dict("PI_CODING_AGENT_DIR" => jf_snapshot_dir))
        pi_snapshot = setenv(Cmd(`node $oracle $source --mode rpc --no-session --model openai/gpt-5.2 --approve`; dir=workspace), pi_snapshot_env)
        jf_snapshot = setenv(Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project $(joinpath(@__DIR__, "terminal_process.jl")) --mode rpc --no-session --model openai/gpt-5.2`; dir=workspace), jf_snapshot_env)
        expected_snapshot = exchangecatalogsnapshot(pi_snapshot, joinpath(pi_snapshot_dir, "models.json"))
        actual_snapshot = exchangecatalogsnapshot(jf_snapshot, joinpath(jf_snapshot_dir, "models.json"))
        @test expected_snapshot.before["data"]["models"] == expected_snapshot.after["data"]["models"] == actual_snapshot.before["data"]["models"] == actual_snapshot.after["data"]["models"]
        mixeddir = joinpath(workspace, "rpc-mixed-models")
        mkpath(mixeddir)
        write(joinpath(mixeddir, "models.json"), JSON3.write((; providers=(; google=(; models=[(; id="custom-extra", name="Custom")])))))
        mixedenv = merge(builtinenvironment, Dict("PI_CODING_AGENT_DIR" => mixeddir, "GEMINI_API_KEY" => "fixture"))
        mixedpi = setenv(Cmd(`node $oracle $source --mode rpc --no-session --model openai/gpt-5.2 --approve`; dir=workspace), mixedenv)
        mixedjf = setenv(Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project $(joinpath(@__DIR__, "terminal_process.jl")) --mode rpc --no-session --model openai/gpt-5.2`; dir=workspace), mixedenv)
        mixedinput = JSON3.write((; id="models", type="get_available_models")) * "\n"
        expected_mixed = runprocess(mixedpi, mixedinput, [])
        actual_mixed = runprocess(mixedjf, mixedinput, [])
        @test expected_mixed.status == actual_mixed.status == 0
        @test responses(actual_mixed.output)["models"] == responses(expected_mixed.output)["models"]
        for (provider, model, key, api) in (("anthropic", "claude-haiku-4-5", "ANTHROPIC_API_KEY", "anthropic-messages"), ("google", "gemini-2.5-flash", "GEMINI_API_KEY", "google-generative-ai"), ("openrouter", "openrouter/free", "OPENROUTER_API_KEY", "openai-completions"))
            provider_env = merge(cleanenv, Dict("PI_CODING_AGENT_DIR" => joinpath(workspace, "rpc-" * provider), "JF_PROVIDER" => provider, key => "fixture"))
            reference_cmd = setenv(Cmd(`node $oracle $source --mode rpc --no-session --provider $provider --model $model --approve`; dir=workspace), provider_env)
            actual_cmd = setenv(Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project $(joinpath(@__DIR__, "terminal_process.jl")) --mode rpc --no-session --provider $provider --model $model`; dir=workspace), provider_env)
            input = JSON3.write((; id="models", type="get_available_models")) * "\n"
            reference = runprocess(reference_cmd, input, [])
            observed = runprocess(actual_cmd, input, [])
            @test reference.status == observed.status == 0
            expected = responses(reference.output)["models"]["data"]["models"]
            actual = responses(observed.output)["models"]["data"]["models"]
            @test actual == [item for item in expected if item["api"] == api]
        end
        generated = joinpath(workspace, "rpc-models.json")
        package_data = joinpath(source, "node_modules", "@earendil-works", "pi-ai", "dist", "providers", "data")
        run(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project $(joinpath(project, "scripts", "rpc_model_catalog.jl")) $package_data $generated`)
        @test read(generated) == read(joinpath(project, "data", "pi-rpc-models.json"))

        if Sys.isunix()
            expected_bash = exchangebash(pi, env)
            actual_bash = exchangebash(jf, env)
            normalizepath(value) = Dict(key => key == "fullOutputPath" ? "<output>" : item for (key, item) in value)
            normalreply(reply) = haskey(reply, "data") ? merge(reply, Dict("data" => normalizepath(reply["data"]))) : reply
            @test normalreply.(actual_bash.replies) == normalreply.(expected_bash.replies)
            updates(exchange, id) = join(get(event, "delta", "") for event in exchange.observed if get(event, "type", "") == "bash_execution_update" && get(event, "id", "") == id)
            @test [updates(actual_bash, id) for id in ("bash-ok", "bash-fail", "bash-color", "bash-unicode", "bash-long", "bash-cancel")] == [updates(expected_bash, id) for id in ("bash-ok", "bash-fail", "bash-color", "bash-unicode", "bash-long", "bash-cancel")]
            bashmessages(exchange) = [normalizepath(Dict(key => value for (key, value) in message if key != "timestamp")) for message in exchange.messages["data"]["messages"]]
            @test bashmessages(actual_bash) == bashmessages(expected_bash)
            entrymessages(exchange) = [normalizepath(Dict(key => value for (key, value) in entry["message"] if key != "timestamp")) for entry in get(get(exchange.entries, "data", Dict()), "entries", []) if entry["type"] == "message"]
            @test entrymessages(actual_bash) == entrymessages(expected_bash)
            outputpath(exchange) = only(reply["data"]["fullOutputPath"] for reply in exchange.replies if get(reply, "id", "") == "bash-long")
            @test read(outputpath(actual_bash), String) == read(outputpath(expected_bash), String)
            rm(outputpath(actual_bash))
            rm(outputpath(expected_bash))

        end

        expected_entries = exchangeentries(pi, env)
        actual_entries = exchangeentries(jf, env)
        entriesview(response) = [Dict(key => value for (key, value) in item if !(key in ("id", "parentId", "timestamp"))) for item in get(get(response, "data", Dict()), "entries", [])]
        treeview(node) = (; entry=Dict(key => value for (key, value) in node["entry"] if !(key in ("id", "parentId", "timestamp"))), children=treeview.(node["children"]))
        @test entriesview(actual_entries.entries) == entriesview(expected_entries.entries)
        @test entriesview(actual_entries.since) == entriesview(expected_entries.since)
        @test actual_entries.invalid == expected_entries.invalid
        @test treeview.(get(get(actual_entries.tree, "data", Dict()), "tree", [])) == treeview.(expected_entries.tree["data"]["tree"])
        function entrychain(exchange)
            entries = exchange.entries["data"]["entries"]
            parents = [nothing; [item["id"] for item in entries[1:end-1]]]
            [item["parentId"] for item in entries] == parents && exchange.entries["data"]["leafId"] == last(entries)["id"] && exchange.since["data"]["entries"] == entries[2:end]
        end
        @test entrychain(actual_entries) && entrychain(expected_entries)

        modes = [(; id="steer-all", type="set_steering_mode", mode="all"), (; id="follow-all", type="set_follow_up_mode", mode="all"), (; id="all-state", type="get_state"), (; id="new", type="new_session"), (; id="new-state", type="get_state"), (; id="steer-one", type="set_steering_mode", mode="one-at-a-time"), (; id="follow-one", type="set_follow_up_mode", mode="one-at-a-time"), (; id="one-state", type="get_state")]
        modeinput = join(JSON3.write.(modes), "\n") * "\n"
        modeenv(directory) = vcat([pair for pair in env if first(pair) != "PI_CODING_AGENT_DIR"], ["PI_CODING_AGENT_DIR" => directory])
        pi_modes = responses(runprocess(pi, modeinput, modeenv(joinpath(workspace, "pi-modes"))).output)
        jf_modes = responses(runprocess(jf, modeinput, modeenv(joinpath(workspace, "jf-modes"))).output)
        @test [get(get(jf_modes, id, Dict()), "success", nothing) for id in ("steer-all", "follow-all", "steer-one", "follow-one")] == [pi_modes[id]["success"] for id in ("steer-all", "follow-all", "steer-one", "follow-one")]
        modeview(response) = (get(get(response, "data", Dict()), "steeringMode", nothing), get(get(response, "data", Dict()), "followUpMode", nothing))
        @test [modeview(get(jf_modes, id, Dict())) for id in ("all-state", "new-state", "one-state")] == [modeview(pi_modes[id]) for id in ("all-state", "new-state", "one-state")]

        pi_thinking = Cmd(`node $oracle $source --mode rpc --no-session --model openai/gpt-5.2:high --approve`; dir=workspace)
        jf_thinking = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project $(joinpath(@__DIR__, "terminal_process.jl")) --mode rpc --no-session --model openai/gpt-5.2:high`; dir=workspace)
        thinking = [(; id="state", type="get_state"), (; id="levels", type="get_available_thinking_levels"), (; id="low", type="set_thinking_level", level="low"), (; id="after", type="get_state"), (; id="cycle", type="cycle_thinking_level"), (; id="cycled", type="get_state")]
        thinkinginput = join(JSON3.write.(thinking), "\n") * "\n"
        pi_thought = runprocess(pi_thinking, thinkinginput, modeenv(joinpath(workspace, "pi-thinking")))
        jf_thought = runprocess(jf_thinking, thinkinginput, modeenv(joinpath(workspace, "jf-thinking")))
        pi_thoughts, jf_thoughts = responses(pi_thought.output), responses(jf_thought.output)
        @test jf_thought.status == pi_thought.status == 0
        @test [get(get(get(jf_thoughts, id, Dict()), "data", Dict()), "thinkingLevel", nothing) for id in ("state", "after", "cycled")] == [pi_thoughts[id]["data"]["thinkingLevel"] for id in ("state", "after", "cycled")]
        @test [get(jf_thoughts, id, nothing) for id in ("levels", "low", "cycle")] == [pi_thoughts[id] for id in ("levels", "low", "cycle")]
        thinkingevents(run) = [(item["type"], item["level"]) for item in records(run.output) if get(item, "type", "") == "thinking_level_changed"]
        @test thinkingevents(jf_thought) == thinkingevents(pi_thought)

        restricted = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project $(joinpath(@__DIR__, "terminal_process.jl")) --mode rpc --no-session --model openai/gpt-6-luna:off`; dir=workspace)
        restrictedenv = vcat(modeenv(joinpath(workspace, "restricted")), ["OPENAI_BASE_URL" => "https://api.openai.com/v1"])
        restrictedinput = join(JSON3.write.([(; id="levels", type="get_available_thinking_levels"), (; id="low", type="set_thinking_level", level="low"), (; id="state", type="get_state")]), "\n") * "\n"
        restriction = runprocess(restricted, restrictedinput, restrictedenv)
        restrictedresponses = responses(restriction.output)
        @test restriction.status == 0
        @test get(get(get(restrictedresponses, "levels", Dict()), "data", Dict()), "levels", nothing) == ["off"]
        @test get(get(restrictedresponses, "low", Dict()), "success", false)
        @test get(get(get(restrictedresponses, "state", Dict()), "data", Dict()), "thinkingLevel", nothing) == "off"
    end
end

@testset "Pi RPC thinking requests and sessions" begin
    source = ENV["PI_SOURCE"]
    requests = Channel{Any}(2)
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        put!(requests, JSON3.read(String(request.body), Dict{String, Any}))
        delta = JSON3.write((; type="response.output_text.delta", delta="fixture"))
        done = JSON3.write((; type="response.completed", response=(; status="completed", output=[(; type="message", content=[(; type="output_text", text="fixture")])])))
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $delta\n\ndata: $done\n\n")
    end
    try
        mktempdir() do workspace
            base = "http://$(HTTP.server_addr(server))/v1"
            piagent = joinpath(workspace, "pi-agent")
            mkpath(piagent)
            write(joinpath(piagent, "models.json"), JSON3.write((; providers=(; openai=(; baseUrl=base, apiKey="fixture")))))
            project = dirname(@__DIR__)
            oracle = joinpath(@__DIR__, "headless_reference.mjs")
            pi = Cmd(`node $oracle $source --mode rpc --session-dir $(joinpath(workspace, "pi-sessions")) --model openai/gpt-5.2:high --approve`; dir=workspace)
            jf = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode rpc --session-dir $(joinpath(workspace, "jf-sessions")) --model openai/gpt-5.2:high`; dir=workspace)
            function env(agentdir)
                values = Dict("PATH" => ENV["PATH"], "HOME" => workspace, "USERPROFILE" => workspace, "PI_SOURCE" => source, "PI_CODING_AGENT_DIR" => agentdir, "PI_OFFLINE" => "1", "JF_PROVIDER" => "openai", "OPENAI_API_KEY" => "fixture", "OPENAI_BASE_URL" => base, "JF_INSTRUCTIONS_DIR" => workspace, "JULIA_DEPOT_PATH" => get(ENV, "JULIA_DEPOT_PATH", ""))
                for key in ("SystemRoot", "WINDIR", "COMSPEC", "PATHEXT", "TMP", "TEMP")
                    haskey(ENV, key) && (values[key] = ENV[key])
                end
                values
            end
            reference = exchangethinking(setenv(pi, env(piagent)), [])
            actual = exchangethinking(setenv(jf, env(joinpath(workspace, "jf-agent"))), [])
            pi_request, jf_request = take!(requests), take!(requests)
            @test jf_request["reasoning"] == pi_request["reasoning"] == Dict("effort" => "low", "summary" => "auto")
            @test [get(result["data"], "thinkingLevel", nothing) for result in (actual.state, actual.newstate, actual.restored)] == [result["data"]["thinkingLevel"] for result in (reference.state, reference.newstate, reference.restored)]
            thinkingentries(result) = [entry["thinkingLevel"] for entry in result.entries["data"]["entries"] if entry["type"] == "thinking_level_change"]
            @test thinkingentries(actual) == thinkingentries(reference)
            @test actual.low == reference.low && actual.new == reference.new && actual.switched == reference.switched

            pi6 = Cmd(`node $oracle $source --mode rpc --session-dir $(joinpath(workspace, "pi6-sessions")) --model openai/gpt-6-luna:high --approve`; dir=workspace)
            jf6 = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode rpc --session-dir $(joinpath(workspace, "jf6-sessions")) --model openai/gpt-6-luna:high`; dir=workspace)
            reference6 = exchangethinking(setenv(pi6, env(piagent)), [])
            actual6 = exchangethinking(setenv(jf6, env(joinpath(workspace, "jf-agent"))), [])
            pi_request6, jf_request6 = take!(requests), take!(requests)
            updates(request) = [item for item in request["input"] if get(item, "type", "") == "configuration_update"]
            @test jf_request6["reasoning"] == pi_request6["reasoning"]
            @test updates(jf_request6) == updates(pi_request6) == [Dict("type" => "configuration_update", "reasoning" => Dict("effort" => "low"))]
            @test [result["data"]["thinkingLevel"] for result in (actual6.state, actual6.newstate, actual6.restored)] == [result["data"]["thinkingLevel"] for result in (reference6.state, reference6.newstate, reference6.restored)]

            customdir = joinpath(workspace, "custom-models")
            mkpath(customdir)
            definitions = [(; id="alpha", name="Alpha", contextWindow=8000, maxTokens=2048), (; id="beta", name="Beta", contextWindow=16000, maxTokens=4096)]
            write(joinpath(customdir, "models.json"), JSON3.write((; providers=(; fixture=(; baseUrl=base, api="openai-responses", apiKey="fixture", models=definitions)))))
            customenv = Dict("PATH" => ENV["PATH"], "HOME" => workspace, "USERPROFILE" => workspace, "PI_SOURCE" => source, "PI_CODING_AGENT_DIR" => customdir, "PI_OFFLINE" => "1", "JF_PROVIDER" => "fixture", "JF_INSTRUCTIONS_DIR" => workspace, "JULIA_DEPOT_PATH" => get(ENV, "JULIA_DEPOT_PATH", ""))
            for key in ("SystemRoot", "WINDIR", "COMSPEC", "PATHEXT", "TMP", "TEMP")
                haskey(ENV, key) && (customenv[key] = ENV[key])
            end
            pi_custom = setenv(Cmd(`node $oracle $source --mode rpc --no-session --provider fixture --model alpha --approve`; dir=workspace), customenv)
            jf_custom = setenv(Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode rpc --no-session --provider fixture --model alpha`; dir=workspace), customenv)
            pi_models = exchangemodels(pi_custom, []; prompt=true)
            jf_models = exchangemodels(jf_custom, []; prompt=true)
            pi_custom_request, jf_custom_request = take!(requests), take!(requests)
            @test jf_models.changed == pi_models.changed
            @test jf_custom_request["model"] == pi_custom_request["model"] == "beta"
            assistantmodels(run) = [event["message"]["model"] for event in run.observed if get(event, "type", "") == "message_end" && get(event["message"], "role", "") == "assistant"]
            @test assistantmodels(jf_models) == assistantmodels(pi_models) == ["beta"]

            arrivals = Channel{Tuple{Dict{String, Any}, Channel{Nothing}}}(2)
            gated = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
                gate = Channel{Nothing}(1)
                put!(arrivals, (JSON3.read(String(request.body), Dict{String, Any}), gate))
                take!(gate)
                delta = JSON3.write((; type="response.output_text.delta", delta="fixture"))
                done = JSON3.write((; type="response.completed", response=(; status="completed", output=[(; type="message", content=[(; type="output_text", text="fixture")])])))
                HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $delta\n\ndata: $done\n\n")
            end
            try
                gatedbase = "http://$(HTTP.server_addr(gated))/v1"
                write(joinpath(customdir, "models.json"), JSON3.write((; providers=(; fixture=(; baseUrl=gatedbase, api="openai-responses", apiKey="fixture", models=definitions)))))
                pi_busy = exchangebusymodel(pi_custom, [], arrivals)
                jf_busy = exchangebusymodel(jf_custom, [], arrivals)
                @test pi_busy.changed["success"] && !jf_busy.changed["success"]
                @test pi_busy.body["model"] == jf_busy.body["model"] == "alpha"
                @test jf_busy.during["data"]["model"]["id"] == jf_busy.after["data"]["model"]["id"] == "alpha"
            finally
                close(gated)
                wait(gated)
            end

            pi_builtin = Cmd(`node $oracle $source --mode rpc --no-session --model openai/gpt-5.2 --approve`; dir=workspace)
            jf_builtin = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode rpc --no-session --model openai/gpt-5.2`; dir=workspace)
            pi_selected = exchangemodels(setenv(pi_builtin, env(piagent)), []; provider="openai", target="gpt-4.1-mini", prompt=true)
            jf_selected = exchangemodels(setenv(jf_builtin, env(joinpath(workspace, "jf-agent"))), []; provider="openai", target="gpt-4.1-mini", prompt=true)
            pi_selected_request, jf_selected_request = take!(requests), take!(requests)
            @test jf_selected.listed == pi_selected.listed && jf_selected.changed == pi_selected.changed
            @test jf_selected_request["model"] == pi_selected_request["model"] == "gpt-4.1-mini"
            @test assistantmodels(jf_selected) == assistantmodels(pi_selected) == ["gpt-4.1-mini"]
        end
    finally
        close(server)
        wait(server)
    end
end

function eventview(record)
    type = record["type"]
    if type in ("message_start", "message_end")
        value = record["message"]
        role = value["role"]
        type == "message_start" && role == "assistant" && return (; type, role)
        return role == "system" ? (; type, role) : (; type, role, content=value["content"], stopReason=get(value, "stopReason", nothing))
    elseif type == "message_update"
        return (; type, event=record["assistantMessageEvent"], usage=record["usage"])
    elseif type == "turn_end"
        return (; type, content=record["message"]["content"], stopReason=record["message"]["stopReason"], toolResults=toolview.(record["toolResults"]))
    elseif type == "tool_execution_start"
        return (; type, id=record["toolCallId"], name=record["toolName"], args=record["args"])
    elseif type == "tool_execution_end"
        return (; type, id=record["toolCallId"], name=record["toolName"], content=record["result"]["content"], isError=record["isError"])
    elseif type == "agent_end"
        return (; type, roles=[value["role"] for value in record["messages"]], willRetry=record["willRetry"])
    elseif type == "agent_settled"
        return (; type, aborted=record["aborted"])
    end
    (; type)
end
toolview(value) = (; role=value["role"], id=value["toolCallId"], name=value["toolName"], content=value["content"], isError=value["isError"])

@testset "Pi JSON stream with a local provider" begin
    source = ENV["PI_SOURCE"]
    chunks = [Dict("id" => "fixture", "object" => "chat.completion.chunk", "created" => 1, "model" => "fixture", "choices" => [Dict("index" => 0, "delta" => delta, "finish_reason" => finish)]) for (delta, finish) in [(Dict("role" => "assistant", "content" => "Hello"), nothing), (Dict("content" => " world"), nothing), (Dict(), "stop")]]
    body = join(("data: " * JSON3.write(chunk) * "\n\n" for chunk in chunks)) * "data: [DONE]\n\n"
    requests = Channel{Any}(Inf)
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        put!(requests, JSON3.read(String(request.body), Dict{String, Any}))
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], body)
    end
    try
        mktempdir() do workspace
            base = "http://$(HTTP.server_addr(server))/v1"
            agentdir = joinpath(workspace, "agent")
            mkpath(agentdir)
            write(joinpath(agentdir, "settings.json"), JSON3.write((; retry=(; enabled=false))))
            write(joinpath(agentdir, "models.json"), JSON3.write(Dict("providers" => Dict("openai" => Dict("baseUrl" => base, "api" => "openai-completions", "apiKey" => "fixture", "models" => [Dict("id" => "fixture")])))))
            project = dirname(@__DIR__)
            oracle = joinpath(@__DIR__, "headless_reference.mjs")
            pi = Cmd(`node $oracle $source --mode json --no-session --provider openai --model fixture hello`; dir=workspace)
            jf = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode json --no-session hello`; dir=workspace)
            env = ["PI_SOURCE" => source, "HOME" => workspace, "USERPROFILE" => workspace, "PI_CODING_AGENT_DIR" => agentdir, "PI_OFFLINE" => "1", "JF_PROVIDER" => "openai", "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => "fixture", "OPENAI_BASE_URL" => base, "JF_INSTRUCTIONS_DIR" => workspace]
            reference = runprocess(pi, "", env)
            actual = runprocess(jf, "", env)
            @test reference.status == actual.status == 0
            @test eventview.(records(actual.output)) == eventview.(records(reference.output))

            packages = joinpath(workspace, "packages")
            plugin = joinpath(packages, "NoisyPlugin")
            mkpath(joinpath(plugin, "src"))
            write(joinpath(plugin, "Project.toml"), "name = \"NoisyPlugin\"\nuuid = \"c5f8f239-ffb0-4ec5-ab9d-3fe12300424f\"\nversion = \"0.1.0\"\n\n[deps]\nJuliaForever = \"2b71f2a2-b786-4fd0-b9cc-80b6322c5084\"\n")
            write(joinpath(plugin, "src", "NoisyPlugin.jl"), "module NoisyPlugin\nusing JuliaForever\nfunction __init__(); println(\"init-noise\"); end\nfunction plugin(); println(\"factory-noise\"); JuliaForever.Extensions.Plugin(; hooks=(:agent_start => (event -> println(\"hook-noise\")),)); end\nend\n")
            extension = joinpath(workspace, "noisy.mjs")
            write(extension, "console.log('init-noise'); export default function(pi) { console.log('factory-noise'); pi.on('agent_start', async () => console.log('hook-noise')); }\n")
            pi_noisy = Cmd(`node $oracle $source --mode json --no-session --provider openai --model fixture --extension $extension --approve hello`; dir=workspace)
            jf_noisy = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode json --no-session --plugin-env $packages --plugin NoisyPlugin hello`; dir=workspace)
            pi_logs = runprocess(pi_noisy, "", env)
            jf_logs = runprocess(jf_noisy, "", env)
            @test pi_logs.status == jf_logs.status == 0
            @test eventview.(records(jf_logs.output)) == eventview.(records(pi_logs.output))
            @test all(occursin(noise, pi_logs.diagnostics) && occursin(noise, jf_logs.diagnostics) for noise in ("init-noise", "factory-noise", "hook-noise"))

            rejected = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
                HTTP.Response(401, ["Content-Type" => "application/json"], JSON3.write((; error=(; message="fixture denied", type="authentication_error"))))
            end
            try
                rejectedbase = "http://$(HTTP.server_addr(rejected))/v1"
                write(joinpath(agentdir, "models.json"), JSON3.write(Dict("providers" => Dict("openai" => Dict("baseUrl" => rejectedbase, "api" => "openai-completions", "apiKey" => "fixture", "models" => [Dict("id" => "fixture")])))))
                rejectedenv = [pair for pair in env if first(pair) != "OPENAI_BASE_URL"]
                push!(rejectedenv, "OPENAI_BASE_URL" => rejectedbase)
                pi_failure = runprocess(pi, "", rejectedenv)
                jf_failure = runprocess(jf, "", rejectedenv)
                @test pi_failure.status == jf_failure.status == 0
                @test eventview.(records(jf_failure.output)) == eventview.(records(pi_failure.output))
            finally
                close(rejected)
                wait(rejected)
            end
            disconnected = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
                HTTP.Response(200)
            end
            disconnectedbase = "http://$(HTTP.server_addr(disconnected))/v1"
            close(disconnected)
            wait(disconnected)
            write(joinpath(agentdir, "models.json"), JSON3.write(Dict("providers" => Dict("openai" => Dict("baseUrl" => disconnectedbase, "api" => "openai-completions", "apiKey" => "fixture", "models" => [Dict("id" => "fixture")])))))
            disconnectedenv = [pair for pair in env if first(pair) != "OPENAI_BASE_URL"]
            push!(disconnectedenv, "OPENAI_BASE_URL" => disconnectedbase)
            pi_disconnect = runprocess(pi, "", disconnectedenv)
            jf_disconnect = runprocess(jf, "", disconnectedenv)
            @test pi_disconnect.status == jf_disconnect.status == 0
            @test eventview.(records(jf_disconnect.output)) == eventview.(records(pi_disconnect.output))
            write(joinpath(agentdir, "models.json"), JSON3.write(Dict("providers" => Dict("openai" => Dict("baseUrl" => base, "api" => "openai-completions", "apiKey" => "fixture", "models" => [Dict("id" => "fixture")])))))

            pi_rpc = Cmd(`node $oracle $source --mode rpc --no-session --provider openai --model fixture`; dir=workspace)
            jf_rpc = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode rpc --no-session`; dir=workspace)
            while isready(requests)
                take!(requests)
            end
            if Sys.isunix()
                pi_bash_dir = joinpath(workspace, "bash-pi")
                jf_bash_dir = joinpath(workspace, "bash-jf")
                pi_bash_cmd = Cmd(`node $oracle $source --mode rpc --session-dir $pi_bash_dir --provider openai --model fixture`; dir=workspace)
                jf_bash_cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode rpc --session-dir $jf_bash_dir`; dir=workspace)
                providerrequest() = (timedwait(() -> isready(requests), 45) == :ok || error("Provider request did not arrive"); take!(requests))
                pi_bash = exchangebash(pi_bash_cmd, env; promptafter=true, sessiondir=pi_bash_dir)
                pi_context = providerrequest()
                jf_bash = exchangebash(jf_bash_cmd, env; promptafter=true, sessiondir=jf_bash_dir)
                jf_context = providerrequest()
                contexttext(message) = get(message, "content", "") isa AbstractString ? message["content"] : join(get(block, "text", "") for block in message["content"])
                bashcontext(request) = [replace(contexttext(message), r"Full output: [^\]\n]+" => "Full output: <output>") for message in request["messages"] if get(message, "role", "") == "user" && occursin("Ran `", contexttext(message))]
                @test bashcontext(jf_context) == bashcontext(pi_context)
                @test length(bashcontext(jf_context)) == 5
                @test all(!occursin("printf 'bad", text) for text in bashcontext(jf_context))
                @test !pi_bash.shellfile && !jf_bash.shellfile
                entryroles(exchange) = [(entry["type"], get(get(entry, "message", Dict()), "role", "")) for entry in get(get(exchange.entries, "data", Dict()), "entries", [])]
                @test entryroles(jf_bash) == entryroles(pi_bash)
                pi_bash_resume = Cmd(`node $oracle $source --mode rpc --continue --session-dir $pi_bash_dir --provider openai --model fixture`; dir=workspace)
                jf_bash_resume = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode rpc --continue --session-dir $jf_bash_dir`; dir=workspace)
                resumeinput = join(JSON3.write.([(; id="messages", type="get_messages"), (; id="entries", type="get_entries")]), "\n") * "\n"
                pi_restored = runprocess(pi_bash_resume, resumeinput, env)
                jf_restored = runprocess(jf_bash_resume, resumeinput, env)
                savedbash(messages) = [Dict(key => value for (key, value) in message if key != "timestamp") for message in messages if get(message, "role", "") == "bashExecution"]
                @test savedbash(responses(pi_restored.output)["messages"]["data"]["messages"]) == savedbash(pi_bash.messages["data"]["messages"])
                @test savedbash(responses(jf_restored.output)["messages"]["data"]["messages"]) == savedbash(jf_bash.messages["data"]["messages"])
                @test responses(pi_restored.output)["entries"]["data"]["entries"] == pi_bash.entries["data"]["entries"]
                @test responses(jf_restored.output)["entries"]["data"]["entries"] == jf_bash.entries["data"]["entries"]
                for exchange in (pi_bash, jf_bash), reply in exchange.replies
                    haskey(get(reply, "data", Dict()), "fullOutputPath") && rm(reply["data"]["fullOutputPath"])
                end
            end

            pi_run = exchange(pi_rpc, env)
            jf_run = exchange(jf_rpc, env)
            events(run) = [eventview(event) for event in run.observed if !(event["type"] in ("response", "queue_update", "session_info_changed"))]
            @test events(jf_run) == events(pi_run)
            @test jf_run.name == pi_run.name
            @test [value["role"] for value in jf_run.messages["data"]["messages"]] == [value["role"] for value in pi_run.messages["data"]["messages"]]
            @test jf_run.state["data"]["messageCount"] == pi_run.state["data"]["messageCount"]
            @test jf_run.state["data"]["sessionName"] == pi_run.state["data"]["sessionName"]
            @test jf_run.clone == pi_run.clone
            @test jf_run.clonestate["data"]["messageCount"] == pi_run.clonestate["data"]["messageCount"]
            @test jf_run.clonestate["data"]["sessionId"] != jf_run.state["data"]["sessionId"]
            forktexts(result) = [item["text"] for item in get(get(result.fork.messages, "data", Dict()), "messages", [])]
            @test forktexts(jf_run) == forktexts(pi_run) == ["hello"]
            userentryids(run) = Set(entry["id"] for entry in run.fork.records["data"]["entries"] if entry["type"] == "message" && get(entry["message"], "role", "") == "user")
            @test all(entry["entryId"] in userentryids(jf_run) for entry in jf_run.fork.messages["data"]["messages"])
            @test all(entry["entryId"] in userentryids(pi_run) for entry in pi_run.fork.messages["data"]["messages"])
            @test jf_run.fork.reply == pi_run.fork.reply
            @test jf_run.fork.state["data"]["messageCount"] == pi_run.fork.state["data"]["messageCount"]
            @test jf_run.fork.state["data"]["sessionId"] != jf_run.clonestate["data"]["sessionId"]
            @test !jf_run.fork.invalid["success"] && !pi_run.fork.invalid["success"]
            @test jf_run.fork.after["data"]["sessionId"] == jf_run.fork.state["data"]["sessionId"]
            @test get(jf_run.stats, "data", nothing) !== nothing
            for key in ("userMessages", "assistantMessages", "toolCalls", "toolResults", "totalMessages", "tokens", "cost")
                @test get(get(jf_run.stats, "data", Dict()), key, nothing) == pi_run.stats["data"][key]
            end
            @test jf_run.new == pi_run.new
            @test jf_run.newstate["data"]["messageCount"] == pi_run.newstate["data"]["messageCount"] == 0
            @test jf_run.newstate["data"]["sessionId"] != jf_run.state["data"]["sessionId"]
            @test !haskey(jf_run.newstate["data"], "sessionName")

            pi_switch_rpc = Cmd(`node $oracle $source --mode rpc --session-dir $(joinpath(workspace, "switch-pi")) --provider openai --model fixture`; dir=workspace)
            jf_switch_rpc = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode rpc --session-dir $(joinpath(workspace, "switch-jf"))`; dir=workspace)
            pi_switch = exchange(pi_switch_rpc, env; switching=true)
            jf_switch = exchange(jf_switch_rpc, env; switching=true, protect=true)
            @test pi_switch.exported.reply["success"] && jf_switch.exported.reply["success"]
            @test pi_switch.exported.reply["data"]["path"] == pi_switch.exported.path
            @test get(get(jf_switch.exported.reply, "data", Dict()), "path", nothing) == jf_switch.exported.path
            @test occursin("Hello world", pihtml(pi_switch.exported.html)) && occursin("Hello world", jf_switch.exported.html)
            @test !pi_switch.exported.invalid["success"] && !jf_switch.exported.invalid["success"]
            @test !jf_switch.exported.overwrite["success"] && jf_switch.exported.unchanged
            @test jf_switch.clone == pi_switch.clone
            @test jf_switch.clonestate["data"]["messageCount"] == pi_switch.clonestate["data"]["messageCount"]
            @test forktexts(jf_switch) == forktexts(pi_switch) == ["hello"]
            @test jf_switch.fork.reply == pi_switch.fork.reply
            @test jf_switch.switched.reply == pi_switch.switched.reply
            @test jf_switch.switched.restored["data"]["sessionId"] == jf_switch.state["data"]["sessionId"]
            @test jf_switch.switched.restored["data"]["messageCount"] == pi_switch.switched.restored["data"]["messageCount"]
            @test !jf_switch.switched.invalid["success"] && !pi_switch.switched.invalid["success"]
            @test jf_switch.switched.after["data"]["sessionId"] == jf_switch.state["data"]["sessionId"]

            pidir, jfdir = joinpath(workspace, "pi-sessions"), joinpath(workspace, "jf-sessions")
            pi_saved = Cmd(`node $oracle $source --mode json --session-dir $pidir --provider openai --model fixture hello`; dir=workspace)
            jf_saved = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode json --session-dir $jfdir hello`; dir=workspace)
            pi_first = runprocess(pi_saved, "", env)
            jf_first = runprocess(jf_saved, "", env)
            pi_resume = Cmd(`node $oracle $source --mode rpc --continue --session-dir $pidir --provider openai --model fixture`; dir=workspace)
            jf_resume = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode rpc --continue --session-dir $jfdir`; dir=workspace)
            inspection = join(JSON3.write.([(; id="messages", type="get_messages"), (; id="state", type="get_state"), (; id="last", type="get_last_assistant_text")]), "\n") * "\n"
            pi_again = runprocess(pi_resume, inspection, env)
            jf_again = runprocess(jf_resume, inspection, env)
            @test pi_first.status == jf_first.status == pi_again.status == jf_again.status == 0
            pi_restored, jf_restored = responses(pi_again.output), responses(jf_again.output)
            @test jf_restored["last"] == pi_restored["last"]
            @test jf_restored["state"]["data"]["messageCount"] == pi_restored["state"]["data"]["messageCount"]
            @test [m["role"] for m in jf_restored["messages"]["data"]["messages"]] == [m["role"] for m in pi_restored["messages"]["data"]["messages"]]
            @test jf_restored["state"]["data"]["sessionId"] == first(records(jf_first.output))["id"]
            @test isfile(jf_restored["state"]["data"]["sessionFile"])

            image_dir = joinpath(workspace, "image-sessions")
            image_cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode rpc --session-dir $image_dir`; dir=workspace)
            image = (; type="image", mimeType="image/png", data="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/aX0AAAAASUVORK5CYII=")
            saved = saveimagequeue(image_cmd, env, image)
            @test saved["success"]
            image_resume = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode rpc --continue --session-dir $image_dir`; dir=workspace)
            replay = exchangereplay(image_resume, env)
            @test replay.state["data"]["pendingMessageCount"] == 1
            @test !replay.clear["success"]
            @test any(event -> event["type"] == "queue_update" && event["steering"] == ["saved"], replay.observed)
            @test any(block -> get(block, "type", "") == "image" && block["data"] == image.data, Iterators.flatten(message["content"] for message in replay.messages["data"]["messages"] if message["role"] == "user"))

            arrivals = Channel{Channel{Nothing}}(Inf)
            gated = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
                gate = Channel{Nothing}(1)
                put!(arrivals, gate)
                take!(gate)
                HTTP.Response(200, ["Content-Type" => "text/event-stream"], body)
            end
            try
                gatedbase = "http://$(HTTP.server_addr(gated))/v1"
                write(joinpath(agentdir, "models.json"), JSON3.write(Dict("providers" => Dict("openai" => Dict("baseUrl" => gatedbase, "api" => "openai-completions", "apiKey" => "fixture", "models" => [Dict("id" => "fixture")])))))
                gatedenv = [pair for pair in env if first(pair) != "OPENAI_BASE_URL"]
                push!(gatedenv, "OPENAI_BASE_URL" => gatedbase)
                pi_image = exchangequeued(pi_rpc, gatedenv, arrivals; image=true)
                jf_image = exchangequeued(jf_rpc, gatedenv, arrivals; image=true, protect=true)
                imageusers(run) = [message["content"] for message in run.messages["data"]["messages"] if message["role"] == "user"]
                @test imageusers(jf_image) == imageusers(pi_image)
                @test count(block -> block["type"] == "image", Iterators.flatten(imageusers(jf_image))) == 3
                @test all(event -> event["steering"] isa AbstractVector && event["followUp"] isa AbstractVector, filter(event -> event["type"] == "queue_update", jf_image.observed))
                pi_queue = exchangequeued(pi_rpc, gatedenv, arrivals)
                jf_queue = exchangequeued(jf_rpc, gatedenv, arrivals)
                @test jf_queue.first == pi_queue.first
                @test jf_queue.steer == pi_queue.steer
                @test jf_queue.follow == pi_queue.follow
                @test jf_queue.busy == pi_queue.busy
                usertexts(run) = [join(block["text"] for block in message["content"] if block["type"] == "text") for message in run.messages["data"]["messages"] if message["role"] == "user"]
                @test usertexts(jf_queue) == usertexts(pi_queue)
                queuedids(run) = Set(entry["id"] for entry in run.entries["data"]["entries"] if entry["type"] == "message" && get(entry["message"], "role", "") == "user")
                @test all(item["entryId"] in queuedids(jf_queue) for item in jf_queue.forks["data"]["messages"])
                @test all(item["entryId"] in queuedids(pi_queue) for item in pi_queue.forks["data"]["messages"])
                if Sys.isunix()
                    pi_pending = exchangebashduringturn(pi_rpc, gatedenv, arrivals)
                    jf_pending = exchangebashduringturn(jf_rpc, gatedenv, arrivals)
                    @test jf_pending.reply == pi_pending.reply
                    bashroles(reply) = [message["role"] for message in reply["data"]["messages"]]
                    @test bashroles(jf_pending.before) == bashroles(pi_pending.before)
                    @test bashroles(jf_pending.after) == bashroles(pi_pending.after)
                    @test last(bashroles(jf_pending.after)) == "bashExecution"
                end

                pi_abort = exchangeaborted(pi_rpc, gatedenv, arrivals)
                jf_abort = exchangeaborted(jf_rpc, gatedenv, arrivals)
                @test jf_abort.reply == pi_abort.reply
                @test jf_abort.settled == pi_abort.settled == Dict("type" => "agent_settled", "aborted" => true)
                reasons(run) = [event["message"]["stopReason"] for event in run.observed if event["type"] == "message_end" && get(event["message"], "role", "") == "assistant"]
                @test reasons(jf_abort) == reasons(pi_abort) == ["aborted"]
                pi_all_dir, jf_all_dir = joinpath(workspace, "pi-all"), joinpath(workspace, "jf-all")
                for directory in (pi_all_dir, jf_all_dir)
                    mkpath(directory)
                    cp(joinpath(agentdir, "models.json"), joinpath(directory, "models.json"))
                end
                allenv(directory) = vcat([pair for pair in gatedenv if first(pair) != "PI_CODING_AGENT_DIR"], ["PI_CODING_AGENT_DIR" => directory])
                pi_all = exchangeallqueued(pi_rpc, allenv(pi_all_dir), arrivals)
                jf_all = exchangeallqueued(jf_rpc, allenv(jf_all_dir), arrivals)
                @test usertexts(jf_all) == usertexts(pi_all) == ["hello", "steer one", "steer two", "follow one", "follow two"]
                @test jf_all.calls == pi_all.calls == 3
            finally
                close(gated)
                wait(gated)
            end

            call = Dict("index" => 0, "id" => "call-1", "type" => "function", "function" => Dict("name" => "read", "arguments" => ""))
            fragments = [Dict("role" => "assistant", "tool_calls" => [call]), Dict("tool_calls" => [Dict("index" => 0, "function" => Dict("arguments" => "{\"path\":\"target.txt\"}"))]), Dict()]
            toolchunks = [Dict("id" => "fixture", "object" => "chat.completion.chunk", "created" => 1, "model" => "fixture", "choices" => [Dict("index" => 0, "delta" => delta, "finish_reason" => finish)]) for (delta, finish) in zip(fragments, (nothing, nothing, "tool_calls"))]
            toolbody = join(("data: " * JSON3.write(chunk) * "\n\n" for chunk in toolchunks)) * "data: [DONE]\n\n"
            write(joinpath(workspace, "target.txt"), "alpha\n")
            toolserver = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
                try
                    data = JSON3.read(codeunits(String(request.body)))
                    aftertool = any(message -> message.role == "tool", data.messages)
                    HTTP.Response(200, ["Content-Type" => "text/event-stream"], aftertool ? body : toolbody)
                catch exception
                    println(stderr, "Tool fixture failed: ", sprint(showerror, exception))
                    HTTP.Response(500)
                end
            end
            try
                toolbase = "http://$(HTTP.server_addr(toolserver))/v1"
                write(joinpath(agentdir, "models.json"), JSON3.write(Dict("providers" => Dict("openai" => Dict("baseUrl" => toolbase, "api" => "openai-completions", "apiKey" => "fixture", "models" => [Dict("id" => "fixture")])))))
                toolenv = [pair for pair in env if first(pair) != "OPENAI_BASE_URL"]
                push!(toolenv, "OPENAI_BASE_URL" => toolbase)
                pi_tools = runprocess(pi, "", toolenv)
                jf_tools = runprocess(jf, "", toolenv)
                @test pi_tools.status == jf_tools.status == 0
                @test count(event -> event["type"] == "tool_execution_end", records(pi_tools.output)) == 1
                @test eventview.(records(jf_tools.output)) == eventview.(records(pi_tools.output))
            finally
                close(toolserver)
                wait(toolserver)
            end
        end
    finally
        close(server)
        wait(server)
    end
end

end
