@testset "Pi session history" begin
    S = JuliaForever.Sessions
    @test readchomp(`git -C $(ENV["PI_SOURCE"]) rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    script = joinpath(@__DIR__, "session_reference.mjs")
    function view(session)
        rows = S.entries(session)
        ids = Dict(row["id"] => index for (index, row) in enumerate(rows))
        active = [ids[row["id"]] for row in S.branch(session)]
        leaf = isnothing(S.leaf(session)) ? nothing : ids[S.leaf(session)]
        for row in rows
            row["id"] = ids[row["id"]]
            row["parentId"] = isnothing(row["parentId"]) ? nothing : ids[row["parentId"]]
            delete!(row, "timestamp")
        end
        Dict("rows" => rows, "active" => active, "leaf" => leaf)
    end
    mktempdir() do dir
        file = joinpath(dir, "julia.jsonl")
        referencefile = joinpath(dir, "pi.jsonl")
        reference = JSON3.read(read(`node $script $(ENV["PI_SOURCE"]) build $referencefile`, String), Dict{String, Any})
        session = S.Session(file; cwd=dir)
        setup = S.record!(session, "model_change", Dict("provider" => "example", "modelId" => "model"))
        S.record!(session, Dict("role" => "system", "content" => "instructions", "timestamp" => 1))
        before = isfile(file)
        question = S.record!(session, Dict("role" => "user", "content" => "question", "timestamp" => 2))
        after = isfile(file)
        answer = S.record!(session, Dict("role" => "assistant", "content" => "answer", "timestamp" => 3))
        abandoned = S.record!(session, Dict("role" => "user", "content" => "abandoned", "timestamp" => 4))
        S.branch!(session, question)
        S.record!(session, Dict("role" => "assistant", "content" => "alternative", "timestamp" => 5))
        S.record!(session, "custom", Dict("customType" => "state", "data" => Dict("count" => 1)))
        active = [entry["id"] for entry in S.branch(session)]
        old = [entry["id"] for entry in S.branch(session, abandoned)]
        children = [entry["id"] for entry in S.children(session, question)]
        S.branch!(session, nothing)
        S.record!(session, Dict("role" => "user", "content" => "new root", "timestamp" => 6))
        S.branch!(session, answer)
        branchonly = S.leaf(open(S.Session, file))
        S.record!(session, Dict("role" => "user", "content" => "continued", "timestamp" => 7))
        final = open(S.Session, file)
        ids = Dict(entry["id"] => index for (index, entry) in enumerate(S.entries(final)))
        result = merge(view(final), Dict("before" => before, "after" => after, "activeBefore" => [ids[id] for id in active], "old" => [ids[id] for id in old], "children" => [ids[id] for id in children], "branchOnlyReopened" => ids[branchonly], "setup" => ids[setup]))
        @test result == reference
        @test view(open(S.Session, referencefile)) == view(final)
        piopened = JSON3.read(read(`node $script $(ENV["PI_SOURCE"]) read $file`, String), Dict{String, Any})
        @test piopened == view(final)
    end
end
