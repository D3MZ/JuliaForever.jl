using Test, JuliaForever, JSON3

import JuliaForever.Kernel as K
import JuliaForever.Conversation as C

function reply(text; calls=C.ToolCall[], finish="stop", done=true)
    C.ModelReply(C.Assistant(text, calls, finish, done))
end
