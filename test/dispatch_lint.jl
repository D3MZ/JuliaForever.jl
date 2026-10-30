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
    @test length(dispatchchecks(Meta.parse("f(x) = typeof(x) === String"))) == 1
    @test length(dispatchchecks(Meta.parse("f(x) = Base.typeof(x) != Int"))) == 1
    @test isempty(dispatchchecks(Meta.parse("f(x) = typeof(x)")))
    predicate = Meta.parseall("selected(::Nothing) = false\nselected(::String) = true\nf(x) = selected(x) ? 1 : 0")
    @test length(dispatchchecks(predicate)) == 1
    @test length(dispatchchecks(Meta.parseall("function selected(::Nothing); return false; end\nf(x) = selected(x) ? 1 : 0"))) == 1
    @test isempty(dispatchchecks(Meta.parseall("selected(x) = x > 0\nf(x) = selected(x) ? 1 : 0")))
    @test length(dispatchchecks(Meta.parse("f(flag) = handle(Val(flag))"))) == 1
    @test length(dispatchchecks(Meta.parse("f(x) = handle(Val(x == 0))"))) == 1
    @test isempty(dispatchchecks(Meta.parse("f() = handle(Val(1))")))
    @test length(dispatchchecks(Meta.parse("f(flag) = handle(Val{flag}())"))) == 1
    @test length(dispatchchecks(Meta.parse("f(flag) = handle(Base.Val{flag}())"))) == 1
    @test isempty(dispatchchecks(Meta.parse("f() = handle(Val{1}())")))
    @test length(dispatchchecks(Meta.parse("f(value) = value == \"stop\""))) == 1
    @test length(dispatchchecks(Meta.parse("f(selected) = selected == \"future-provider\" ? 1 : 0"))) == 1
    @test length(dispatchchecks(Meta.parse("f(event) = event.status == \"custom\""))) == 1
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
    end

    actual = dispatchbaseline(joinpath(@__DIR__, "..", "src"))
    expected = readlines(joinpath(@__DIR__, "dispatch-baseline.txt"))
    @test isempty(dispatchdifference(actual, expected))
    @test isempty(dispatchdifference(expected, actual))
end
