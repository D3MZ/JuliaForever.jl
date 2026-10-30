using Test, JuliaForever, HTTP, JSON3, TOML

using JuliaForever: CodeMode, CodeCancellation, cancel!, codeexecute

@testset "CodeMode tool selection" begin
    mktempdir() do dir
        nested = CodeMode([Read(dir)])
        mode = CodeMode([Read(dir), nested, Write(dir)])
        @test Set(keys(mode.tools)) == Set(["read", "write"])
        @test isempty(CodeMode([nested]).tools)
    end
end

struct DelayedWrite <: JuliaForever.Tool
    path::String
end
JuliaForever.name(::DelayedWrite) = "delayed_write"
JuliaForever.description(::DelayedWrite) = "Write after a delay."
JuliaForever.schema(::DelayedWrite) = Dict("type" => "object")
function JuliaForever.execute(tool::DelayedWrite, args)
    write(tool.path * ".started", "started")
    sleep(1.5)
    write(tool.path, "finished")
    ToolResult("finished")
end

struct GatedCalls <: JuliaForever.Tool
    entered::Channel{Int}
    gates::Vector{Channel{Nothing}}
    finished::Channel{Int}
    tasks::Channel{Task}
end
GatedCalls(n) = GatedCalls(Channel{Int}(n), [Channel{Nothing}(1) for _ in 1:n], Channel{Int}(n), Channel{Task}(n))
JuliaForever.name(::GatedCalls) = "gated"
JuliaForever.description(::GatedCalls) = "Wait for a test gate."
JuliaForever.schema(::GatedCalls) = Dict("type" => "object")
function JuliaForever.execute(tool::GatedCalls, args)
    id = Int(args.id)
    put!(tool.tasks, current_task())
    put!(tool.entered, id)
    take!(tool.gates[id])
    put!(tool.finished, id)
    ToolResult("reply-$id")
end

struct LargeReply <: JuliaForever.Tool
    entered::Channel{Task}
    gate::Channel{Nothing}
    marker::String
end
JuliaForever.name(::LargeReply) = "large"
JuliaForever.description(::LargeReply) = "Send a large reply."
JuliaForever.schema(::LargeReply) = Dict("type" => "object")
function JuliaForever.execute(tool::LargeReply, args)
    write(tool.marker, "started")
    put!(tool.entered, current_task())
    take!(tool.gate)
    ToolResult(repeat("x", 4_000_000))
end

function arrivals(channel, count)
    values = Int[]
    for _ in 1:count
        timedwait(() -> isready(channel), 20) == :ok || break
        push!(values, take!(channel))
    end
    values
end

@testset "code mode coordination" begin
    mktempdir() do dir
        n = 12
        if isdir("/dev/fd")
            @test codeexecute(CodeMode(JuliaForever.Tool[]; timeout=30), "nothing").ok
            GC.gc()
            yield()
            handles = length(readdir("/dev/fd"))
        end
        tool = GatedCalls(n)
        mode = CodeMode([tool]; timeout=30)
        cancel = CodeCancellation()
        source = "jobs = [Threads.@spawn tools.gated((; id=i)) for i in 1:$n]; [fetch(job).text for job in jobs]"
        run = Threads.@spawn codeexecute(mode, source; cancel)
        entered = arrivals(tool.entered, n)
        @test Set(entered) == Set(1:n)
        if length(entered) == n
            tasks = [take!(tool.tasks) for _ in 1:n]
            for id in n:-1:1
                put!(tool.gates[id], nothing)
                @test arrivals(tool.finished, 1) == [id]
            end
            ready = timedwait(() -> istaskdone(run), 30)
            @test ready == :ok
            if ready == :ok
                result = fetch(run)
                @test result.ok && result.value == ["reply-$id" for id in 1:n]
                @test length(result.calls) == n && all(call -> call.status == :ok, result.calls)
            end
            @test timedwait(() -> all(istaskdone, tasks), 5) == :ok
        else
            foreach(close, tool.gates)
        end
        cancel!(cancel)

        tool = GatedCalls(1)
        timeout = Threads.@spawn codeexecute(CodeMode([tool]; timeout=8), "tools.gated((; id=1))")
        entered = arrivals(tool.entered, 1)
        @test entered == [1]
        if !isempty(entered)
            task = take!(tool.tasks)
            ready = timedwait(() -> istaskdone(timeout), 15)
            @test ready == :ok
            if ready == :ok
                result = fetch(timeout)
                @test !result.ok && result.kind == :timeout
                @test only(result.calls).status == :unresolved
                if Sys.isunix()
                    @test ccall(:kill, Cint, (Cint, Cint), result.pid, 0) == -1
                end
            end
            put!(tool.gates[1], nothing)
            @test arrivals(tool.finished, 1) == [1]
            @test timedwait(() -> istaskdone(task), 5) == :ok
        else
            close(tool.gates[1])
        end

        tool = GatedCalls(2)
        cancel = CodeCancellation()
        mode = CodeMode([tool]; timeout=30)
        runs = [Threads.@spawn codeexecute(mode, "tools.gated((; id=$id))"; cancel) for id in 1:2]
        entered = arrivals(tool.entered, 2)
        @test Set(entered) == Set(1:2)
        tasks = [take!(tool.tasks) for _ in entered]
        cancel!(cancel)
        cancel!(cancel)
        ready = timedwait(() -> all(istaskdone, runs), 5)
        @test ready == :ok
        if ready == :ok
            results = fetch.(runs)
            @test all(result -> !result.ok && result.kind == :cancelled, results)
            @test all(result -> only(result.calls).status == :unresolved, results)
            @test isempty(cancel.events)
            if Sys.isunix()
                @test all(result -> ccall(:kill, Cint, (Cint, Cint), result.pid, 0) == -1, results)
            end
        end
        foreach(gate -> put!(gate, nothing), tool.gates)
        @test Set(arrivals(tool.finished, length(entered))) == Set(entered)
        @test timedwait(() -> all(istaskdone, tasks), 5) == :ok

        tool = GatedCalls(1)
        source = "Threads.@spawn tools.gated((; id=1)); sleep(1); exit(0)"
        run = Threads.@spawn codeexecute(CodeMode([tool]; timeout=30), source)
        entered = arrivals(tool.entered, 1)
        @test entered == [1]
        if !isempty(entered)
            task = take!(tool.tasks)
            ready = timedwait(() -> istaskdone(run), 10)
            @test ready == :ok
            if ready == :ok
                result = fetch(run)
                @test !result.ok && result.kind == :worker
                @test only(result.calls).status == :unresolved
            end
            put!(tool.gates[1], nothing)
            @test arrivals(tool.finished, 1) == [1]
            @test timedwait(() -> istaskdone(task), 5) == :ok
        else
            close(tool.gates[1])
        end

        cancel = CodeCancellation()
        marker = joinpath(dir, "flood-started")
        source = "write($(repr(marker)), \"started\"); while true; text(\"x\"); end"
        run = Threads.@spawn codeexecute(CodeMode(JuliaForever.Tool[]; timeout=30), source; cancel)
        @test timedwait(() -> isfile(marker), 20) == :ok
        cancel!(cancel)
        ready = timedwait(() -> istaskdone(run), 5)
        @test ready == :ok
        if ready == :ok
            result = fetch(run)
            @test !result.ok && result.kind == :cancelled
            @test isempty(cancel.events)
        end

        cancel = CodeCancellation()
        source = "Main.send((; type=\"call_done\", index=999, status=\"ok\", duration=0)); sleep(30)"
        result = codeexecute(CodeMode(JuliaForever.Tool[]; timeout=30), source; cancel)
        @test !result.ok && result.kind == :worker
        @test isempty(cancel.events)
        if Sys.isunix()
            @test ccall(:kill, Cint, (Cint, Cint), result.pid, 0) == -1
        end

        started = joinpath(dir, "tool-started")
        tool = LargeReply(Channel{Task}(1), Channel{Nothing}(1), started)
        cancel = CodeCancellation()
        marker = joinpath(dir, "busy-worker")
        source = "Threads.@spawn tools.large((;)); while !isfile($(repr(started))); yield(); end; write($(repr(marker)), \"started\"); while true; end"
        withenv("JULIA_NUM_THREADS" => "1") do
            run = Threads.@spawn codeexecute(CodeMode([tool]; timeout=30), source; cancel)
            ready = timedwait(() -> isready(tool.entered) && isfile(marker), 20)
            @test ready == :ok
            task = ready == :ok ? take!(tool.entered) : nothing
            if !isnothing(task)
                put!(tool.gate, nothing)
                sleep(0.2)
                @test !istaskdone(task)
            else
                close(tool.gate)
            end
            cancel!(cancel)
            ready = timedwait(() -> istaskdone(run), 5)
            @test ready == :ok
            if ready == :ok
                result = fetch(run)
                @test !result.ok && result.kind == :cancelled
                if Sys.isunix()
                    @test ccall(:kill, Cint, (Cint, Cint), result.pid, 0) == -1
                end
            end
            !isnothing(task) && @test timedwait(() -> istaskdone(task), 5) == :ok
        end

        worker = joinpath(dirname(pathof(JuliaForever)), "codemode_worker.jl")
        project = dirname(Base.active_project())
        cmd = `$(Base.julia_cmd()) --startup-file=no --project=$project $worker $(joinpath(dir, "stdout")) $(joinpath(dir, "stderr"))`
        process = open(cmd, "r+")
        try
            code = "jobs = [Threads.@spawn tools.gated((; id=i)) for i in 1:3]; answers = fetch.(jobs); push!(answers, tools.gated((; id=4))); [answer.iserror for answer in answers]"
            println(process, JSON3.write((; code, store=Dict(), tools=[])))
            flush(process)
            calls = Threads.@spawn [JSON3.read(readline(process)) for _ in 1:3]
            ready = timedwait(() -> istaskdone(calls), 20)
            @test ready == :ok
            if ready == :ok
                @test all(call -> call.type == "call", fetch(calls))
                close(process.in)
                response = Threads.@spawn JSON3.read(readline(process))
                ready = timedwait(() -> istaskdone(response), 5)
                @test ready == :ok
                if ready == :ok
                    result = fetch(response)
                    @test result.type == "result" && result.ok
                    @test result.value == [true, true, true, true]
                end
            end
        finally
            process_running(process) && kill(process, Base.SIGKILL)
            wait(process)
            close(process)
        end
        if isdir("/dev/fd")
            GC.gc()
            yield()
            @test length(readdir("/dev/fd")) <= handles + 2
        end
    end
end

@testset "Julia code mode" begin
    mktempdir() do dir
        mode = CodeMode([Read(dir), Write(dir), Edit(dir)]; timeout=30)
        result = codeexecute(mode, """
            struct Marker
                value::Int
            end
            f(x::Integer) = "integer"
            f(x::AbstractString) = "string"
            f(x::Marker) = x.value
            println("ordinary stdout")
            text(f(3))
            text(f("hello"))
            text(f(Marker(17)))
            println(stderr, "ordinary stderr")
            (; pid=getpid(), names=[item.name for item in ALL_TOOLS], read_schema=only(filter(item -> item.name == "read", ALL_TOOLS)).schema)
            """)
        @test result.ok
        @test result.value.pid != getpid()
        @test Set(result.value.names) == Set(["read", "write", "edit"])
        @test result.value.read_schema.properties.path.type == "string"
        @test occursin("read", JuliaForever.description(mode))
        @test occursin("path", JuliaForever.description(mode))
        @test result.output == ["integer", "string", "17"]
        @test occursin("ordinary stdout", result.stdout)
        @test occursin("ordinary stderr", result.stderr)

        result = codeexecute(mode, """
            a = tools.write((; path="file.txt", content="hello"))
            b = tools["read"]((; path="file.txt"))
            c = tools.read((; path="missing"))
            d = tools["missing"]((;))
            (; a, b, c, d)
            """)
        @test result.ok
        @test result.value.a.text == "Successfully wrote to file.txt"
        @test result.value.b.text == "hello"
        @test result.value.c.iserror
        @test result.value.d.iserror
        @test [call.name for call in result.calls] == ["write", "read", "read", "missing"]
        @test [call.status for call in result.calls] == [:ok, :ok, :error, :error]

        result = codeexecute(mode, """
            @sync begin
                a = @async tools.read((; path="file.txt"))
                b = @async tools.read((; path="file.txt"))
                global answers = (fetch(a).text, fetch(b).text)
            end
            answers
            """)
        @test result.ok && result.value == ["hello", "hello"]
        @test length(result.calls) == 2
        @test all(call -> call.status == :ok, result.calls)

        toolresult = execute(mode, (; code="text(\"visible\"); 5"))
        @test !toolresult.iserror && toolresult.text == "visible\n5"
        toolresult = execute(mode, (; code="1 + \"bad\""))
        @test toolresult.iserror && occursin("MethodError", toolresult.text)
        @test !execute(mode, (; code="store(\"counter\", 4)")).iserror
        @test execute(mode, (; code="load(\"counter\")")).text == "4"
        @test execute(mode, (; code="store(\"counter\", 9); 1 + \"bad\"")).iserror
        @test execute(mode, (; code="load(\"counter\")")).text == "4"

        result = codeexecute(mode, "text(\"before\"); 1 + \"bad\"")
        @test !result.ok
        @test result.kind == :script
        @test occursin("MethodError", result.message)
        @test result.output == ["before"]
        @test codeexecute(mode, "isdefined(@__MODULE__, :f)").value == false
        direct = joinpath(dir, "direct")
        @test codeexecute(mode, "write($(repr(direct)), \"direct filesystem access\")").ok
        @test read(direct, String) == "direct filesystem access"
        stopped = codeexecute(mode, "text(\"before exit\"); exit(0)")
        @test !stopped.ok && stopped.kind == :worker
        @test stopped.output == ["before exit"]

        state = Dict("count" => 2)
        result = codeexecute(mode, "store(\"count\", load(\"count\") + 1); load(\"count\")"; store=state)
        @test result.ok && result.value == 3
        @test result.writes == Dict("count" => 3)
        @test state["count"] == 2
        result = codeexecute(mode, """
            @sync for i in 1:16
                Threads.@spawn store(string(i), i)
            end
            sum(load(string(i)) for i in 1:16)
            """)
        @test result.ok && result.value == 136
        @test length(result.writes) == 16
        result = codeexecute(mode, "store(\"count\", 9); 1 + \"bad\""; store=state)
        @test !result.ok && isempty(result.writes)

        timeout = codeexecute(CodeMode(JuliaForever.Tool[]; timeout=3), "text(\"started\"); flush(stdout); while true; end")
        @test !timeout.ok && timeout.kind == :timeout
        @test timeout.output == ["started"]
        if Sys.isunix()
            @test ccall(:kill, Cint, (Cint, Cint), timeout.pid, 0) == -1
        end

        flood = codeexecute(CodeMode(JuliaForever.Tool[]; timeout=3), "while true; text(\"x\"); end")
        @test !flood.ok && flood.kind == :timeout && !isempty(flood.output)

        cancel = CodeCancellation()
        cancel!(cancel)
        skipped = codeexecute(mode, "write(\"should-not-run\", \"bad\")"; cancel)
        @test !skipped.ok && skipped.kind == :cancelled && skipped.pid == 0

        cancel = CodeCancellation()
        marker = joinpath(dir, "worker-started")
        task = @async codeexecute(CodeMode(JuliaForever.Tool[]; timeout=30), "write($(repr(marker)), \"started\"); sleep(30)"; cancel)
        @test timedwait(() -> isfile(marker), 20) == :ok
        cancel!(cancel)
        cancelled = fetch(task)
        @test !cancelled.ok && cancelled.kind == :cancelled
        if Sys.isunix()
            @test ccall(:kill, Cint, (Cint, Cint), cancelled.pid, 0) == -1
        end

        if isdir("/dev/fd")
            codeexecute(mode, "nothing")
            count = length(readdir("/dev/fd"))
            for _ in 1:4
                @test codeexecute(mode, "nothing").ok
            end
            yield()
            @test length(readdir("/dev/fd")) <= count + 2
        end

        path = joinpath(dir, "nested")
        cancel = CodeCancellation()
        task = @async codeexecute(CodeMode([DelayedWrite(path)]; timeout=30), "tools.delayed_write((;))"; cancel)
        @test timedwait(() -> isfile(path * ".started"), 20) == :ok
        cancel!(cancel)
        cancelled = fetch(task)
        @test !cancelled.ok && cancelled.kind == :cancelled
        @test only(cancelled.calls).status == :unresolved
        @test timedwait(() -> isfile(path), 5) == :ok
    end
end

mutable struct CodeProvider
    messages::Vector{Any}
    replies::Vector{Any}
end
function JuliaForever.complete(provider::CodeProvider, messages, tools)
    push!(provider.messages, deepcopy(messages))
    popfirst!(provider.replies)
end

@testset "agent calls Julia code mode" begin
    mktempdir() do dir
        call = Dict("id" => "code-1", "type" => "function", "function" => Dict("name" => "codemode", "arguments" => JSON3.write((; code="result = tools.write((; path=\"from-code.txt\", content=\"native Julia\")); text(result.text)"))))
        provider = CodeProvider([], [Dict("role" => "assistant", "content" => nothing, "tool_calls" => [call]), Dict("role" => "assistant", "content" => "done")])
        agent = Agent(provider, [CodeMode([Write(dir)]; timeout=30)])
        @test respond!(agent, "write a file") == "done"
        @test read(joinpath(dir, "from-code.txt"), String) == "native Julia"
        @test provider.messages[2][end]["content"] == "Successfully wrote to from-code.txt"
        @test provider.messages[2][end]["tool_call_id"] == "code-1"
    end
end

@testset "worker from a dependent project" begin
    mktempdir() do dir
        package = Base.pkgdir(JuliaForever)
        manifest = read(joinpath(dirname(Base.active_project()), "Manifest.toml"), String)
        manifest = replace(manifest, r"(?ms)^\[\[deps\.JuliaForever\]\]\n.*?(?=^\[\[deps\.|\z)" => "")
        dependencies = sort!(collect(keys(TOML.parsefile(joinpath(package, "Project.toml"))["deps"])))
        manifest *= "\n[[deps.JuliaForever]]\ndeps = $(JSON3.write(dependencies))\npath = $(JSON3.write(package))\nuuid = \"2b71f2a2-b786-4fd0-b9cc-80b6322c5084\"\nversion = \"0.1.0\"\n"
        write(joinpath(dir, "Project.toml"), "[deps]\nJuliaForever = \"2b71f2a2-b786-4fd0-b9cc-80b6322c5084\"\n")
        write(joinpath(dir, "Manifest.toml"), manifest)
        script = "using JuliaForever; if !isdefined(JuliaForever, :CodeMode); Base.include(JuliaForever, joinpath(dirname(pathof(JuliaForever)), \"codemode.jl\")); end; result = JuliaForever.codeexecute(JuliaForever.CodeMode(JuliaForever.Tool[]; timeout=30), \"1 + 1\"); println(result.ok && result.value == 2)"
        cmd = `$(Base.julia_cmd()) --startup-file=no --project=$dir -e $script`
        @test strip(read(cmd, String)) == "true"
    end
end

@testset "terminal code mode" begin
    requests = []
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        body = JSON3.read(String(request.body))
        push!(requests, body)
        delta = if length(requests) == 1
            call = Dict("index" => 0, "id" => "code-cli", "type" => "function", "function" => Dict("name" => "codemode", "arguments" => JSON3.write((; code="1 + 1"))))
            Dict("tool_calls" => [call])
        else
            Dict("content" => "done")
        end
        finish_reason = length(requests) == 1 ? "tool_calls" : "stop"
        data = JSON3.write((; choices=[(; delta, finish_reason)]))
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $data\n\ndata: [DONE]\n\n")
    end
    try
        withenv("JF_PROVIDER" => "openai", "OPENAI_BASE_URL" => "http://$(HTTP.server_addr(server))/v1", "OPENAI_MODEL" => "test", "OPENAI_API_KEY" => "synthetic") do
            @test JuliaForever.main(["--no-session", "--codemode", "run Julia"]) == 0
        end
        @test any(tool -> tool.function.name == "codemode", requests[1].tools)
        @test requests[2].messages[end].content == "2"
    finally
        close(server)
    end
end
