using Random, SHA
using ..JuliaForever: base64url

struct Register end

struct Returning
    client::String
    subject::String
    id_token::Union{Nothing, String}
    email::Union{Nothing, String}
end

Returning(client::AbstractString, subject::AbstractString; id_token=nothing, email=nothing) = Returning(String(client), String(subject), id_token, email)
Base.show(io::IO, ::Returning) = print(io, "Returning([redacted])")

struct Reconsent
    registration::Returning
end

Base.show(io::IO, ::Reconsent) = print(io, "Reconsent([redacted])")

struct Denied end

struct Code
    code::String
    client::String
    ticket::Channel{Nothing}
    gate::ReentrantLock
end

function Code(code::AbstractString, client::AbstractString)
    ticket = Channel{Nothing}(1)
    put!(ticket, nothing)
    Code(String(code), String(client), ticket, ReentrantLock())
end

function consume(code::Code)
    lock(code.gate) do
        isready(code.ticket) || return nothing
        take!(code.ticket)
        code.code
    end
end

Base.show(io::IO, ::Code) = print(io, "Code([redacted])")

function callbackclient(::Register, clients)
    length(clients) == 1 || return nothing
    client = only(clients)
    isempty(client) || client == "dynamic_agent_client" ? nothing : client
end

function callbackclient(registration::Returning, clients)
    isempty(clients) && return registration.client
    clients == [registration.client] ? registration.client : nothing
end

callbackclient(registration::Reconsent, clients) = callbackclient(registration.registration, clients)

function callback(registration, state, params)
    values = Dict{String, Vector{String}}()
    for (key, value) in params
        push!(get!(values, key, String[]), value)
    end
    states = get(values, "state", String[])
    states == [state] || return nothing
    codes = get(values, "code", String[])
    failures = get(values, "error", String[])
    if length(failures) == 1 && !isempty(only(failures)) && isempty(codes)
        return Denied()
    end
    isempty(failures) && length(codes) == 1 && !isempty(only(codes)) || return nothing
    clients = get(values, "client_id", String[])
    callbackcode(callbackclient(registration, clients), only(codes))
end

callbackcode(::Nothing, code) = nothing
callbackcode(client::AbstractString, code) = Code(code, client)

abstract type CallbackState end
struct CallbackOpen <: CallbackState end
struct CallbackClosed <: CallbackState end
mutable struct CallbackBox
    result::Channel{Union{Code, Denied}}
    gate::ReentrantLock
    state::CallbackState
end
CallbackBox() = CallbackBox(Channel{Union{Code, Denied}}(1), ReentrantLock(), CallbackOpen())

reply(::Nothing, box) = HTTP.Response(400)
function reply(value::Union{Code, Denied}, box::CallbackBox)
    lock(box.gate) do
        deliver!(box, box.state, value)
    end
end
deliver!(box, ::CallbackClosed, value) = HTTP.Response(409)
function deliver!(box, ::CallbackOpen, value)
    put!(box.result, value)
    close!(box, box.state)
    HTTP.Response(200, ["Content-Type" => "text/plain; charset=utf-8", "Cache-Control" => "no-store", "Referrer-Policy" => "no-referrer"], "You may close this window.")
end
close!(box, ::CallbackClosed) = nothing
function close!(box, ::CallbackOpen)
    close(box.result)
    box.state = CallbackClosed()
    nothing
end

struct Pending{S, R}
    server::S
    registration::R
    host::String
    redirect::String
    state::String
    nonce::String
    verifier::String
    box::CallbackBox
end

Base.show(io::IO, ::Pending) = print(io, "Pending([redacted])")

function Pending(registration::Union{Register, Returning, Reconsent}, host::AbstractString)
    state = String(base64url(rand(RandomDevice(), UInt8, 32)))
    nonce = String(base64url(rand(RandomDevice(), UInt8, 32)))
    verifier = String(base64url(rand(RandomDevice(), UInt8, 32)))
    box = CallbackBox()
    address = Ref("")
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        request.method == "GET" || return HTTP.Response(405)
        uri = HTTP.URI(request.target)
        uri.path == "/auth/callback" || return HTTP.Response(404)
        isempty(uri.host) && isempty(uri.scheme) && HTTP.header(request, "Host", "") == address[] || return HTTP.Response(400)
        reply(callback(registration, state, HTTP.queryparampairs(uri)), box)
    end
    address[] = "127.0.0.1:$(HTTP.port(server))"
    Pending(server, registration, String(host), "http://$(address[])/auth/callback", state, nonce, verifier, box)
end

client(::Register) = "dynamic_agent_client"
client(registration::Returning) = registration.client
client(registration::Reconsent) = client(registration.registration)
hint(::Register) = ["agent_name_hint" => "Julia Forever"]
hint(::Nothing, key) = Pair{String, String}[]
hint(value::AbstractString, key) = [key => String(value)]
hint(registration::Returning) = [hint(registration.id_token, "id_token_hint"); hint(registration.email, "login_hint")]
hint(registration::Reconsent) = [hint(registration.registration); "prompt" => "consent"]

struct Authorization
    uri::String
end

Base.show(io::IO, ::Authorization) = print(io, "Authorization([redacted])")

launchfailure(::InterruptException) = Rejected(:cancelled)
launchfailure(::Any) = Rejected(:browser)

function launch(open::Function, authorization::Authorization)
    # An opener exception can include the complete authorization URI.
    try
        open(authorization.uri) ? nothing : Rejected(:browser)
    catch failure
        launchfailure(failure)
    end
end

function authorize(pending::Pending)
    values = ["client_id" => client(pending.registration), "ext_agent_host_id" => pending.host, "response_type" => "code", "redirect_uri" => pending.redirect, "scope" => "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct", "resource" => "https://api.openai.com/v1", "state" => pending.state, "nonce" => pending.nonce, "code_challenge_method" => "S256", "code_challenge" => base64url(sha256(pending.verifier))]
    append!(values, hint(pending.registration))
    query = join(("$(HTTP.escapeuri(key))=$(HTTP.escapeuri(value))" for (key, value) in values), "&")
    Authorization("https://auth.openai.com/api/accounts/authorize?$query")
end

struct CallbackReady end
function Base.wait(pending::Pending; timeout=300)
    result = timedwait(() -> isready(pending.box.result), timeout; pollint=0.01)
    callbackwait(pending.box, get(Dict(:ok => CallbackReady()), result, nothing))
end
callbackwait(box, ::CallbackReady) = take!(box.result)
function callbackwait(box, ::Nothing)
    lock(box.gate) do
        isready(box.result) && return take!(box.result)
        close!(box, box.state)
        nothing
    end
end

function Base.close(pending::Pending)
    lock(pending.box.gate) do
        close!(pending.box, pending.box.state)
    end
    close(pending.server)
    wait(pending.server)
    nothing
end
