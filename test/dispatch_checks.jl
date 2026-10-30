function dispatchcallee(expression)
    expression isa Expr && expression.head == :. && last(expression.args) isa QuoteNode && return last(expression.args).value
    expression
end

const dispatchfields = (:type, :kind, :status, :phase, :reason, :role, :finish, :mode, :state, :outcome, :selected, :label, :code, :effort)
const dispatchresultflags = Dict(:Completion => 5, :ToolResult => 3, :ToolReply => 3, :CodeResult => 2, :BashMessage => 5)
const dispatchresultproperties = Dict(:Completion => :done, :CodeResult => :ok)
const dispatchresultvariables = Set([:iserror, :failed, :failure, :ok, :done, :success, :cancelled, :truncated, :flag])
const dispatchflagvariables = union(dispatchresultvariables, Set([:exclude, :negate, :enabled]))

struct DispatchPredicates
    booleans::Set{Symbol}
    labels::Set{Symbol}
end
DispatchPredicates() = DispatchPredicates(Set{Symbol}(), Set{Symbol}())

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

function dispatchpredicate(expression, predicates=DispatchPredicates())
    (dispatchcallee(expression) in (:isnothing, :ismissing, :cancelled) || dispatchcallee(expression) in predicates.booleans) && return true
    expression isa Expr && expression.head == :call && first(expression.args) === :! && length(expression.args) == 2 && return dispatchpredicate(last(expression.args), predicates)
    false
end

function dispatchlabelcheck(expression, predicates)
    expression isa Expr && expression.head == :call || return false
    dispatchcallee(first(expression.args)) in (:(===), :(!==), :(==), :(!=), :in, :∈) || return false
    any(arg -> arg isa Expr && arg.head == :call && dispatchcallee(first(arg.args)) in predicates.labels, expression.args[2:end])
end

const dispatchstatuses = Set(["cancelled", "canceled", "complete", "completed", "done", "end", "error", "failed", "function_call", "idle", "in_progress", "incomplete", "length", "pending", "placed", "queued", "ready", "running", "stop", "success", "timed_out", "timeout", "tool_calls"])
dispatchstatus(value) = false
dispatchstatus(value::String) = value in dispatchstatuses || (startswith(value, "--") && ncodeunits(value) > 2) || occursin(r"^-[A-Za-z]", value)
dispatchstatus(value::Expr) = value.head in (:tuple, :vect) && any(dispatchstatus, value.args)

function dispatchstatuscheck(expression)
    expression isa Expr && expression.head == :call || return false
    dispatchcallee(first(expression.args)) in (:(===), :(!==), :(==), :(!=), :in, :∈) || return false
    args = expression.args[2:end]
    any(dispatchstatus, args) || any(arg -> dispatchfield(arg) in dispatchfields, args)
end

dispatchdynamic(value) = value isa Bool || !(value isa Union{Number, AbstractString, Char, QuoteNode} || value in (:true, :false, :nothing))

function dispatchprobe(expression)
    expression isa Expr || return false
    if expression.head == :curly && length(expression.args) == 2 && dispatchcallee(first(expression.args)) === :Val && last(expression.args) isa Bool
        return true
    end
    expression.head == :call || return false
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
    any(arg -> arg in (:nothing, :missing) || arg isa Bool || (arg isa Symbol && arg in dispatchflagvariables), expression.args[2:end])
end

function dispatchcheck(expression, direct)
    expression === :iserror && return direct
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
    callee in (:(===), :(!==), :(==), :(!=)) && any(arg -> arg isa Symbol && arg in dispatchflagvariables, expression.args[2:end]) && return true
    if callee in (:(===), :(!==), :(==), :(!=), :in, :∈)
        args = expression.args[2:end]
        any(dispatchstatus, args) && return true
        any(arg -> arg isa QuoteNode && arg.value isa Symbol, args) && return true
        any(arg -> arg isa Expr && arg.head in (:tuple, :vect) && any(item -> item isa QuoteNode && item.value isa Symbol, arg.args), args) && return true
        any(arg -> dispatchfield(arg) in dispatchfields, args) && return true
    end
    callee in (:get, :getfield, :getproperty) && QuoteNode(:iserror) in expression.args
end

function dispatchboolreturn(expression)
    expression isa Bool && return true
    expression isa Expr || return false
    if expression.head == :block
        values = filter(value -> !(value isa LineNumberNode), expression.args)
        return !isempty(values) && dispatchboolreturn(last(values))
    elseif expression.head == :return && length(expression.args) == 1
        return dispatchboolreturn(only(expression.args))
    elseif expression.head in (:if, :elseif) && length(expression.args) == 3
        return dispatchboolreturn(expression.args[2]) && dispatchboolreturn(expression.args[3])
    end
    false
end

function dispatchbools!(names, expression)
    expression isa Expr || return names
    expression.head in (:quote, :inert) && return names
    if expression.head in (:(=), :function) && length(expression.args) == 2
        signature, body = expression.args
        while signature isa Expr && signature.head in (:where, :(::))
            signature = first(signature.args)
        end
        while body isa Expr && body.head == :block
            values = filter(value -> !(value isa LineNumberNode), body.args)
            isempty(values) && break
            body = last(values)
        end
        if body isa Expr && body.head == :return && length(body.args) == 1
            body = only(body.args)
        end
        if signature isa Expr && signature.head == :call && dispatchboolreturn(body) && any(arg -> arg isa Expr && arg.head == :(::), signature.args[2:end])
            name = dispatchcallee(first(signature.args))
            name isa Symbol && push!(names, name)
        end
    end
    foreach(arg -> dispatchbools!(names, arg), expression.args)
    names
end

function dispatchlabelreturn(expression)
    expression isa String && return true
    expression isa QuoteNode && return expression.value isa Symbol
    expression isa Expr || return false
    if expression.head == :block
        values = filter(value -> !(value isa LineNumberNode), expression.args)
        return !isempty(values) && dispatchlabelreturn(last(values))
    elseif expression.head == :return && length(expression.args) == 1
        return dispatchlabelreturn(only(expression.args))
    elseif expression.head in (:if, :elseif) && length(expression.args) == 3
        return dispatchlabelreturn(expression.args[2]) && dispatchlabelreturn(expression.args[3])
    end
    false
end

function dispatchlabels!(names, expression)
    expression isa Expr || return names
    expression.head in (:quote, :inert) && return names
    if expression.head in (:(=), :function) && length(expression.args) == 2
        signature, body = expression.args
        while signature isa Expr && signature.head in (:where, :(::))
            signature = first(signature.args)
        end
        if signature isa Expr && signature.head == :call && dispatchlabelreturn(body) && any(arg -> arg isa Expr && arg.head == :(::), signature.args[2:end])
            name = dispatchcallee(first(signature.args))
            name isa Symbol && push!(names, name)
        end
    end
    foreach(arg -> dispatchlabels!(names, arg), expression.args)
    names
end

function dispatchconstructor(signature)
    signature isa Expr || return false
    signature.head in (:where, :(::)) && return dispatchconstructor(first(signature.args))
    signature.head == :call && haskey(dispatchresultflags, dispatchcallee(first(signature.args)))
end

function dispatchsignature!(checks, signature, predicates)
    if signature.head in (:where, :(::))
        dispatchsignature!(checks, first(signature.args), predicates)
    end
    foreach(arg -> dispatchchecks!(checks, arg, false, true, predicates), signature.args[2:end])
    checks
end

function dispatchchecks!(checks, expression, condition=false, direct=true, predicates=DispatchPredicates())
    boolcall = condition && expression isa Expr && expression.head == :call && dispatchcallee(first(expression.args)) in predicates.booleans
    if boolcall || dispatchlabelcheck(expression, predicates) || (condition && dispatchcheck(expression, direct)) || (!condition && (dispatchstatuscheck(expression) || dispatchprobe(expression)))
        value = expression isa Expr ? Base.remove_linenums!(deepcopy(expression)) : expression
        push!(checks, replace(sprint(show, value), '\n' => ' '))
        return checks
    end
    expression isa Expr || return checks
    expression.head in (:quote, :inert) && return checks
    if expression.head in (:(=), :function) && length(expression.args) == 2 && dispatchconstructor(first(expression.args))
        dispatchsignature!(checks, first(expression.args), predicates)
        dispatchchecks!(checks, last(expression.args), false, true, predicates)
    elseif condition && expression.head == :block
        foreach(arg -> dispatchchecks!(checks, arg, false, true, predicates), expression.args[1:end-1])
        dispatchchecks!(checks, last(expression.args), true, direct, predicates)
    elseif expression.head in (:if, :while, :elseif, :filter)
        dispatchchecks!(checks, first(expression.args), true, true, predicates)
        foreach(arg -> dispatchchecks!(checks, arg, false, true, predicates), expression.args[2:end])
    elseif expression.head in (:&&, :||)
        dispatchchecks!(checks, first(expression.args), true, true, predicates)
        dispatchchecks!(checks, last(expression.args), condition, true, predicates)
    elseif expression.head == :kw && length(expression.args) == 2
        value = last(expression.args)
        boolkeyword = value isa Expr && value.head == :call && dispatchcallee(first(value.args)) in predicates.booleans
        dispatchchecks!(checks, value, boolkeyword, false, predicates)
    elseif expression.head == :call && first(expression.args) === :!
        dispatchchecks!(checks, expression.args[2], condition, direct, predicates)
    elseif expression.head == :call && haskey(dispatchresultflags, dispatchcallee(first(expression.args)))
        callee = dispatchcallee(first(expression.args))
        index = dispatchresultflags[callee]
        property = get(dispatchresultproperties, callee, nothing)
        fields = callee === :BashMessage ? ((5, :cancelled), (6, :truncated)) : ((index, property),)
        if any(fields) do (index, property)
            length(expression.args) >= index && (expression.args[index] isa Bool || expression.args[index] in dispatchresultvariables || (!isnothing(property) && dispatchfield(expression.args[index]) === property))
        end
            value = Base.remove_linenums!(deepcopy(expression))
            push!(checks, replace(sprint(show, value), '\n' => ' '))
        end
        foreach(arg -> dispatchchecks!(checks, arg, true, false, predicates), expression.args[2:end])
    elseif expression.head == :call && dispatchcallee(first(expression.args)) === :ifelse
        dispatchchecks!(checks, expression.args[2], true, true, predicates)
        foreach(arg -> dispatchchecks!(checks, arg, false, true, predicates), expression.args[3:end])
    elseif expression.head == :call && dispatchcallee(first(expression.args)) in (:filter, :filter!, :findfirst, :findlast, :findall, :findnext, :findprev, :any, :all, :count, :takewhile, :dropwhile) && length(expression.args) >= 3
        predicate = expression.args[2]
        if predicate isa Expr && predicate.head == :->
            dispatchchecks!(checks, predicate.args[2], true, true, predicates)
        elseif dispatchpredicate(predicate, predicates)
            push!(checks, sprint(show, predicate))
        else
            dispatchchecks!(checks, predicate, true, false, predicates)
        end
        foreach(arg -> dispatchchecks!(checks, arg, false, true, predicates), expression.args[3:end])
    else
        foreach(arg -> dispatchchecks!(checks, arg, condition, false, predicates), expression.args)
    end
    checks
end

function dispatchchecks(expression)
    predicates = DispatchPredicates()
    dispatchbools!(predicates.booleans, expression)
    dispatchlabels!(predicates.labels, expression)
    dispatchchecks!(String[], expression, false, true, predicates)
end

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
    sources = Pair{String, Expr}[]
    for (dir, _, files) in walkdir(root)
        for name in files
            endswith(name, ".jl") || continue
            file = joinpath(dir, name)
            push!(sources, relpath(file, root) => Meta.parseall(read(file, String)))
        end
    end
    predicates = DispatchPredicates()
    foreach(source -> dispatchbools!(predicates.booleans, source.second), sources)
    foreach(source -> dispatchlabels!(predicates.labels, source.second), sources)
    entries = String[]
    for (file, expression) in sources
        for check in dispatchchecks!(String[], expression, false, true, predicates)
            push!(entries, file * "\t" * check)
        end
    end
    sort!(entries)
end
