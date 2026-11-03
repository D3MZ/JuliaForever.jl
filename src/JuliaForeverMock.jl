module JuliaForeverMock

using Tachikoma
@tachikoma_app

include("mock/state.jl")
include("mock/input.jl")
include("mock/view.jl")
include("mock/compact.jl")
include("mock/prompt.jl")

function main()
    app(MockState(); fps=20, default_bindings=false)
end

end
