using JSON3

@testset "session history" begin
    S = JuliaForever.Sessions
    session = S.Session(; cwd=pwd())
    @test S.header(session)["version"] == 3
    @test S.Session(; path=SubString("relative.jsonl", 1)).file == abspath("relative.jsonl")
    @test S.leaf(session) === nothing
    @test isempty(S.branch(session))

    setup = S.record!(session, "model_change", Dict("provider" => "example", "modelId" => "m"))
    question = Dict("role" => "user", "content" => "first", "timestamp" => 1)
    first = S.record!(session, question)
    question["content"] = "mutated"
    answer = S.record!(session, Dict("role" => "assistant", "content" => [Dict("type" => "text", "text" => "answer")], "timestamp" => 2))
    other = S.record!(session, Dict("role" => "user", "content" => "abandoned", "timestamp" => 3))
    @test S.branch!(session, SubString(first, 1))
    branch = S.record!(session, Dict("role" => "user", "content" => "new direction", "timestamp" => 4))
    @test [entry["id"] for entry in S.branch(session)] == [setup, first, branch]
    @test [entry["id"] for entry in S.branch(session, other)] == [setup, first, answer, other]
    @test [entry["id"] for entry in S.children(session, first)] == [answer, branch]
    @test [message["content"] for message in S.messages(session)] == ["first", "new direction"]
    @test !S.branch!(session, "missing")
    @test S.leaf(session) == branch
    @test S.branch!(session, nothing)
    @test isempty(S.branch(session))
    root = S.record!(session, Dict("role" => "user", "content" => "new root"))
    @test only(S.branch(session))["id"] == root
    @test Set(entry["id"] for entry in S.children(session, nothing)) == Set([setup, root])
    snapshot = S.entries(session)
    snapshot[2]["message"]["content"] = "altered"
    @test S.messages(session, first)[1]["content"] == "first"
end

@testset "session persistence" begin
    S = JuliaForever.Sessions
    mktempdir() do dir
        file = joinpath(dir, "session.jsonl")
        session = S.Session(file; cwd=dir)
        @test !session.flushed && session.terminated
        @test setproperty!(session, :terminated, 0) === false
        @test setproperty!(session, :terminated, 1) === true
        @test setproperty!(session, :flushed, 0) === false
        data = JSON3.read(JSON3.write(session))
        @test !data.flushed && data.terminated
        setup = S.record!(session, "model_change", Dict("provider" => "example", "modelId" => "m"))
        system = S.record!(session, Dict("role" => "system", "content" => "instructions"))
        @test !isfile(file)
        question = S.record!(session, Dict("role" => "user", "content" => "hello"))
        answer = S.record!(session, Dict("role" => "assistant", "content" => "reply"))
        @test isfile(file)
        @test session.flushed && session.terminated
        @test [JSON3.read(line)["type"] for line in eachline(file)] == ["session", "model_change", "message", "message", "message"]
        @test S.branch!(session, question)
        alternative = S.record!(session, Dict("role" => "assistant", "content" => "alternative"))
        reopened = open(S.Session, file)
        @test S.header(reopened) == S.header(session)
        @test S.entries(reopened) == S.entries(session)
        @test S.leaf(reopened) == alternative
        @test [entry["id"] for entry in S.branch(reopened)] == [setup, system, question, alternative]
        @test [entry["id"] for entry in S.branch(reopened, answer)] == [setup, system, question, answer]
        @test S.branch!(session, answer)
        @test S.leaf(open(S.Session, file)) == alternative
        extra = S.record!(reopened, "custom", Dict("customType" => "data", "data" => Dict("n" => 1)))
        @test S.leaf(open(S.Session, file)) == extra
    end
end

@testset "session file boundaries" begin
    S = JuliaForever.Sessions
    mktempdir() do dir
        file = joinpath(dir, "foreign.jsonl")
        original = "{\"type\":\"event\",\"data\":\"keep\"}\n"
        write(file, original)
        @test open(S.Session, file) == S.Rejected(:invalid_session)
        @test read(file, String) == original
        session = S.Session(file; cwd=dir)
        @test_throws Exception S.record!(session, Dict("role" => "user", "content" => "blocked"))
        @test isempty(S.entries(session))
        @test S.leaf(session) === nothing
        @test read(file, String) == original

        sessionfile = joinpath(dir, "valid.jsonl")
        saved = S.Session(sessionfile; cwd=dir)
        first = S.record!(saved, Dict("role" => "user", "content" => "keep"))
        mv(sessionfile, sessionfile * ".moved")
        mkdir(sessionfile)
        @test_throws Exception S.record!(saved, Dict("role" => "assistant", "content" => "fail"))
        @test S.leaf(saved) == first
        @test length(S.entries(saved)) == 1

        valid = sessionfile * ".moved"
        text = read(valid, String)
        write(valid, chomp(text))
        reopened = open(S.Session, valid)
        @test reopened.flushed && !reopened.terminated
        second = S.record!(reopened, Dict("role" => "assistant", "content" => "reply"))
        @test S.leaf(open(S.Session, valid)) == second
        @test length(readlines(valid)) == 3
        corrupt = joinpath(dir, "corrupt.jsonl")
        write(corrupt, text * "{broken\n")
        @test open(S.Session, corrupt) == S.Rejected(:invalid_session)
        @test read(corrupt, String) == text * "{broken\n"
    end
end
