const JSON3 = Base.require(Base.PkgId(Base.UUID("0f8b85d8-7281-11e9-16c2-39a750bddbf1"), "JSON3"))

const input = open(Base.Libc.dup(Base.RawFD(0)))
const output = open(Base.Libc.dup(Base.RawFD(1)))
redirect_stdin(devnull)
redirect_stdout(open(ARGS[1], "w"))
redirect_stderr(open(ARGS[2], "a"))

const request = JSON3.read(readline(input))
const writelock = ReentrantLock()
const pendinglock = ReentrantLock()
const storelock = ReentrantLock()
const pending = Dict{Int, Channel{Any}}()
const serial = Ref(0)
const connected = Ref(true)
const data = Dict{String, Any}(String(key) => value for (key, value) in pairs(request.store))
const writes = Dict{String, Any}()

function send(message)
    lock(writelock) do
        println(output, JSON3.write(message))
        flush(output)
    end
end

function toolcall(name, args)
    channel = Channel{Any}(1)
    id = lock(pendinglock) do
        if connected[]
            serial[] += 1
            pending[serial[]] = channel
            serial[]
        end
    end
    isnothing(id) && return (; text="Tool connection closed", iserror=true)
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

text(value) = send((; type="text", text=value isa AbstractString ? String(value) : JSON3.write(value)))
function load(key::AbstractString)
    lock(storelock) do
        JSON3.read(JSON3.write(get(data, key, nothing)))
    end
end
function store(key::AbstractString, value)
    copy = JSON3.read(JSON3.write(value))
    lock(storelock) do
        data[key] = copy
        writes[key] = copy
    end
    nothing
end

Threads.@spawn begin
    try
        for line in eachline(input)
            message = JSON3.read(line)
            channel = lock(pendinglock) do
                pop!(pending, Int(message.id), nothing)
            end
            !isnothing(channel) && put!(channel, message.result)
        end
    catch
    finally
        lock(pendinglock) do
            connected[] = false
            foreach(channel -> put!(channel, (; text="Tool connection closed", iserror=true)), values(pending))
            empty!(pending)
        end
    end
end

program = Module(:CodeProgram)
for (key, value) in ((:tools, Tools()), (:ALL_TOOLS, request.tools), (:text, text), (:load, load), (:store, store))
    Core.eval(program, Expr(:const, Expr(:(=), key, QuoteNode(value))))
end

try
    value = Base.include_string(program, request.code, "codemode.jl")
    flush(stdout)
    flush(stderr)
    changed = lock(storelock) do
        copy(writes)
    end
    send((; type="result", ok=true, value, writes=changed))
catch exception
    flush(stdout)
    flush(stderr)
    send((; type="result", ok=false, message=sprint(showerror, exception)))
end
