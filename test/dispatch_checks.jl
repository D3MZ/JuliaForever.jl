function dispatchcheck(expression, direct)
    expression === :iserror && return true
    direct && expression isa Symbol && expression ∉ (:true, :false, :nothing) && return true
    expression isa Expr || return false
    direct && expression.head == :. && return true
    expression.head == :. && last(expression.args) == QuoteNode(:iserror) && return true
    expression.head == :call || return false
    callee = first(expression.args)
    callee isa Expr && callee.head == :. && (callee = last(callee.args).value)
    callee in (:isa, :isnothing, :typeof, :cancelled) && return true
    callee in (:(===), :(!==), :(==), :(!=)) && :nothing in expression.args && return true
    callee in (:(===), :(!==), :(==), :(!=)) && any(arg -> arg isa Bool, expression.args[2:end]) && return true
    callee in (:get, :getfield, :getproperty) && QuoteNode(:iserror) in expression.args
end

function dispatchchecks!(checks, expression, condition=false, direct=true)
    if condition && dispatchcheck(expression, direct)
        push!(checks, sprint(show, expression))
        return checks
    end
    expression isa Expr || return checks
    expression.head in (:quote, :inert) && return checks
    if condition && expression.head == :block
        foreach(arg -> dispatchchecks!(checks, arg), expression.args[1:end-1])
        dispatchchecks!(checks, last(expression.args), true, direct)
    elseif expression.head in (:if, :while, :elseif)
        dispatchchecks!(checks, first(expression.args), true)
        foreach(arg -> dispatchchecks!(checks, arg), expression.args[2:end])
    elseif expression.head in (:&&, :||)
        dispatchchecks!(checks, first(expression.args), true)
        dispatchchecks!(checks, last(expression.args), condition)
    elseif expression.head == :call && first(expression.args) === :!
        dispatchchecks!(checks, expression.args[2], condition, direct)
    elseif expression.head == :call && first(expression.args) === :ifelse
        dispatchchecks!(checks, expression.args[2], true)
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
