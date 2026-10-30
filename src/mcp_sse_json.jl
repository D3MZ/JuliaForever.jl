struct InvalidSSE end
const maxjsondepth = 512

jsonfailures(exceptions, depth) = length(exceptions) > depth ? jsonfailures(last(exceptions).exception) : ()
jsonfailures(::ArgumentError) = (InvalidSSE(),)
jsonfailures(exception) = ()
function sseparse(data)
    text = join(data, "\n")
    JSON.isvalidjson(text; maxdepth=maxjsondepth) || return InvalidSSE()
    depth = length(current_exceptions())
    try
        JSON3.read(codeunits(text), Dict{String, Any})
    finally
        for failure in jsonfailures(current_exceptions(), depth)
            return failure
        end
    end
end

ssevalid(invalid::InvalidSSE) = invalid
ssevalid(message::AbstractDict) = ssevalid(message, toolfield(message, "method"), toolfield(message, "error"))
ssevalid(message, ::Some, error) = message
ssevalid(message, ::Nothing, ::Nothing) = message
ssevalid(message, ::Nothing, error::Some) = sseerror(message, something(error))
sseerror(message, value) = InvalidSSE()
sseerror(message, value::AbstractDict) = sseerror(message, get(value, "code", nothing), get(value, "message", nothing))
sseerror(message, code, text) = InvalidSSE()
sseerror(message, code::Bool, text::AbstractString) = InvalidSSE()
sseerror(message, code::Real, text::AbstractString) = message
