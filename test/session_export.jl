using Test, JuliaForever, JSON3

struct ExportFixture end
function JuliaForever.complete(::ExportFixture, messages, tools; parameters=Dict())
    JuliaForever.Completion(Dict{String,Any}("role" => "assistant", "content" => "Stored answer & details"), nothing, "stop", JuliaForever.Finished(), nothing)
end

@testset "export saved conversation" begin
    mktempdir() do root
        H = JuliaForever.History
        path = joinpath(root, "conversation.sqlite")
        store = open(H.SQLite, path)
        agent = Agent(ExportFixture(), JuliaForever.Tool[]; history=H.Tree(store))
        @test respond!(agent, "Read <script>alert(1)</script>") == "Stored answer & details"
        close(store)
        html, json = joinpath(root, "conversation.html"), joinpath(root, "conversation.json")
        julia = Base.julia_cmd()
        project = dirname(@__DIR__)
        for output in (html, json)
            cmd = `$julia --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --export $path $output`
            @test success(pipeline(cmd; stdout=devnull, stderr=devnull))
        end
        missing = joinpath(root, "missing.sqlite")
        refused = `$julia --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --export $missing $(joinpath(root, "missing.html"))`
        @test !success(pipeline(refused; stdout=devnull, stderr=devnull))
        @test !ispath(missing)
        before = read(path)
        overwrite = `$julia --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --export $path $path`
        @test !success(pipeline(overwrite; stdout=devnull, stderr=devnull))
        @test read(path) == before
        existing = joinpath(root, "existing.html")
        write(existing, "preserve")
        refusal = `$julia --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --export $path $existing`
        @test !success(pipeline(refusal; stdout=devnull, stderr=devnull))
        @test read(existing, String) == "preserve"
        empty = joinpath(root, "empty.sqlite")
        close(open(H.SQLite, empty))
        emptybefore = read(empty)
        emptycmd = `$julia --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --export $empty $(joinpath(root, "empty.html"))`
        @test !success(pipeline(emptycmd; stdout=devnull, stderr=devnull))
        @test read(empty) == emptybefore
        if isfile(html) && isfile(json)
            page = read(html, String)
            messages = JSON3.read(read(json, String))
            @test occursin("Stored answer &amp; details", page)
            @test occursin("&lt;script&gt;alert(1)&lt;/script&gt;", page)
            @test !occursin("<script>alert(1)</script>", page)
            @test [row.role for row in messages] == ["user", "assistant"]
            @test messages[1].content == "Read <script>alert(1)</script>"
            @test messages[2].content == "Stored answer & details"
        end
    end
end

@testset "conversation export escapes tools and embeds images" begin
    io = IOBuffer()
    messages = [Dict("role" => "assistant", "content" => "hi", "tool_calls" => [Dict("function" => Dict("name" => "read <file>", "arguments" => "<script>x</script>"))]), Dict("role" => "user", "content" => "image", "images" => [Dict("mime" => "image/png", "data" => "aGVsbG8=")])]
    JuliaForever.Logs.conversationhtml(io, messages)
    html = String(take!(io))
    @test occursin("read &lt;file&gt;", html)
    @test occursin("&lt;script&gt;x&lt;/script&gt;", html)
    @test occursin("data:image/png;base64,aGVsbG8=", html)
end

@testset "conversation export browser controls" begin
    browser = get(ENV, "JF_EXPORT_UI_BROWSER", "")
    if !isempty(browser)
        mktempdir() do root
            messages = [Dict("role" => "user", "content" => "violet harbor"), Dict("role" => "assistant", "content" => "violet answer", "tool_calls" => [Dict("function" => Dict("name" => "read", "arguments" => "notes"))]), Dict("role" => "tool", "content" => "amber result"), Dict("role" => "user", "content" => "<script>globalThis.injected = true</script>")]
            page = joinpath(root, "conversation.html")
            open(page, "w") do io
                JuliaForever.Logs.conversationhtml(io, messages)
            end
            command = `node $(joinpath(@__DIR__, "session_export_ui.cjs")) $page $browser`
            @test run(pipeline(ignorestatus(command); stdout=stdout, stderr=stderr)).exitcode == 0
        end
    end
end
