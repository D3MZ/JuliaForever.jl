@testset "Pi shell and directory tools" begin
    @test readchomp(`git -C $(ENV["PI_SOURCE"]) rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    cases = [
        (; tool="ls", args=(;)),
        (; tool="ls", args=(; path="alpha")),
        (; tool="ls", args=(; path="missing")),
        (; tool="ls", args=(; path="beta.txt")),
        (; tool="ls", args=(; limit=2)),
    ]
    if !Sys.iswindows()
        append!(cases, [
            (; tool="bash", args=(; command="printf 'hello 🌱'")),
            (; tool="bash", args=(; command="printf warning >&2")),
            (; tool="bash", args=(; command="true")),
            (; tool="bash", args=(; command="printf fail; exit 7")),
            (; tool="bash", args=(; command="printf before; sleep 1", timeout=0.1)),
            (; tool="bash", args=(; command="printf '%051201d' 0")),
            (; tool="bash", args=(; command="printf '%051200d\\n' 0")),
            (; tool="bash", args=(; command="printf '%050000d\\n%02000d\\n' 0 0")),
            (; tool="bash", args=(; command="for ((i=1;i<=2001;i++)); do echo \$i; done")),
            (; tool="bash", args=(; command="for ((i=1;i<=13000;i++)); do printf '🌱'; done")),
        ])
    else
        append!(cases, [
            (; tool="powershell", args=(; command="Write-Output hello")),
            (; tool="powershell", args=(; command="exit 7")),
        ])
    end
    mktempdir() do dir
        input = joinpath(dir, "cases.json")
        write(input, JSON3.write(cases))
        reference = JSON3.read(read(`node $(joinpath(@__DIR__, "system_reference.mjs")) $(ENV["PI_SOURCE"]) $input`, String))
        for (index, case) in enumerate(cases)
            mktempdir() do workspace
                mkdir(joinpath(workspace, "alpha"))
                write(joinpath(workspace, ".hidden"), "h")
                write(joinpath(workspace, "beta.txt"), "b")
                tools = Dict("bash" => Bash(workspace), "powershell" => PowerShell(workspace), "ls" => Ls(workspace))
                result = execute(tools[case.tool], case.args)
                @test result.iserror == reference[index].iserror
                output = match(r"Full output: ([^\]]+)\]$", result.text)
                full = isnothing(output) ? nothing : read(output.captures[1], String)
                text = isnothing(output) ? result.text : replace(result.text, output.captures[1] => "<output>")
                !isnothing(output) && rm(output.captures[1]; force=true)
                @test full == reference[index].full
                @test replace(text, workspace => "<cwd>") == reference[index].text
            end
        end
    end
end

include("system_cancel_differential.jl")
