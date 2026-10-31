using Test, JuliaForever
import JuliaForever.History as ForkHistory
import JuliaForever.Conversation as ForkConversation
import JuliaForever.SessionCatalog as ForkCatalog

struct ForkProvider end
JuliaForever.complete(::ForkProvider, messages, tools) = Dict("role" => "assistant", "content" => "reply:" * messages[end]["content"])
struct InterruptedForkProvider end
JuliaForever.complete(::InterruptedForkProvider, messages, tools) = sqrt(-1)
forktexts(agent) = [message["content"] for message in agent.messages if message["role"] in ("user", "assistant")]
