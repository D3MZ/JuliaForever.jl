using Test, JSON3, JuliaForever

import JuliaForever.Durable as D
import JuliaForever.History as H
import JuliaForever.Logs as L
import JuliaForever.Kernel as K

struct NotJSON
    value::Int
end

@testset "history value copying and rejection" begin
    shared = Any[1, 2]
    original = Any[shared, shared]
    copied = H.value(original, IdDict())
    @test copied == original
    copied[1][1] = 9
    @test copied[2][1] == 1 && original[1][1] == 1
    cycle = Any[]
    push!(cycle, cycle)
    seen = IdDict()
    @test H.value(cycle, seen) == H.Rejected(:unsupported_value)
    @test isempty(seen)
    @test H.value(Dict(:invalid => 1), IdDict()) == H.Rejected(:unsupported_value)
end

function exercise(history)
    empty = H.snapshot(history)
    @test empty.revision == 0
    @test isempty(collect(empty))
    @test H.append!(history, 0, Any[]) == H.Rejected(:empty_batch)
    @test H.append!(history, 1, Any["stale"]) == H.Rejected(:revision)

    first = Dict("kind" => "plan", "input" => Any[true, 1, -0.0, 0.0, 1.0, nothing, "π", Dict("n" => 3.5)], "numbers" => Any[typemin(Int), typemax(Int), floatmin(Float64), nextfloat(0.0), floatmax(Float64), 1e20])
    original = deepcopy(first)
    @test H.append!(history, 0, Any[first, Dict("kind" => "observe")]) == 1
    first["input"][1] = false
    atone = H.snapshot(history)
    @test atone.revision == 1
    @test isequal(collect(atone), Any[original, Dict("kind" => "observe")])
    items = collect(atone)
    items[1]["input"][8]["n"] = 999.0
    @test isequal(collect(atone), Any[original, Dict("kind" => "observe")])
    exposed = atone.batches
    @test length(exposed) == 1 && length(only(exposed)) == 2
    exposed[1][1]["kind"] = "changed"
    @test collect(atone)[1]["kind"] == "plan"
    @test [typeof(x) for x in collect(atone)[1]["input"][1:5]] == [Bool, Int, Float64, Float64, Float64]
    @test signbit(collect(atone)[1]["input"][3])
    numbers = collect(atone)[1]["numbers"]
    @test [typeof(x) for x in numbers] == [Int, Int, Float64, Float64, Float64, Float64]
    @test all(isequal(x, y) for (x, y) in zip(numbers, original["numbers"]))
    log = L.json(atone)
    @test [row["kind"] for row in JSON3.read(log, Vector{Any})] == ["plan", "observe"]
    @test occursin("-0.0", log)
    @test occursin(string(typemax(Int)), log)
    @test length(collect(eachmatch(r"<li><pre>", L.html(atone)))) == 2

    @test H.append!(history, 1, Any["last"]) == 2
    @test atone.revision == 1
    @test length(collect(atone)) == 2
    @test H.snapshot(history).revision == 2
    @test collect(H.snapshot(history)) == Any[original, Dict("kind" => "observe"), "last"]
    @test H.append!(history, 1, Any["stale"]) == H.Rejected(:revision)
    invalid = String(UInt8[0xff])
    for value in (invalid, Dict(invalid => 1), NotJSON(2), (a=1,), :symbol, Int32(1), Float32(1), big(2), NaN, Inf, Dict(:key => 1), Any[Dict("ok" => NotJSON(1))])
        @test H.append!(history, 2, Any["before", value]) == H.Rejected(:unsupported_value)
        @test H.snapshot(history).revision == 2
        @test length(collect(H.snapshot(history))) == 3
    end
    cycle = Any[]
    push!(cycle, cycle)
    @test H.append!(history, 2, Any[cycle]) == H.Rejected(:unsupported_value)
    @test H.snapshot(history).revision == 2
    @test length(H.snapshot(history).batches) == 2
    collect(H.snapshot(history))
end

function race(histories)
    results = Vector{Any}(undef, 24)
    @sync for i in eachindex(results)
        Threads.@spawn results[i] = H.append!(histories[mod1(i, length(histories))], 0, Any[Dict("writer" => i, "part" => 1), Dict("writer" => i, "part" => 2)])
    end
    @test count(==(1), results) == 1
    @test count(==(H.Rejected(:revision)), results) == 23
    saved = H.snapshot(first(histories))
    @test saved.revision == 1
    rows = collect(saved)
    @test length(rows) == 2
    @test rows[1]["writer"] == rows[2]["writer"]
    @test [row["part"] for row in rows] == [1, 2]
    @test length(saved.batches) == 1 && length(only(saved.batches)) == 2
end

@testset "replaceable histories" begin
    expected = exercise(H.Memory())
    race([H.Memory()])
    if Sys.isunix()
        mktempdir() do dir
            path = joinpath(dir, "histories.jsonl")
            store = open(D.Store, path)
            journal = H.create(store)
            @test journal isa H.Journal
            id = journal.id
            @test isequal(exercise(journal), expected)
            raced = H.create(store)
            race([raced, H.Journal(store, raced.id)])
            close(store)
            @test H.snapshot(journal) == H.Rejected(:closed)
            @test H.append!(journal, 2, Any["closed"]) == H.Rejected(:closed)
            @test H.create(store) == H.Rejected(:closed)

            store = open(D.Store, path)
            reopened = H.Journal(store, id)
            @test H.snapshot(reopened).revision == 2
            @test isequal(collect(H.snapshot(reopened)), expected)
            @test H.append!(reopened, 2, Any["after reopen"]) == 3
            @test collect(H.snapshot(reopened))[end] == "after reopen"
            @test H.snapshot(H.Journal(store, typemax(Int))) == H.Rejected(:history_missing)
            @test H.append!(H.Journal(store, typemax(Int)), 0, Any["missing"]) == H.Rejected(:history_missing)
            close(store)
        end
    end
end

@testset "process restart" begin
    if Sys.isunix()
        mktempdir() do dir
            path = joinpath(dir, "history.jsonl")
            project = dirname(@__DIR__)
            script = """
                using JuliaForever
                import JuliaForever.Durable as D
                import JuliaForever.History as H
                store = open(D.Store, ARGS[1])
                history = H.create(store)
                records = Any[Dict(\"kind\" => \"plan\", \"revision\" => 0, \"id\" => \"read-1\", \"input\" => Dict(\"path\" => \"a.txt\")), Dict(\"kind\" => \"observation\", \"revision\" => 1, \"id\" => \"read-1\", \"value\" => \"done\"), Dict(\"kind\" => \"finish\", \"revision\" => 2)]
                H.append!(history, 0, records) == 1 || exit(2)
                println(history.id)
                close(store)
            """
            id = parse(Int, strip(read(`$(Base.julia_cmd()) --project=$project -e $script $path`, String)))
            store = open(D.Store, path)
            history = H.Journal(store, id)
            snapshot = H.snapshot(history)
            @test snapshot.revision == 1
            rows = collect(snapshot)
            @test [row["kind"] for row in rows] == ["plan", "observation", "finish"]
            @test rows == collect(snapshot)
            events = Any[K.Plan(rows[1]["revision"], rows[1]["id"], K.Call("read", rows[1]["input"])), K.Observe(rows[2]["revision"], rows[2]["id"], K.Return(rows[2]["value"])), K.Finish(rows[3]["revision"])]
            replay = K.Replay(K.State("restart"), events)
            results = collect(replay)
            @test all(result isa K.Applied for result in results)
            @test [result.state.revision for result in results] == [1, 2, 3]
            @test results[end].state.closed
            @test [result.state.revision for result in collect(replay)] == [1, 2, 3]
            @test H.append!(history, 1, Any["next"]) == 2
            close(store)
        end
    end
end
