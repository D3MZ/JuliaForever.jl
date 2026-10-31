using Test, JSON3, JuliaForever

import JuliaForever.Durable as D
import JuliaForever.History as H
import JuliaForever.Logs as L
import JuliaForever.Kernel as K

struct NotJSON
    value::Int
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
