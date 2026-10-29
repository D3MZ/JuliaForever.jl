using Aqua, JET

function prohibited(expression)
    expression isa Expr || return false
    if expression.head == :call
        callee = first(expression.args)
        callee in (:throw, :error) && return true
        callee isa Expr && callee.head == :. && last(callee.args) in (QuoteNode(:throw), QuoteNode(:error)) && return true
    end
    expression.head == :macrocall && first(expression.args) == Symbol("@assert") && return true
    any(prohibited, expression.args)
end

@testset "quality" begin
    @test prohibited(Meta.parseall("throw(ArgumentError())"))
    @test prohibited(Meta.parseall("Base.error(\"bad\")"))
    @test prohibited(Meta.parseall("@assert x"))
    @test !prohibited(Meta.parseall("f(x) = x + 1"))
    for file in readdir(joinpath(@__DIR__, "..", "src"); join=true)
        endswith(file, ".jl") && @test !prohibited(Meta.parseall(read(file, String)))
    end
    Aqua.test_all(JuliaForever)
    JET.@test_opt JuliaForever.name(Read(pwd()))
    JET.@test_call target_modules=(JuliaForever,) execute(Write(pwd()), (; path="a.txt", content="hello"))
    JET.@test_call target_modules=(JuliaForever,) execute(Read(pwd()), (; path="a.txt", offset=1, limit=2))
    JET.@test_call target_modules=(JuliaForever,) execute(Edit(pwd()), (; path="a.txt", edits=[(; oldText="a", newText="b")]))
end
