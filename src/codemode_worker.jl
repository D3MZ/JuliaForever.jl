const JSON3 = Base.require(Base.PkgId(Base.UUID("0f8b85d8-7281-11e9-16c2-39a750bddbf1"), "JSON3"))

const input = open(Base.Libc.dup(Base.RawFD(0)))
const output = open(Base.Libc.dup(Base.RawFD(1)))
redirect_stdin(devnull)
redirect_stdout(open(ARGS[1], "w"))
redirect_stderr(open(ARGS[2], "a"))

const request = JSON3.read(codeunits(readline(input)))
const writelock = ReentrantLock()
const pendinglock = ReentrantLock()
const storelock = ReentrantLock()
const pending = Ref{Union{Nothing, Dict{Int, Channel{Any}}}}(Dict{Int, Channel{Any}}())
const serial = Ref(0)
const data = Dict{String, Any}(String(key) => value for (key, value) in pairs(request.store))
const writes = Dict{String, Any}()
const deletes = Set{String}()

function send(message)
    lock(writelock) do
        println(output, JSON3.write(message))
        flush(output)
    end
end

register!(::Nothing, channel) = nothing
function register!(pending::Dict, channel)
    serial[] += 1
    pending[serial[]] = channel
    serial[]
end

function toolcall(name, args)
    channel = Channel{Any}(1)
    id = lock(pendinglock) do
        register!(pending[], channel)
    end
    toolcall(name, args, channel, id)
end
toolcall(name, args, channel, ::Nothing) = (; text="Tool connection closed", iserror=true)
function toolcall(name, args, channel, id::Int)
    send((; type="call", id, name, args))
    take!(channel)
end

struct Tools end
struct ToolCall
    name::String
end
Base.getproperty(::Tools, name::Symbol) = ToolCall(String(name))
Base.getindex(::Tools, name::AbstractString) = ToolCall(String(name))
(call::ToolCall)(args) = toolcall(call.name, args)

textvalue(value::AbstractString) = String(value)
textvalue(value) = JSON3.write(value)
text(value) = send((; type="text", text=textvalue(value)))
function load(key::AbstractString)
    lock(storelock) do
        JSON3.read(codeunits(JSON3.write(get(data, key, nothing))))
    end
end
function store(key::AbstractString, value)
    copy = JSON3.read(codeunits(JSON3.write(value)))
    lock(storelock) do
        data[key] = copy
        writes[key] = copy
        delete!(deletes, key)
    end
    nothing
end
function forget!(key::AbstractString)
    lock(storelock) do
        delete!(data, key)
        delete!(writes, key)
        push!(deletes, key)
    end
    nothing
end

takepending!(::Nothing, id) = nothing
takepending!(pending::Dict, id) = pop!(pending, id, nothing)
deliver!(::Nothing, result) = nothing
deliver!(channel::Channel, result) = put!(channel, result)
disconnect!(::Nothing) = nothing
function disconnect!(pending::Dict)
    foreach(channel -> put!(channel, (; text="Tool connection closed", iserror=true)), values(pending))
    empty!(pending)
end

Threads.@spawn begin
    try
        for line in eachline(input)
            message = JSON3.read(codeunits(line))
            channel = lock(pendinglock) do
                takepending!(pending[], Int(message.id))
            end
            deliver!(channel, message.result)
        end
    catch
    finally
        lock(pendinglock) do
            disconnect!(pending[])
            pending[] = nothing
        end
    end
end

program = Module(:CodeProgram)
for (key, value) in ((:tools, Tools()), (:ALL_TOOLS, request.tools), (:text, text), (:load, load), (:store, store), (:forget!, forget!))
    Core.eval(program, Expr(:const, Expr(:(=), key, QuoteNode(value))))
end

try
    value = Base.include_string(program, request.code, "codemode.jl")
    flush(stdout)
    flush(stderr)
    changed, removed = lock(storelock) do
        copy(writes), collect(deletes)
    end
    send((; type="result", ok=true, value, writes=changed, deletes=removed))
catch exception
    flush(stdout)
    flush(stderr)
    send((; type="result", ok=false, message=sprint(showerror, exception)))
end
