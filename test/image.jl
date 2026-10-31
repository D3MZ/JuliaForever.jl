using Test, JuliaForever, HTTP, JSON3, Base64, Distributed
import JuliaForever.History as ImageHistory
import JuliaForever.Conversation as ImageConversation
import JuliaForever.Kernel as ImageKernel

const imagepng = read(joinpath(@__DIR__, "fixtures", "pixel.png"))
const imagejpeg = read(joinpath(@__DIR__, "fixtures", "pixel.jpg"))

mutable struct ImageProvider
    replies::Vector{Any}
    requests::Vector{Any}
end
function JuliaForever.complete(provider::ImageProvider, messages, tools)
    push!(provider.requests, deepcopy(messages))
    popfirst!(provider.replies)
end
