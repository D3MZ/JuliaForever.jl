module KernelExecutionCases

using Distributed, JuliaForever
import JuliaForever.Kernel as K
import JuliaForever.Execution as E

E.perform(effect::K.Call{Int}, cancellation::E.Cancellation) = (effect.input * 2, myid())

struct BadEffect <: K.Effect end
E.perform(::BadEffect, cancellation::E.Cancellation) = error("effect failed")

end
