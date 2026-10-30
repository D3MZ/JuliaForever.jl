function dispatchcallee(expression)
    expression isa Expr && expression.head == :. && last(expression.args) isa QuoteNode && return last(expression.args).value
    expression
end

const dispatchfields = (:type, :kind, :status, :phase, :reason, :role, :finish, :mode, :state, :outcome, :selected)

function dispatchfield(expression)
    expression isa Symbol && expression in dispatchfields && return expression
    expression isa Expr || return nothing
    if expression.head == :. && last(expression.args) isa QuoteNode
        return last(expression.args).value
    elseif expression.head == :ref && length(expression.args) == 2
        key = last(expression.args)
        return key isa QuoteNode ? key.value : key isa String ? Symbol(key) : nothing
    elseif expression.head == :call && dispatchcallee(first(expression.args)) in (:get, :getfield, :getproperty) && length(expression.args) >= 3
        key = expression.args[3]
        return key isa QuoteNode ? key.value : key isa String ? Symbol(key) : nothing
    end
    nothing
end

function dispatchpredicate(expression)
    dispatchcallee(expression) in (:isnothing, :ismissing, :cancelled) && return true
    expression isa Expr && expression.head == :call && first(expression.args) === :! && length(expression.args) == 2 && return dispatchpredicate(last(expression.args))
    false
end

const dispatchstatuses = Set(["cancelled", "canceled", "complete", "completed", "done", "end", "error", "failed", "function_call", "idle", "in_progress", "incomplete", "length", "pending", "placed", "queued", "ready", "running", "stop", "success", "timed_out", "timeout", "tool_calls"])
dispatchstatus(value) = false
dispatchstatus(value::String) = value in dispatchstatuses
dispatchstatus(value::Expr) = value.head in (:tuple, :vect) && any(dispatchstatus, value.args)

function dispatchstatuscheck(expression)
    expression isa Expr && expression.head == :call || return false
    dispatchcallee(first(expression.args)) in (:(===), :(!==), :(==), :(!=), :in, :∈) || return false
    args = expression.args[2:end]
    any(dispatchstatus, args) || any(arg -> dispatchfield(arg) in dispatchfields, args)
end

dispatchdynamic(value) = !(value isa Union{Number, AbstractString, Char, QuoteNode} || value in (:true, :false, :nothing))

function dispatchprobe(expression)
    expression isa Expr && expression.head == :call || return false
    callee = dispatchcallee(first(expression.args))
    if callee === :Val && length(expression.args) == 2
        return dispatchdynamic(last(expression.args))
    end
    if callee isa Expr && callee.head == :curly && length(callee.args) == 2 && dispatchcallee(first(callee.args)) === :Val
        return dispatchdynamic(last(callee.args))
    end
    callee in (:isa, :isnothing, :ismissing) && return true
    callee in (:(===), :(!==), :(==), :(!=)) || return false
    any(arg -> arg isa Expr && arg.head == :call && dispatchcallee(first(arg.args)) === :typeof, expression.args[2:end]) && return true
    any(arg -> arg in (:nothing, :missing) || arg isa Bool, expression.args[2:end])
end

function dispatchcheck(expression, direct)
    expression === :iserror && return true
    direct && expression isa Symbol && expression ∉ (:true, :false, :nothing) && return true
    expression isa Expr || return false
    direct && expression.head in (:., :ref) && return true
    expression.head == :. && last(expression.args) == QuoteNode(:iserror) && return true
    expression.head == :call || return false
    callee = dispatchcallee(first(expression.args))
    callee in (:isa, :isnothing, :ismissing, :typeof, :cancelled) && return true
    direct && callee === :get && last(expression.args) isa Bool && return true
    callee in (:(===), :(!==), :(==), :(!=)) && any(arg -> arg in (:nothing, :missing), expression.args) && return true
    callee in (:(===), :(!==), :(==), :(!=)) && any(arg -> arg isa Bool, expression.args[2:end]) && return true
    if callee in (:(===), :(!==), :(==), :(!=), :in, :∈)
        args = expression.args[2:end]
        any(dispatchstatus, args) && return true
        any(arg -> arg isa QuoteNode && arg.value isa Symbol, args) && return true
        any(arg -> arg isa Expr && arg.head in (:tuple, :vect) && any(item -> item isa QuoteNode && item.value isa Symbol, arg.args), args) && return true
        any(arg -> dispatchfield(arg) in dispatchfields, args) && return true
    end
    callee in (:get, :getfield, :getproperty) && QuoteNode(:iserror) in expression.args
end

function dispatchchecks!(checks, expression, condition=false, direct=true)
    if (condition && dispatchcheck(expression, direct)) || (!condition && (dispatchstatuscheck(expression) || dispatchprobe(expression)))
        value = expression isa Expr ? Base.remove_linenums!(deepcopy(expression)) : expression
        push!(checks, replace(sprint(show, value), '\n' => ' '))
        return checks
    end
    expression isa Expr || return checks
    expression.head in (:quote, :inert) && return checks
    if condition && expression.head == :block
        foreach(arg -> dispatchchecks!(checks, arg), expression.args[1:end-1])
        dispatchchecks!(checks, last(expression.args), true, direct)
    elseif expression.head in (:if, :while, :elseif, :filter)
        dispatchchecks!(checks, first(expression.args), true)
        foreach(arg -> dispatchchecks!(checks, arg), expression.args[2:end])
    elseif expression.head in (:&&, :||)
        dispatchchecks!(checks, first(expression.args), true)
        dispatchchecks!(checks, last(expression.args), condition)
    elseif expression.head == :call && first(expression.args) === :!
        dispatchchecks!(checks, expression.args[2], condition, direct)
    elseif expression.head == :call && dispatchcallee(first(expression.args)) === :ifelse
        dispatchchecks!(checks, expression.args[2], true)
        foreach(arg -> dispatchchecks!(checks, arg), expression.args[3:end])
    elseif expression.head == :call && dispatchcallee(first(expression.args)) in (:filter, :filter!, :findfirst, :findlast, :findall, :findnext, :findprev, :any, :all, :count, :takewhile, :dropwhile) && length(expression.args) >= 3
        predicate = expression.args[2]
        if predicate isa Expr && predicate.head == :->
            dispatchchecks!(checks, predicate.args[2], true)
        elseif dispatchpredicate(predicate)
            push!(checks, sprint(show, predicate))
        else
            dispatchchecks!(checks, predicate, true, false)
        end
        foreach(arg -> dispatchchecks!(checks, arg), expression.args[3:end])
    else
        foreach(arg -> dispatchchecks!(checks, arg, condition, false), expression.args)
    end
    checks
end

dispatchchecks(expression) = dispatchchecks!(String[], expression)

function dispatchdifference(actual, expected)
    remaining = Dict{String, Int}()
    for entry in expected
        remaining[entry] = get(remaining, entry, 0) + 1
    end
    extra = String[]
    for entry in actual
        count = get(remaining, entry, 0)
        if count == 0
            push!(extra, entry)
        else
            remaining[entry] = count - 1
        end
    end
    extra
end

function dispatchbaseline(root)
    entries = String[]
    for (dir, _, files) in walkdir(root)
        for name in files
            endswith(name, ".jl") || continue
            file = joinpath(dir, name)
            for check in dispatchchecks(Meta.parseall(read(file, String)))
                push!(entries, relpath(file, root) * "\t" * check)
            end
        end
    end
    sort!(entries)
end
