using HTTP, SHA, Base64

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

@testset "ChatGPT authorization callback" begin
    first = CB.Pending(CB.Register(), "urn:uuid:host-fixture")
    second = CB.Pending(CB.Register(), "urn:uuid:host-fixture")
    try
        params = authparams(CB.authorize(first))
        other = authparams(CB.authorize(second))
        @test params["client_id"] == "dynamic_agent_client"
        @test params["agent_name_hint"] == "Julia Forever"
        @test params["ext_agent_host_id"] == "urn:uuid:host-fixture"
        @test params["redirect_uri"] == first.redirect
        @test occursin(r"^http://127\.0\.0\.1:[0-9]+/auth/callback$", first.redirect)
        @test params["scope"] == "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
        @test params["resource"] == "https://api.openai.com/v1"
        @test params["response_type"] == "code"
        @test params["code_challenge_method"] == "S256"
        @test params["code_challenge"] == JuliaForever.base64url(sha256(first.verifier))
        @test params["state"] != other["state"] && params["nonce"] != other["nonce"] && first.verifier != second.verifier
        @test !occursin(first.verifier, sprint(show, first))
        @test !occursin(first.state, sprint(show, first))
        @test callbackget(first, "state=wrong&code=a&client_id=oaiapp_fixture").status == 400
        @test callbackget(first, "state=$(first.state)&code=a&client_id=oaiapp_fixture"; headers=["Host" => "localhost"]).status == 400
        @test callbackget(first, "state=$(first.state)&state=$(first.state)&code=a&client_id=oaiapp_fixture").status == 400
        @test callbackget(first, "state=$(first.state)&code=a&code=b&client_id=oaiapp_fixture").status == 400
        @test callbackget(first, "state=$(first.state)&code=a").status == 400
        @test callbackget(first, "state=$(first.state)&code=a&client_id=dynamic_agent_client").status == 400
        @test callbackget(first, "state=$(first.state)&code=a&client_id=oaiapp_fixture&error=access_denied").status == 400
        @test callbackget(first, "state=$(first.state)&code=a&client_id=oaiapp_fixture"; path="/callback").status == 404
        response = callbackget(first, "state=$(first.state)&code=synthetic%2Bcode&client_id=oaiapp_fixture")
        @test response.status == 200
        @test HTTP.header(response, "Cache-Control") == "no-store"
        @test !occursin("synthetic", String(response.body))
        result = wait(first; timeout=1)
        @test result.code == "synthetic+code"
        @test result.client == "oaiapp_fixture"
        @test !occursin(result.code, sprint(show, result))
        @test callbackget(first, "state=$(first.state)&code=second&client_id=oaiapp_fixture").status == 409
    finally
        close(first)
        close(second)
    end
end

@testset "ChatGPT reauthorization and denial" begin
    registration = CB.Returning("oaiapp_saved", "account-fixture"; id_token="synthetic-id-token", email="fixture@example.test")
    pending = CB.Pending(registration, "urn:uuid:host-fixture")
    try
        params = authparams(CB.authorize(pending))
        @test params["client_id"] == "oaiapp_saved"
        @test !haskey(params, "agent_name_hint")
        @test params["id_token_hint"] == "synthetic-id-token"
        @test params["login_hint"] == "fixture@example.test"
        @test !occursin("synthetic-id-token", sprint(show, registration))
        address = CB.authorize(pending)
        @test !occursin("synthetic-id-token", sprint(show, address))
        @test !occursin("synthetic-id-token", sprint(show, MIME("text/plain"), address))
        failed = CB.launch(_ -> false, address)
        @test failed isa CB.Rejected && failed.reason == :browser
        @test !occursin("synthetic-id-token", sprint(show, failed))
        @test !haskey(params, "prompt")
        @test callbackget(pending, "state=$(pending.state)&code=a&client_id=oaiapp_other").status == 400
        @test callbackget(pending, "state=$(pending.state)&code=a&client_id=oaiapp_saved&client_id=oaiapp_saved").status == 400
        @test callbackget(pending, "state=$(pending.state)&code=a").status == 200
        @test wait(pending; timeout=1).client == "oaiapp_saved"
    finally
        close(pending)
    end
    denied = CB.Pending(CB.Register(), "urn:uuid:host-fixture")
    try
        @test callbackget(denied, "state=wrong&error=access_denied").status == 400
        @test callbackget(denied, "state=$(denied.state)&error=access_denied").status == 200
        @test wait(denied; timeout=1) isa CB.Denied
    finally
        close(denied)
    end
end

@testset "ChatGPT callback timeout and concurrency" begin
    pending = CB.Pending(CB.Register(), "urn:uuid:host-fixture")
    try
        @test isnothing(wait(pending; timeout=0.02))
        @test callbackget(pending, "state=$(pending.state)&code=late&client_id=oaiapp_fixture").status == 409
    finally
        close(pending)
    end
    pending = CB.Pending(CB.Register(), "urn:uuid:host-fixture")
    try
        query = "state=$(pending.state)&code=a&client_id=oaiapp_fixture"
        a = Threads.@spawn callbackget(pending, query).status
        b = Threads.@spawn callbackget(pending, query).status
        @test sort([fetch(a), fetch(b)]) == [200, 409]
        @test wait(pending; timeout=1).code == "a"
    finally
        close(pending)
    end
end

@testset "ChatGPT explicit reconsent" begin
    pending = CB.Pending(CB.Reconsent(CB.Returning("oaiapp_saved", "account-fixture")), "urn:uuid:host-fixture")
    try
        params = authparams(CB.authorize(pending))
        @test params["client_id"] == "oaiapp_saved"
        @test params["prompt"] == "consent"
        @test !haskey(params, "force_reconsent")
        @test !haskey(params, "agent_name_hint")
    finally
        close(pending)
    end
end
