struct InvalidMessage end
const maxjsondepth = 512

jsonfailures(exceptions, depth) = length(exceptions) > depth ? jsonfailures(last(exceptions).exception) : ()
jsonfailures(::ArgumentError) = (InvalidMessage(),)
jsonfailures(exception) = ()
jsonmessage(text) = jsonmessage(text, Dict{String, Any})
function jsonmessage(text, target)
    JSON.isvalidjson(text; maxdepth=maxjsondepth) || return InvalidMessage()
    depth = length(current_exceptions())
    try
        JSON3.read(codeunits(text), target)
    finally
        for failure in jsonfailures(current_exceptions(), depth)
            return failure
        end
    end
end

validmessage(message) = InvalidMessage()
validmessage(invalid::InvalidMessage) = invalid
validmessage(message::AbstractDict) = validmessage(message, toolfield(message, "method"), toolfield(message, "error"))
validmessage(message, ::Some, error) = message
validmessage(message, ::Nothing, ::Nothing) = message
validmessage(message, ::Nothing, error::Some) = validerror(message, something(error))
validerror(message, value) = InvalidMessage()
validerror(message, value::AbstractDict) = validerror(message, get(value, "code", nothing), get(value, "message", nothing))
validerror(message, code, text) = InvalidMessage()
validerror(message, code::Bool, text::AbstractString) = InvalidMessage()
validerror(message, code::Real, text::AbstractString) = message
