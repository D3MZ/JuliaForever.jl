struct Plan{C<:Credential, F, N}
    model::String
    session::C
    post::F
    now::N
end

Plan(model::AbstractString, session::Credential; post=HTTP.post, now=time) = Plan(String(model), session, post, now)
Base.show(io::IO, ::Plan) = print(io, "Plan([redacted])")
