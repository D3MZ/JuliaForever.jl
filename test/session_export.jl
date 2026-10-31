using Test, JuliaForever, JSON3

struct ExportFixture end
function JuliaForever.complete(::ExportFixture, messages, tools; parameters=Dict())
    JuliaForever.Completion(Dict{String,Any}("role" => "assistant", "content" => "Stored answer & details", "reasoning" => "Check <script>thinking()</script>"), nothing, "stop", JuliaForever.Finished(), nothing)
end

@testset "conversation export browser controls" begin
    browser = get(ENV, "JF_EXPORT_UI_BROWSER", "")
    if !isempty(browser)
        mktempdir() do root
            markdown = "**violet** answer using `notes.txt`. [safe](https://example.test) [unsafe](javascript:alert(1)) ![remote image](https://example.test/a.png)\n\n1. first\n2. second\n\n```julia\nx < 2\n```\n\n```python\ndef answer():\n    return \"<img src=x onerror=globalThis.injected=true>\"\n```\n\n```python\" data-pwned=\"yes\n</script><script>globalThis.injected=true</script>\n```\n\n| name | value |\n| --- | --- |\n| red | 3 |\n\n> quoted text"
            messages = [Dict("role" => "user", "content" => "violet harbor"), Dict("role" => "assistant", "content" => markdown, "reasoning" => "Inspect <img src=x onerror=globalThis.injected=true>", "tool_calls" => [Dict("function" => Dict("name" => "read", "arguments" => "notes"))]), Dict("role" => "tool", "content" => "amber result"), Dict("role" => "user", "content" => "<script>globalThis.injected = true</script>")]
            page = joinpath(root, "conversation.html")
            open(page, "w") do io
                JuliaForever.Logs.conversationhtml(io, messages)
            end
            command = `node $(joinpath(@__DIR__, "session_export_ui.cjs")) $page $browser`
            @test run(pipeline(ignorestatus(command); stdout=stdout, stderr=stderr)).exitcode == 0
        end
    end
end
