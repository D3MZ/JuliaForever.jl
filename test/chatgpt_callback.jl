using HTTP, SHA, Base64, JSON3

const CB = JuliaForever.ChatGPT

function authparams(address)
    captured = Ref("")
    result = CB.launch(address) do value
        captured[] = value
        true
    end
    @test isnothing(result)
    HTTP.queryparams(HTTP.URI(captured[]))
end

function callbackget(pending, query; path="/auth/callback", headers=[])
    base = replace(pending.redirect, "/auth/callback" => path)
    HTTP.get(base * "?" * query, headers; status_exception=false, retry=false)
end
