using Test, JuliaForever
const MCP = JuliaForever.MCP
takebefore(channel) = timedwait(() -> isready(channel), 15) == :ok ? take!(channel) : error("timed out waiting for callback")
fetchbefore(task) = timedwait(() -> istaskdone(task), 15) == :ok ? fetch(task) : error("timed out waiting for request")
server() = `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(Base.active_project())) $(joinpath(@__DIR__, "mcp_progress_native_server.jl"))`
