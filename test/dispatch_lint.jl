using Test
include("dispatch_checks.jl")

@testset "dispatch lint" begin
    @test length(dispatchchecks(Meta.parse("f(result) = result.iserror ? 1 : 0"))) == 1
    @test length(dispatchchecks(Meta.parse("f(iserror) = if iserror; 1; end"))) == 1
    @test length(dispatchchecks(Meta.parse("f(agent, truncated) = if cancelled(agent); 1; elseif truncated; 2; end"))) == 2
    @test length(dispatchchecks(Meta.parse("f(executor, context) = if !isnothing(executor) || !isnothing(context); 1; end"))) == 2
    @test length(dispatchchecks(Meta.parse("f(x) = x isa Int && x > 0"))) == 1
    @test length(dispatchchecks(Meta.parse("f(x) = ifelse(x === nothing, 1, 2)"))) == 1
    @test length(dispatchchecks(Meta.parse("f(x) = Base.ifelse(x isa Int, 1, 2)"))) == 1
    @test length(dispatchchecks(Meta.parse("f(x) = if getfield(x, :iserror); 1; end"))) == 1
    @test length(dispatchchecks(Meta.parse("f(x) = if x.failed == false; 1; end"))) == 1
    @test length(dispatchchecks(Meta.parse("f(x) = if get(x, :iserror, false); 1; end"))) == 1
    @test length(dispatchchecks(Meta.parse("f(x) = if x[:enabled]; 1; end"))) == 1
    @test length(dispatchchecks(Meta.parse("f(x) = if Base.get(x, :enabled, false); 1; end"))) == 1
    @test length(dispatchchecks(Meta.parse("f(xs) = [x for x in xs if x isa Int]"))) == 1
    @test length(dispatchchecks(Meta.parse("f(xs) = filter(x -> x isa Int, xs)"))) == 1
    @test length(dispatchchecks(Meta.parse("f(xs) = Base.filter(x -> x isa Int, xs)"))) == 1
    @test length(dispatchchecks(Meta.parse("f(xs) = filter!(x -> x isa Int, xs)"))) == 1
    @test length(dispatchchecks(Meta.parse("f(xs) = findnext(x -> isnothing(x), xs, 1)"))) == 1
    @test length(dispatchchecks(Meta.parse("f(xs) = filter(isa(Int), xs)"))) == 1
    @test length(dispatchchecks(Meta.parse("f(xs) = filter(isnothing, xs)"))) == 1
    @test length(dispatchchecks(Meta.parse("f(xs) = filter(!isnothing, xs)"))) == 1
    @test length(dispatchchecks(Meta.parse("f(xs) = filter(==(nothing), xs)"))) == 1
    @test length(dispatchchecks(Meta.parse("f(xs) = any(x -> isnothing(x), xs)"))) == 1
    @test length(dispatchchecks(Meta.parse("f(x) = ismissing(x) ? 0 : x"))) == 1
    @test length(dispatchchecks(Meta.parse("f(x) = x === missing ? 0 : x"))) == 1
    @test length(dispatchchecks(Meta.parse("f(event) = event.type == :start ? 1 : 0"))) == 1
    @test length(dispatchchecks(Meta.parse("f(event) = event[\"kind\"] == \"done\" ? 1 : 0"))) == 1
    @test length(dispatchchecks(Meta.parse("f(event) = Base.get(event, \"kind\", \"\") == \"done\" ? 1 : 0"))) == 1
    @test length(dispatchchecks(Meta.parse("f(mode) = mode === :parallel ? 1 : 0"))) == 1
    @test length(dispatchchecks(Meta.parse("f(state) = state in (:queued, :running) ? 1 : 0"))) == 1
    @test length(dispatchchecks(Meta.parse("f(value) = value in (:queued, :running) ? 1 : 0"))) == 1
    @test length(dispatchchecks(Meta.parse("f(kind) = kind == \"tool\" ? 1 : 0"))) == 1
    @test length(dispatchchecks(Meta.parse("f(value) = value == \"stop\" ? 1 : 0"))) == 1
    @test length(dispatchchecks(Meta.parse("f(value) = value in (\"queued\", \"running\") ? 1 : 0"))) == 1
    @test length(dispatchchecks(Meta.parse("f(x) = isnothing(x)"))) == 1
    @test length(dispatchchecks(Meta.parse("f(x) = x isa Int"))) == 1
    @test length(dispatchchecks(Meta.parse("f(x) = x !== nothing"))) == 1
    @test length(dispatchchecks(Meta.parse("f(x) = x === false"))) == 1
    @test length(dispatchchecks(Meta.parse("f(matches, exclude) = matches != exclude"))) == 1
    @test length(dispatchchecks(Meta.parse("f(matches, done) = matches == done"))) == 1
    @test isempty(dispatchchecks(Meta.parse("f(left, right) = left == right")))
    @test length(dispatchchecks(Meta.parse("f(x) = typeof(x) === String"))) == 1
    @test length(dispatchchecks(Meta.parse("f(x) = Base.typeof(x) != Int"))) == 1
    @test isempty(dispatchchecks(Meta.parse("f(x) = typeof(x)")))
    predicate = Meta.parseall("selected(::Nothing) = false\nselected(::String) = true\nf(x) = selected(x) ? 1 : 0")
    @test length(dispatchchecks(predicate)) == 1
    @test length(dispatchchecks(Meta.parseall("selected(::Nothing) = false\nselected(::String) = true\nf(xs) = filter(selected, xs)"))) == 1
    @test length(dispatchchecks(Meta.parseall("selected(::Nothing) = false\nselected(::String) = true\nf(xs) = filter(!selected, xs)"))) == 1
    @test length(dispatchchecks(Meta.parseall("selected(::Nothing) = false\nselected(::String) = true\nf(xs) = findall(selected, xs)"))) == 1
    @test length(dispatchchecks(Meta.parseall("function selected(::Nothing); return false; end\nf(x) = selected(x) ? 1 : 0"))) == 1
    @test length(dispatchchecks(Meta.parseall("selected(x::String) = if isempty(x); true; else; return false; end\nf(x) = selected(x) ? 1 : 0"))) == 1
    @test length(dispatchchecks(Meta.parseall("selected(x::String) = if isempty(x); true; else; return false; end\nf(xs) = filter(selected, xs)"))) == 1
    @test isempty(dispatchchecks(Meta.parseall("selected(x) = x > 0\nf(x) = selected(x) ? 1 : 0")))
    @test length(dispatchchecks(Meta.parseall("flag(::Nothing) = false\nflag(::String) = true\nf(x) = Completion(Dict(), nothing, nothing, flag(x), nothing)"))) == 1
    @test length(dispatchchecks(Meta.parseall("forced(::Nothing) = false\nforced(::String) = true\nf(x) = g(; force=forced(x))"))) == 1
    @test length(dispatchchecks(Meta.parse("f(x) = ToolReply(x.text, x.iserror)"))) == 1
    @test length(dispatchchecks(Meta.parse("f() = ToolResult(\"cancelled\", true)"))) == 1
    @test length(dispatchchecks(Meta.parse("f(image) = ToolResult(\"ok\", false, image)"))) == 1
    @test length(dispatchchecks(Meta.parse("f() = ToolReply(\"failed\", true)"))) == 1
    @test length(dispatchchecks(Meta.parse("f() = Completion(Dict(), nothing, nothing, false, nothing)"))) == 1
    @test length(dispatchchecks(Meta.parse("f(fields...) = CodeResult(true, fields...)"))) == 1
    @test length(dispatchchecks(Meta.parse("f(reply) = Completion(Dict(), nothing, nothing, reply.done, nothing)"))) == 1
    @test length(dispatchchecks(Meta.parse("f(reply) = CodeResult(reply.ok, reply)"))) == 1
    @test length(dispatchchecks(Meta.parse("f(text, failed) = ToolResult(text, failed)"))) == 1
    @test length(dispatchchecks(Meta.parse("f(text, iserror) = ToolReply(text, iserror)"))) == 1
    @test length(dispatchchecks(Meta.parse("f(done) = Completion(Dict(), nothing, nothing, done, nothing)"))) == 1
    @test length(dispatchchecks(Meta.parse("f(ok, fields...) = CodeResult(ok, fields...)"))) == 1
    @test isempty(dispatchchecks(Meta.parse("CodeResult(ok, fields...) = CodeSuccess(fields...)")))
    @test isempty(dispatchchecks(Meta.parse("Completion(message, usage, finish, done, error) = Completion(message, usage, finish, Finished(), error)")))
    @test length(dispatchchecks(Meta.parse("ToolResult(x::Val{true}, flag) = x"))) == 1
    @test isempty(dispatchchecks(Meta.parse("f() = Completion(Dict(\"enabled\" => true), nothing, nothing, Finished(), nothing)")))
    @test length(dispatchchecks(Meta.parse("f(flag) = handle(Val(flag))"))) == 1
    @test length(dispatchchecks(Meta.parse("f() = handle(Val(true))"))) == 1
    @test length(dispatchchecks(Meta.parse("f() = handle(Val(false))"))) == 1
    @test length(dispatchchecks(Meta.parse("f(::Val{true}) = 1"))) == 1
    @test length(dispatchchecks(Meta.parse("f(::Val{false}) = 1"))) == 1
    @test length(dispatchchecks(Meta.parse("f(x) = handle(Val(x == 0))"))) == 1
    @test isempty(dispatchchecks(Meta.parse("f() = handle(Val(1))")))
    @test length(dispatchchecks(Meta.parse("f(flag) = handle(Val{flag}())"))) == 1
    @test length(dispatchchecks(Meta.parse("f(flag) = handle(Base.Val{flag}())"))) == 1
    @test isempty(dispatchchecks(Meta.parse("f() = handle(Val{1}())")))
    @test length(dispatchchecks(Meta.parse("f(value) = value == \"stop\""))) == 1
    @test length(dispatchchecks(Meta.parse("f(selected) = selected == \"future-provider\" ? 1 : 0"))) == 1
    @test length(dispatchchecks(Meta.parse("f(label) = label == \"results\" ? 1 : 0"))) == 1
    @test length(dispatchchecks(Meta.parse("f(effort) = effort == \"none\" ? 1 : 0"))) == 1
    @test length(dispatchchecks(Meta.parse("f(effort) = effort == \"none\""))) == 1
    @test length(dispatchchecks(Meta.parse("f(event) = event.status == \"custom\""))) == 1
    @test length(dispatchchecks(Meta.parse("f(failure) = failure.code in (\"invalid_grant\", \"token_expired\")"))) == 1
    @test length(dispatchchecks(Meta.parse("f(data) = get(data, \"code\", nothing) == -32601"))) == 1
    @test length(dispatchchecks(Meta.parse("f(args) = first(args) == \"--codemode\" ? 1 : 0"))) == 1
    @test length(dispatchchecks(Meta.parse("f(option) = option in (\"--tools\", \"-t\") ? 1 : 0"))) == 1
    @test length(dispatchchecks(Meta.parse("f(option) = option == \"-h\" ? 1 : 0"))) == 1
    @test isempty(dispatchchecks(Meta.parse("f(args) = first(args) == \"--\"")))
    @test isempty(dispatchchecks(Meta.parse("f(value) = value == \"-1\"")))
    @test dispatchchecks(Meta.parseall("f() = if timedwait(() -> true, 1) == :ok; 1; end")) == dispatchchecks(Meta.parseall("\n\nf() = if timedwait(() -> true, 1) == :ok; 1; end"))
    @test isempty(dispatchchecks(Meta.parse("f(x::Int) = x > 0 ? 1 : 0")))
    @test isempty(dispatchchecks(Meta.parse("f(x) = x == \"hello\"")))
    @test isempty(dispatchchecks(Meta.parse("f(xs) = filter(x -> x > 0, xs)")))
    @test isempty(dispatchchecks(Meta.parse("f(x) = (; iserror=x.iserror)")))
    @test dispatchdifference(["a", "a", "b"], ["a", "b"]) == ["a"]
    mktempdir() do root
        mkpath(joinpath(root, "nested"))
        write(joinpath(root, "nested", "example.jl"), "f(x) = x.iserror ? 1 : 0")
        @test only(dispatchbaseline(root)) == joinpath("nested", "example.jl") * "\t" * only(dispatchchecks(Meta.parse("f(x) = x.iserror ? 1 : 0")))
    end
    mktempdir() do root
        write(joinpath(root, "predicate.jl"), "selected(::Nothing) = false\nselected(::String) = true")
        write(joinpath(root, "consumer.jl"), "f(x) = selected(x) ? 1 : 0")
        @test only(dispatchbaseline(root)) == "consumer.jl\t:(selected(x))"
        write(joinpath(root, "consumer.jl"), "f(xs) = filter(selected, xs)")
        @test only(dispatchbaseline(root)) == "consumer.jl\t:selected"
    end

    # Julia's REPL.prompt! returns `ok` and `suspend` booleans at the terminal boundary.
    actual = dispatchbaseline(joinpath(@__DIR__, "..", "src"))
    expected = readlines(joinpath(@__DIR__, "dispatch-baseline.txt"))
    @test isempty(dispatchdifference(actual, expected))
    @test isempty(dispatchdifference(expected, actual))
end
