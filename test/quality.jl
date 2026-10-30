using Aqua, JET

function prohibited(expression)
    expression isa Expr || return false
    if expression.head == :call
        callee = first(expression.args)
        callee in (:throw, :error, :rethrow) && return true
        callee isa Expr && callee.head == :. && last(callee.args) in (QuoteNode(:throw), QuoteNode(:error), QuoteNode(:rethrow)) && return true
    end
    expression.head == :macrocall && first(expression.args) == Symbol("@assert") && return true
    any(prohibited, expression.args)
end

@testset "quality" begin
    @test prohibited(Meta.parseall("throw(ArgumentError())"))
    @test prohibited(Meta.parseall("rethrow()"))
    @test prohibited(Meta.parseall("Base.error(\"bad\")"))
    @test prohibited(Meta.parseall("@assert x"))
    @test !prohibited(Meta.parseall("f(x) = x + 1"))
    for file in readdir(joinpath(@__DIR__, "..", "src"); join=true)
        endswith(file, ".jl") && @test !prohibited(Meta.parseall(read(file, String)))
    end
    Aqua.test_all(JuliaForever)
    JET.@test_opt JuliaForever.name(Read(pwd()))
    JET.@test_opt JuliaForever.content(ToolSuccess("ok"))
    JET.@test_opt JuliaForever.content(ToolFailure("bad"))
    JET.@test_opt JuliaForever.Kernel.same(1, 1)
    JET.@test_opt JuliaForever.Durable.validate(JuliaForever.Durable.Task(1, 1, nothing), JuliaForever.Durable.Task(1, 1, nothing))
    JET.@test_call target_modules=(JuliaForever,) execute(Write(pwd()), (; path="a.txt", content="hello"))
    JET.@test_call target_modules=(JuliaForever,) execute(Read(pwd()), (; path="a.txt", offset=1, limit=2))
    JET.@test_call target_modules=(JuliaForever,) execute(Edit(pwd()), (; path="a.txt", edits=[(; oldText="a", newText="b")]))
    JET.@test_call target_modules=(JuliaForever,) JuliaForever.providererror(:openai_compatible, Dict{String, Any}("type" => "server_error", "code" => 503))
    JET.@test_call target_modules=(JuliaForever,) JuliaForever.providererror(:openai_compatible, "content_filter")
end
