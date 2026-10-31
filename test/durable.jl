using Test, JSON3, JuliaForever

import JuliaForever.Durable as D

mutable struct BadCopy end
Base.deepcopy_internal(::BadCopy, ::IdDict) = error("cannot detach return value")
