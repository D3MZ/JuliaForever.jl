using Test, Distributed, JuliaForever

const E = JuliaForever.Execution
include("execution_cases.jl")
const ExecCases = ExecutionCases

function channels()
    RemoteChannel(() -> Channel{Int}(1)), RemoteChannel(() -> Channel{Nothing}(1))
end
