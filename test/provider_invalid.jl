using Test, JuliaForever, HTTP, JSON3

struct BrokenText <: AbstractString end
Base.codeunits(::BrokenText) = throw(Base.IOError("fixture", -1))
struct BrokenArgumentText <: AbstractString end
Base.codeunits(::BrokenArgumentText) = throw(ArgumentError("unrelated"))
