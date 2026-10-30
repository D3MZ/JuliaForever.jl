import JuliaSyntax

function branchpoints!(result, node, file)
    kind = string(JuliaSyntax.kind(node))
    kind == "quote" && return result
    children = JuliaSyntax.children(node)
    isnothing(children) && return result
    if kind in ("if", "elseif", "for", "while", "?", "&&", "||", "filter") && !isempty(children)
        condition = kind == "filter" ? last(children) : first(children)
        push!(result, (; file, line=JuliaSyntax.source_line(node), kind, condition=strip(JuliaSyntax.sourcetext(condition))))
    elseif kind == "call" && JuliaSyntax.is_prefix_call(node) && length(children) > 1
        callee = last(split(JuliaSyntax.sourcetext(first(children)), '.'))
        if callee == "ifelse"
            push!(result, (; file, line=JuliaSyntax.source_line(node), kind="ifelse", condition=strip(JuliaSyntax.sourcetext(children[2]))))
        elseif length(children) > 2 && callee in ("filter", "filter!", "findfirst", "findlast", "findall", "findnext", "findprev", "any", "all", "count", "takewhile", "dropwhile")
            push!(result, (; file, line=JuliaSyntax.source_line(node), kind="predicate", condition=strip(JuliaSyntax.sourcetext(children[2]))))
        end
    elseif kind == "catch"
        push!(result, (; file, line=JuliaSyntax.source_line(node), kind, condition="exception"))
    end
    foreach(child -> branchpoints!(result, child, file), children)
    result
end

function branchpoints(source; file="")
    node = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, source; filename=file)
    branchpoints!(NamedTuple[], node, file)
end

function branchfiles(root::AbstractString)
    result = NamedTuple[]
    for (dir, _, files) in walkdir(root)
        for name in files
            endswith(name, ".jl") || continue
            file = joinpath(dir, name)
            append!(result, branchpoints(read(file, String); file=relpath(file, root)))
        end
    end
    sort!(result; by=point -> (point.file, point.line, point.kind, point.condition))
end

branchentry(point) = string(point.file, '\t', point.kind, '\t', repr(point.condition))
branchbaseline(root::AbstractString) = sort!([branchentry(point) for point in branchfiles(root)])

function branchdifference(actual, expected)
    remaining = copy(expected)
    filter(actual) do entry
        index = findfirst(==(entry), remaining)
        isnothing(index) && return true
        deleteat!(remaining, index)
        false
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    for point in branchfiles(joinpath(@__DIR__, "..", "src"))
        println(point.file, ':', point.line, '\t', point.kind, '\t', replace(point.condition, '\n' => ' '))
    end
end
