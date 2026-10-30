module FileCompletionTests

using Test, JuliaForever, JSON3

@testset "file completion matches Pi" begin
    C = JuliaForever.LiveTerminal.Completion
    mktempdir() do temporary
        root = realpath(temporary)
        for dir in (".git", "src/nested", "my docs", "文档", ".hidden")
            mkpath(joinpath(root, dir))
        end
        for path in ("README.md", "src/main.jl", "src/map.jl", "src/nested/main.md", "my docs/guide.md", "文档/说明.md", ".hidden/hidden.txt", "secret.txt", "ignored.txt", "fd-secret.txt")
            write(joinpath(root, path), "fixture")
        end
        write(joinpath(root, ".gitignore"), "secret.txt\n")
        write(joinpath(root, ".ignore"), "ignored.txt\n")
        write(joinpath(root, ".fdignore"), "fd-secret.txt\n")
        Sys.isunix() && symlink("src", joinpath(root, "link-src"))
        cases = [(; before="open src/ma", after=" and more", force=true), (; before="open ./src/", after="", force=true), (; before="open \"my d", after="\" suffix", force=true), (; before="查看，文档/说", after=" 后文", force=true), (; before="open link-s", after="", force=true), (; before="open ~/src/ma", after="", force=true), (; before="read @main", after="", force=false), (; before="read (@src/ma", after=")", force=false), (; before="read @\"my docs/gui", after="\" next", force=false), (; before="read @hidden", after="", force=false), (; before="read @secret", after="", force=false), (; before="read @ignored", after="", force=false), (; before="read @fd-secret", after="", force=false), (; before="mail user@main", after="", force=false)]
        options = [C.files(case.before, root; force=case.force, home=root) for case in cases]
        actual = map(zip(cases, options)) do (case, result)
            result === nothing && return nothing
            text, cursor = C.apply(case.before, case.after, result.prefix, first(result.items))
            preceding = String(Vector{UInt8}(codeunits(text)[1:cursor]))
            (; prefix=result.prefix, items=[(; value=item.value, label=item.label, description=item.description) for item in result.items], text, cursor=length(transcode(UInt16, preceding)))
        end
        fd = get(ENV, "PI_FD", something(Sys.which("fd"), ""))
        if haskey(ENV, "PI_SOURCE")
            source = ENV["PI_SOURCE"]
            @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
            indices = isempty(fd) ? findall(case -> case.force, cases) : eachindex(cases)
            mktemp() do path, io
                JSON3.write(io, (; cwd=root, fd, cases=cases[indices]))
                flush(io)
                cmd = addenv(`node $(joinpath(@__DIR__, "file_completion_pi.mjs")) $source $path`, "HOME" => root, "USERPROFILE" => root, "PI_CODING_AGENT_DIR" => joinpath(root, "agent"))
                @test JSON3.write(actual[indices]) == JSON3.write(JSON3.read(read(cmd, String)))
            end
        end
        @test actual[7] !== nothing && any(item.value == "@src/main.jl" for item in actual[7].items)
        @test all(isnothing, actual[11:14])
        @test C.files("read @main", root; active=() -> C.Stopped()) === nothing
        if Sys.isunix()
            @test any(item.value == "@link-src/main.jl" for item in actual[7].items)
            symlink("../..", joinpath(root, "src", "nested", "cycle"))
            @test C.files("read @cycle", root) !== nothing
        end
    end
end

end
