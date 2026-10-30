using Test
using JuliaForever

@testset "ChatGPT sign-in CLI" begin
    project = dirname(@__DIR__)
    cmd = `$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project -m JuliaForever --help`
    help = read(cmd, String)
    @test occursin("--login-chatgpt", help)
end

@testset "ChatGPT login persists a selected account" begin
    mktempdir() do dir
        store = CG.Store(dir)
        nonce = Ref("")
        redirects = String[]
        opener = url -> begin
            params = HTTP.queryparams(HTTP.URI(url))
            nonce[] = params["nonce"]
            push!(redirects, params["redirect_uri"])
            target = params["redirect_uri"] * "?state=" * HTTP.escapeuri(params["state"]) * "&code=synthetic-code&client_id=oaiapp_fixture"
            HTTP.get(target; retry=false).status == 200
        end
        post = body -> begin
            claims = identityclaims(; changes=Dict("nonce" => nonce[], "exp" => identitytime + 3600))
            tokens = Dict("access_token" => "synthetic-access", "refresh_token" => "synthetic-refresh", "id_token" => signedidentity(claims), "scope" => identityscope, "token_type" => "Bearer", "expires_in" => 3600)
            CG.TokenReply(200, JSON3.write(tokens))
        end
        output = IOBuffer()
        options = (; output, opener, post, fetcher=url -> JSON3.write(Dict("keys" => identitykeys)), now=() -> identitytime)
        first = JuliaForever.connectchatgpt(store, CG.Register(); options...)
        @test first isa CG.Session
        accounts = CG.accounts(store)
        @test length(accounts) == 1 && only(accounts).client == "oaiapp_fixture"
        @test JuliaForever.choosechatgpt(accounts, IOBuffer(), IOBuffer(), JuliaForever.ResumeChatGPT()) isa CG.Session
        @test JuliaForever.choosechatgpt(accounts, IOBuffer("2\n"), IOBuffer(), JuliaForever.ChooseChatGPT()) isa CG.Register
        @test CG.refresh(store, first.client, first.identity.subject; now=() -> identitytime).access == "synthetic-access"
        text = String(take!(output))
        @test occursin("Continue with ChatGPT", text)
        @test !occursin("synthetic-access", text) && !occursin("synthetic-refresh", text)
        second = JuliaForever.connectchatgpt(store, only(accounts); options...)
        @test second isa CG.Session
        returning_output = String(take!(output))
        @test !occursin("id_token_hint", returning_output) && !occursin(first.id_token, returning_output)
        @test length(redirects) == 2
        @test JuliaForever.modeldata(Dict("models" => [Dict("visibility" => "hidden", "slug" => "hide"), Dict("visibility" => "list", "slug" => "shown")])) == [(; id="shown", name="shown")]
    end
end

@testset "ChatGPT session refresh during a conversation" begin
    mktempdir() do dir
        store = CG.Store(dir)
        identity = CG.Identity("account-fixture", "fixture@example.test")
        expired = CG.Session("oaiapp_fixture", identity, "old-access", "old-refresh", "old-id", identityscope, identitytime - 1)
        CG.save(store, expired)
        refreshes = Ref(0)
        renew = body -> begin
            refreshes[] += 1
            fields = HTTP.queryparams(HTTP.URI("http://127.0.0.1/?" * body))
            @test fields["refresh_token"] == "old-refresh"
            CG.TokenReply(200, JSON3.write((; access_token="new-access", refresh_token="new-refresh", token_type="Bearer", scope=identityscope, expires_in=3600)))
        end
        requests = Channel{Any}(1)
        server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
            put!(requests, HTTP.header(request, "Authorization"))
            output = plantext("ready")
            HTTP.Response(200, ["Content-Type" => "text/event-stream"], plansse((; type="response.output_item.done", output_index=0, item=output)) * plansse((; type="response.completed", response=planresponse([output]))))
        end
        try
            post = (url, headers, body; kwargs...) -> HTTP.post("http://$(HTTP.server_addr(server))/v1/responses", headers, body; kwargs...)
            secrets = JuliaForever.chatgptsecrets(expired)
            model = JuliaForever.ManagedChatGPT(store, expired.client, identity.subject, "fixture-model", secrets; post, refresh=renew, now=() -> identitytime)
            result = JuliaForever.stream(model, [Dict("role" => "user", "content" => "hello")], Dict())
            @test result.done && result.message["content"] == "ready"
            @test take!(requests) == "Bearer new-access"
            @test refreshes[] == 1
            @test "new-access" in secrets && "new-refresh" in secrets
            reopened = CG.load(CG.Store(dir), expired.client, identity.subject)
            @test reopened.access == "new-access" && reopened.refresh == "new-refresh"
        finally
            close(server)
            wait(server)
        end
    end
end

@testset "ChatGPT sign-out revokes the selected session" begin
    mktempdir() do dir
        store = CG.Store(dir)
        session = CG.Session("oaiapp_fixture", CG.Identity("subject", nothing), "access-secret", "refresh-secret", "id-secret", identityscope, identitytime + 100)
        CG.save(store, session)
        calls = []
        request = (method, url, args...; kwargs...) -> begin
            push!(calls, (method, url))
            if method == "GET"
                return HTTP.Response(200, [], JSON3.write((; revocation_endpoint="https://auth.openai.com/revoke")))
            end
            fields = HTTP.queryparams(HTTP.URI("http://127.0.0.1/?" * args[2]))
            @test fields == Dict("token" => "refresh-secret", "token_type_hint" => "refresh_token", "client_id" => "oaiapp_fixture")
            HTTP.Response(200)
        end
        @test CG.signout(store, session; request) isa CG.Revoked
        @test calls == [("GET", "https://auth.openai.com/.well-known/openid-configuration"), ("POST", "https://auth.openai.com/revoke")]
        @test CG.load(store, session.client, session.identity.subject) isa CG.Account
        @test CG.signout(store, session; request) isa CG.Rejected
        other = CG.Session("other-client", CG.Identity("other-subject", nothing), "other-access", "other-refresh", "other-id", identityscope, identitytime + 100)
        CG.save(store, other)
        malicious = (method, url, args...; kwargs...) -> HTTP.Response(200, [], JSON3.write((; revocation_endpoint="https://evil.example/revoke")))
        @test CG.signout(store, other; request=malicious) isa CG.RevocationUnconfirmed
        @test CG.load(store, other.client, other.identity.subject) isa CG.Account
    end
end

@testset "ChatGPT terminal startup" begin
    if Sys.isunix()
        output = read(`python3 $(joinpath(@__DIR__, "chatgpt_pty.py")) $(Base.julia_cmd().exec[1])`, String)
        @test occursin("startup and cancellation passed", output)
    end
end
