using Test, JuliaForever, JSON3

import JuliaForever.Kernel as K

struct Probe <: K.Effect
    name::String
end

struct Report <: K.Observation
    text::String
end

Base.isequal(a::Report, b::Report) = isequal(a.text, b.text)

struct EqualBox
    value::Any
end

Base.isequal(a::EqualBox, b::EqualBox) = isequal(a.value, b.value)
