using Test
include("branch_scan.jl")

@testset "branch inventory" begin
    @test parse(Int, "123") == 123
    source = """
    function example(xs, flag)
        if flag && !isempty(xs)
            flag ? 1 : 2
        elseif flag || isempty(xs)
            while flag
                break
            end
        end
        for x in xs
            identity(x)
        end
        [x for x in xs if x isa Int]
        filter(x -> x isa Int, xs)
        Base.any(isnothing, xs)
        ifelse(flag, 1, 2)
        try
            first(xs)
        catch
            nothing
        end
    end
    """
    branches = branchpoints(source)
    @test sort([branch.kind for branch in branches]) == sort(["if", "elseif", "?", "&&", "||", "while", "for", "filter", "predicate", "predicate", "ifelse", "catch"])
    @test only(branch for branch in branches if branch.kind == "filter").condition == "x isa Int"
    @test only(branch for branch in branches if branch.kind == "for").condition == "x in xs"
    @test Set(branch.condition for branch in branches if branch.kind == "predicate") == Set(["x -> x isa Int", "isnothing"])
    @test only(branch for branch in branches if branch.kind == "ifelse").condition == "flag"
    @test only(branch for branch in branches if branch.kind == "if").line == 2
    @test isempty(branchpoints(":(if flag; one; else; two; end)"))
    @test isempty(branchpoints("count + 1"))
    @test only(branchpoints("count(predicate, xs)")).condition == "predicate"
    @test isempty(branchpoints("filter * value"))
    @test branchentry(only(branchpoints("flag ? 1 : 2"))) == branchentry(only(branchpoints("\n\nflag ? 1 : 2")))
    @test branchdifference(["a", "a", "b"], ["a", "b"]) == ["a"]
    mktempdir() do root
        path = joinpath(root, "example.jl")
        write(path, "f(flag) = flag ? 1 : 2")
        initial = branchbaseline(root)
        write(path, "f(flag) = flag ? 1 : 2\ng(flag) = flag ? 1 : 2")
        @test length(branchbaseline(root)) == length(initial) + 1
    end
end

@testset "branch ratchet" begin
    actual = branchbaseline(joinpath(@__DIR__, "..", "src"))
    expected = readlines(joinpath(@__DIR__, "branch-baseline.txt"))
    @test isempty(branchdifference(actual, expected))
    @test isempty(branchdifference(expected, actual))
end
