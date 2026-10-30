@testset "Pi legacy session migration" begin
    S = JuliaForever.Sessions
    @test readchomp(`git -C $(ENV["PI_SOURCE"]) rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    mktempdir() do dir
        fixture = [Dict("type" => "session", "version" => 2, "id" => "legacy", "timestamp" => "2020", "cwd" => dir), Dict("type" => "message", "id" => "a", "parentId" => nothing, "timestamp" => "2020", "message" => Dict("role" => "hookMessage", "content" => "hello"))]
        pi = joinpath(dir, "pi.jsonl")
        jl = joinpath(dir, "julia.jsonl")
        data = join((JSON3.write(row) * "\n" for row in fixture))
        write(pi, data); write(jl, data)
        reference = JSON3.read(read(`node $(joinpath(@__DIR__, "session_reference.mjs")) $(ENV["PI_SOURCE"]) read $pi`, String), Dict{String, Any})
        session = open(S.Session, jl)
        @test session isa S.Session
        if session isa S.Session
            rows = S.entries(session)
            rows[1]["id"] = 1
            delete!(rows[1], "timestamp")
            @test Dict("rows" => rows, "active" => [1], "leaf" => 1) == reference
            @test JSON3.read(first(eachline(jl))).version == 3
        end
    end
    mktempdir() do dir
        header = Dict("type" => "session", "id" => "legacy", "timestamp" => "2020", "cwd" => dir)
        message = Dict("type" => "message", "timestamp" => "2020", "message" => Dict("role" => "hookMessage", "content" => "hello"))
        compact = Dict("type" => "compaction", "timestamp" => "2020", "summary" => "summary", "firstKeptEntryIndex" => 1, "tokensBefore" => 4)
        data = join(JSON3.write(row) * "\n" for row in (header, message, compact))
        pi = joinpath(dir, "pi.jsonl"); jl = joinpath(dir, "julia.jsonl")
        write(pi, data); write(jl, data)
        read(`node $(joinpath(@__DIR__, "session_reference.mjs")) $(ENV["PI_SOURCE"]) read $pi`, String)
        session = open(S.Session, jl)
        @test session isa S.Session
        if session isa S.Session
            reference = [JSON3.read(line, Dict{String, Any}) for line in eachline(pi)]
            actual = [JSON3.read(line, Dict{String, Any}) for line in eachline(jl)]
            for rows in (reference, actual)
                ids = Dict(row["id"] => string(i) for (i, row) in enumerate(rows[2:end]))
                for row in rows[2:end]
                    row["id"] = ids[row["id"]]
                    isnothing(row["parentId"]) || (row["parentId"] = ids[row["parentId"]])
                    haskey(row, "firstKeptEntryId") && (row["firstKeptEntryId"] = ids[row["firstKeptEntryId"]])
                end
            end
            @test actual == reference
        end
    end
    mktempdir() do dir
        file = joinpath(dir, "invalid.jsonl")
        data = "{\"type\":\"session\",\"version\":2,\"id\":\"old\",\"timestamp\":\"2020\",\"cwd\":\"/\"}\n{\"type\":\"message\"}\n"
        write(file, data)
        @test open(S.Session, file) == S.Rejected(:invalid_session)
        @test read(file, String) == data
    end
end
