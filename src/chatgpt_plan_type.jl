struct Plan{F, N}
    model::String
    session::Session
    post::F
    now::N
end

Plan(model::AbstractString, session::Session; post=HTTP.post, now=time) = Plan(String(model), session, post, now)
Base.show(io::IO, ::Plan) = print(io, "Plan([redacted])")
