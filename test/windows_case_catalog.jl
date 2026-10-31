module WindowsCaseCatalogTests

using Test, JuliaForever, SHA, SQLite
import JuliaForever.History as H
import JuliaForever.SessionCatalog as Catalog
import JuliaForever.Conversation as C

struct FixtureCaseProject <: AbstractString
    path::String
end
Catalog.spellings(project::FixtureCaseProject) = (project.path,)
Catalog.projectlist(dir, project::FixtureCaseProject, paths) = Catalog.listcase(dir, paths)
struct CaseProvider end
JuliaForever.complete(::CaseProvider, messages, tools) = Dict("role" => "assistant", "content" => "reply")

function session(dir, cwd, id, title; recorded=cwd)
    file = joinpath(dir, Catalog.filename(cwd, id))
    prompt = JuliaForever.context(recorded, JuliaForever.Tool[], [])
    state = C.State("fixture"; automatic=false, messages=C.Message[C.RawMessage(Dict("role" => "system", "content" => prompt))])
    tree = H.Tree(Catalog.Deferred(file))
    try
        @test H.append!(tree, 0, Any[H.encode_initial(state)]) == 1
        @test H.append!(tree, 1, Any[H.encode(C.Input(0, title))]) == 2
    finally
        close(tree)
    end
    file
end

const metadata_fault = Ref(:none)
const copy_inserts = Ref(0)
const scan_root = Ref("")
const scan_original = Ref("")
const scan_alternate = Ref("")
const scan_file = Ref("")
const visible_during_copy = Ref(true)
function catalog_authorizer(arg::Ptr{Cvoid}, action::Cint, table::Cstring, column::Cstring, database::Cstring, source::Cstring)::Cint
    if table != C_NULL
        name = unsafe_string(table)
        if action == SQLite.C.SQLITE_UPDATE && name == "jf_meta" && metadata_fault[] == :metadata
            return SQLite.C.SQLITE_DENY
        elseif action == SQLite.C.SQLITE_INSERT && name == "jf_history" && metadata_fault[] in (:copy, :observe)
            copy_inserts[] += 1
            if copy_inserts[] == 6
                metadata_fault[] == :copy && return SQLite.C.SQLITE_DENY
                paths = (scan_original[], scan_alternate[])
                visible_during_copy[] = any(cwd -> scan_file[] in Set(item.path for item in Catalog.listcase(scan_root[], (cwd,))), paths)
            end
        end
    end
    SQLite.C.SQLITE_OK
end
const deny_catalog_write = @cfunction(catalog_authorizer, Cint, (Ptr{Cvoid}, Cint, Cstring, Cstring, Cstring, Cstring))

end
