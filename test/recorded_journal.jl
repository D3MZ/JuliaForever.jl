module RecordedJournalTests

using Test, Distributed, JuliaForever
import JuliaForever.Execution as E
import JuliaForever.History as H
import JuliaForever.Durable as D
import JuliaForever.Conversation as C
import JuliaForever.Kernel as K

isdefined(Main, :AgentExecutionCases) || Base.include(Main, joinpath(@__DIR__, "agent_execution_cases.jl"))
const Fixtures = Main.AgentExecutionCases

end
