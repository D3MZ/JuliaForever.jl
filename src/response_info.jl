responseinfo(provider, timestamp) = Conversation.ResponseInfo(nothing, nothing, nothing, nothing, timestamp)
responseinfo(provider::Union{OpenAI, OpenAIResponses, Anthropic, Google}, timestamp) = Conversation.ResponseInfo(nothing, responseapi(provider), responseroute(provider.route), provider.model, timestamp)
responseapi(::OpenAI) = "openai-completions"
responseapi(::OpenAIResponses) = "openai-responses"
responseapi(::Anthropic) = "anthropic-messages"
responseapi(::Google) = "google-generative-ai"
responseroute(::DirectRoute) = nothing
responseroute(route::CatalogRoute) = route.name
