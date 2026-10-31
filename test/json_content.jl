module JSONContentTests

using Test, JuliaForever, JSON3, HTTP, SQLite
import JuliaForever.Durable as D
import JuliaForever.History as H

const MCP = JuliaForever.MCP
const S = JuliaForever.Sessions
const value = "\U00010000\U0010fffd"

struct Echo <: JuliaForever.Tool end
JuliaForever.name(::Echo) = "echo"
JuliaForever.description(::Echo) = "Echo Unicode."
JuliaForever.schema(::Echo) = Dict("type" => "object")
JuliaForever.execute(::Echo, args) = ToolSuccess(value)

struct Phase <: D.Phase
    value::String
end
D.encode(phase::Phase) = D.Checkpoint("fixture", phase.value)
struct Handler <: D.Handler end
D.name(::Handler) = "fixture"

# A valid JSON document can also be an existing filename on Unix. It exposes
# accidental path interpretation locally while the Unicode cases run on Windows.
function spoof(json, replacement)
    if Sys.isunix()
        @test sizeof(json) < 255
        write(json, replacement)
    end
end

end
