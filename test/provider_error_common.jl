using Test, JuliaForever, HTTP, JSON3, Serialization, Distributed

provider_error_sse(data) = "data: $(JSON3.write(data))\n\n"

function provider_error_fixture()
    replies = Channel{Tuple{String, String}}(2)
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        content_type, body = take!(replies)
        HTTP.Response(200, ["Content-Type" => content_type], body)
    end
    (; server, replies, base="http://$(HTTP.server_addr(server))")
end

function check_provider_error(result, secret, provider, kind, status)
    @test !result.done
    @test isdefined(JuliaForever, :ProviderError) && result.error isa JuliaForever.ProviderError
    @test hasproperty(result.error, :provider) && result.error.provider == provider
    @test hasproperty(result.error, :kind) && result.error.kind == kind
    @test hasproperty(result.error, :status) && result.error.status == status
    @test !occursin(secret, sprint(show, result.error))
    @test !occursin(secret, sprint(show, result))
    @test !occursin(secret, JSON3.write(result))
    @test !occursin(secret, JSON3.write(result.error))
    bytes = IOBuffer()
    serialize(bytes, result)
    @test !occursin(secret, String(take!(bytes)))
end
