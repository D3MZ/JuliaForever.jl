using Test, JuliaForever, JSON3

struct StoreGate <: JuliaForever.Tool
    entered::Channel{Int}
    gates::Vector{Channel{Nothing}}
end
StoreGate() = StoreGate(Channel{Int}(2), [Channel{Nothing}(1) for _ in 1:2])
JuliaForever.name(::StoreGate) = "store_gate"
JuliaForever.description(::StoreGate) = "Pause a store test."
JuliaForever.schema(::StoreGate) = Dict("type" => "object")
function JuliaForever.execute(gate::StoreGate, args)
    id = Int(args.id)
    put!(gate.entered, id)
    take!(gate.gates[id])
    ToolResult("released")
end

@testset "code mode store deletion" begin
    mode = CodeMode(JuliaForever.Tool[]; timeout=60)
    snapshot = Dict{String, Any}("keep" => 42, "remove" => "old", "π😀" => 9)
    result = codeexecute(mode, """
        before = load("remove")
        forget!("remove")
        forget!("π😀")
        forget!("absent")
        forget!("absent")
        store("temporary", 1)
        forget!("temporary")
        forget!("restored")
        store("restored", 2)
        store("null", nothing)
        (; before, removed=load("remove"), absent=load("absent"), null=load("null"), keep=load("keep"))
        """; store=snapshot)
    @test result.ok
    @test result.ok && result.value.before == "old"
    @test result.ok && isnothing(result.value.removed) && isnothing(result.value.absent) && isnothing(result.value.null)
    @test result.ok && result.value.keep == 42
    @test result.writes == Dict("restored" => 2, "null" => nothing)
    @test hasproperty(result, :deletes) && Set(result.deletes) == Set(["remove", "π😀", "absent", "temporary"])
    @test hasproperty(result, :deletes) && length(result.deletes) == 4
    @test snapshot == Dict("keep" => 42, "remove" => "old", "π😀" => 9)

    many = Dict("key-$i" => i for i in 1:12)
    parallel = codeexecute(mode, """
        @sync for i in 1:12
            Threads.@spawn forget!("key-" * string(i))
        end
        nothing
        """; store=many)
    @test parallel.ok && isempty(parallel.writes)
    @test hasproperty(parallel, :deletes) && Set(parallel.deletes) == Set(keys(many))

    failed = codeexecute(mode, "forget!(\"remove\"); store(\"new\", 1); 1 + \"bad\""; store=snapshot)
    @test !failed.ok && failed.kind == :script && isempty(failed.writes)
    @test hasproperty(failed, :deletes) && isempty(failed.deletes)
    @test snapshot["remove"] == "old"

    mktempdir() do dir
        marker = joinpath(dir, "forgot")
        cancel = CodeCancellation()
        task = Threads.@spawn codeexecute(mode, "forget!(\"remove\"); write($(repr(marker)), \"ready\"); sleep(60)"; store=snapshot, cancel)
        @test timedwait(() -> isfile(marker), 40) == :ok
        cancel!(cancel)
        cancelled = fetch(task)
        @test !cancelled.ok && cancelled.kind == :cancelled && isempty(cancelled.writes)
        @test hasproperty(cancelled, :deletes) && isempty(cancelled.deletes)
        @test snapshot["remove"] == "old"
    end

    @test !execute(mode, (; code="store(\"saved\", 1); store(\"null\", nothing)")).iserror
    @test haskey(mode.store, "null") && isnothing(mode.store["null"])
    @test execute(mode, (; code="forget!(\"saved\"); 1 + \"bad\"")).iserror
    @test mode.store["saved"] == 1
    @test !execute(mode, (; code="forget!(\"saved\"); forget!(\"absent\")")).iserror
    @test !haskey(mode.store, "saved") && haskey(mode.store, "null")
    @test !execute(mode, (; code="forget!(\"null\")")).iserror
    @test !haskey(mode.store, "null")
end

@testset "concurrent store deletion completion order" begin
    for first in (1, 2)
        gate = StoreGate()
        mode = CodeMode([gate]; timeout=60)
        mode.store["key"] = 0
        delete_task = Threads.@spawn execute(mode, (; code="tools.store_gate((; id=1)); forget!(\"key\")"))
        write_task = Threads.@spawn execute(mode, (; code="tools.store_gate((; id=2)); store(\"key\", 7)"))
        tasks = [delete_task, write_task]
        arrived = Int[]
        try
            for _ in 1:2
                timedwait(() -> isready(gate.entered), 50) == :ok && push!(arrived, take!(gate.entered))
            end
            @test Set(arrived) == Set([1, 2])
            if length(arrived) == 2
                second = 3 - first
                put!(gate.gates[first], nothing)
                ready = timedwait(() -> istaskdone(tasks[first]), 50)
                @test ready == :ok
                ready == :ok && @test !fetch(tasks[first]).iserror
                put!(gate.gates[second], nothing)
                ready = timedwait(() -> istaskdone(tasks[second]), 50)
                @test ready == :ok
                ready == :ok && @test !fetch(tasks[second]).iserror
                @test first == 1 ? get(mode.store, "key", nothing) == 7 : !haskey(mode.store, "key")
            end
        finally
            foreach(close, gate.gates)
            foreach(wait, tasks)
            close(gate.entered)
        end
    end
end

if haskey(ENV, "PI_SOURCE")
    include("codemode_store_differential.jl")
end
