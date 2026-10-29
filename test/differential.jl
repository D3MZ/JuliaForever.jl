using JSON3

@testset "Pi file tools" begin
    source = ENV["PI_SOURCE"]
    @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    cases = [
        (; tool="write", initial=nothing, args=(; path="nested/a.txt", content="hello 🌱\n")),
        (; tool="write", initial="old", args=(; path="a.txt", content="new")),
        (; tool="read", initial="one\ntwo\nthree\n", args=(; path="a.txt")),
        (; tool="read", initial="one\ntwo\nthree\n", args=(; path="a.txt", offset=2, limit=1)),
        (; tool="read", initial="", args=(; path="a.txt")),
        (; tool="read", initial="one\ntwo", args=(; path="a.txt", offset=10)),
        (; tool="read", initial=repeat("line\n", 2001), args=(; path="a.txt")),
        (; tool="read", initial=repeat("x", 51201), args=(; path="a.txt")),
        (; tool="edit", initial="one\ntwo\nthree\n", args=(; path="a.txt", edits=[(; oldText="two", newText="TWO")])),
        (; tool="edit", initial="a\r\nb\r\nc\r\n", args=(; path="a.txt", edits=[(; oldText="a\nb", newText="A\nB")])),
        (; tool="edit", initial="α 🌱 β", args=(; path="a.txt", edits=[(; oldText="🌱", newText="🌳")])),
        (; tool="edit", initial="a b c", args=(; path="a.txt", edits=[(; oldText="a", newText="A"), (; oldText="c", newText="C")])),
        (; tool="edit", initial="x x", args=(; path="a.txt", edits=[(; oldText="x", newText="y")])),
        (; tool="edit", initial="abcdef", args=(; path="a.txt", edits=[(; oldText="abc", newText="x"), (; oldText="cde", newText="y")])),
        (; tool="edit", initial="x", args=(; path="a.txt", edits=[(; oldText="missing", newText="y")])),
        (; tool="edit", initial="x", args=(; path="a.txt", edits=[(; oldText="x", newText="x")])),
        (; tool="edit", initial="x", args=(; path="a.txt", edits=[(; oldText="", newText="y")])),
        (; tool="edit", initial="\ufeffone\r\ntwo\r\n", args=(; path="a.txt", edits=[(; oldText="two", newText="TWO")])),
        (; tool="edit", initial="one\ntwo\r\nthree", args=(; path="a.txt", edits=[(; oldText="two", newText="TWO")])),
        (; tool="edit", initial="call \"x\"\ncall “x”", args=(; path="a.txt", edits=[(; oldText="call \"x\"", newText="done")])),
    ]
    mktempdir() do dir
        input = joinpath(dir, "cases.json")
        write(input, JSON3.write(cases))
        reference = JSON3.read(read(`node $(joinpath(@__DIR__, "reference.mjs")) $source $input`, String))
        for (index, case) in enumerate(cases)
            mktempdir() do workspace
                file = joinpath(workspace, case.args.path)
                if !isnothing(case.initial)
                    mkpath(dirname(file))
                    write(file, case.initial)
                end
                tools = Dict("read" => Read(workspace), "write" => Write(workspace), "edit" => Edit(workspace))
                result = try
                    execute(tools[case.tool], case.args)
                catch
                    ToolResult("", true)
                end
                @test result.iserror == reference[index].iserror
                if !result.iserror
                    @test result.text == reference[index].text
                end
                @test (isfile(file) ? read(file, String) : nothing) == reference[index].file
            end
        end
    end
end
