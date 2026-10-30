using Test, JuliaForever

ENV["PI_CODING_AGENT_DIR"] = mktempdir()
ENV["JF_OPENROUTER_DIR"] = joinpath(mktempdir(), "openrouter")

include("credential_storage.jl")
include("quality.jl")
include("skill_resume.jl")
include("skill_resume_race.jl")
include("skill_resume_rpc.jl")
include("rpc_switch_active.jl")
include("rpc_cross_provider.jl")
include("rpc_parent_session.jl")
include("skill_resume_user.jl")
include("skill_resume_terminal.jl")
include("branch_audit.jl")
include("dispatch_lint.jl")
include("model_startup.jl")
include("dispatch.jl")
include("integration_dispatch.jl")
include("instructions.jl")
include("instructions_cli.jl")
include("instructions_failure.jl")

@testset "file tools" begin
    mktempdir() do dir
        writer = Write(dir)
        reader = Read(dir)
        editor = Edit(dir)
        @test execute(writer, (; path="nested/a.txt", content="one\ntwo\nthree\n")).text == "Successfully wrote to nested/a.txt"
        @test execute(reader, (; path="nested/a.txt")).text == "one\ntwo\nthree\n"
        @test execute(reader, (; path="nested/a.txt", offset=2, limit=1)).text == "two\n\n[2 more lines in file. Use offset=3 to continue.]"
        @test execute(editor, (; path="nested/a.txt", edits=[(; oldText="two", newText="TWO")])).text == "Successfully replaced 1 block(s) in nested/a.txt."
        @test read(joinpath(dir, "nested/a.txt"), String) == "one\nTWO\nthree\n"
        @test execute(writer, (; path="duplicate.txt", content="x x")).iserror == false
        @test execute(editor, (; path="duplicate.txt", edits=[(; oldText="x", newText="y")])).iserror
        @test read(joinpath(dir, "duplicate.txt"), String) == "x x"
        @test execute(editor, (; path="duplicate.txt", edits=[(; oldText="missing", newText="y")])).iserror
        @test read(joinpath(dir, "duplicate.txt"), String) == "x x"
        @test execute(writer, (; path="overlap.txt", content="abcdef")).iserror == false
        @test execute(editor, (; path="overlap.txt", edits=[(; oldText="abc", newText="x"), (; oldText="cde", newText="y")])).iserror
        @test read(joinpath(dir, "overlap.txt"), String) == "abcdef"
    end
end

include("image.jl")
include("image_stream.jl")
include("file_images.jl")

include("edit.jl")
include("file_mutations.jl")

mutable struct Scripted
    responses::Vector{Any}
    requests::Vector{Any}
end

function JuliaForever.complete(provider::Scripted, messages, tools)
    push!(provider.requests, deepcopy(messages))
    popfirst!(provider.responses)
end

@testset "agent loop" begin
    mktempdir() do dir
        toolcall = Dict("id" => "call-1", "type" => "function", "function" => Dict("name" => "write", "arguments" => "{\"path\":\"a.txt\",\"content\":\"hello\"}"))
        provider = Scripted([Dict("role" => "assistant", "content" => nothing, "tool_calls" => [toolcall]), Dict("role" => "assistant", "content" => "done")], [])
        agent = Agent(provider, [Write(dir), Read(dir), Edit(dir)])
        @test respond!(agent, "create a file") == "done"
        @test read(joinpath(dir, "a.txt"), String) == "hello"
        @test length(provider.requests) == 2
        @test provider.requests[2][end]["role"] == "tool"
        @test provider.requests[2][end]["tool_call_id"] == "call-1"
        @test provider.requests[2][end]["content"] == "Successfully wrote to a.txt"
        @test [message["role"] for message in agent.messages] == ["user", "assistant", "tool", "assistant"]
    end
end

include("agent_core.jl")
include("parallel_recorded.jl")
include("parallel_cli.jl")
include("continuation_slice.jl")
include("extensions.jl")
include("queue.jl")
include("tool_faults.jl")
include("terminal.jl")
include("json_cli.jl")
include("terminal_live_queue.jl")
include("terminal_plugins.jl")
include("editor.jl")
include("command_completion.jl")
include("file_completion.jl")
include("model_completion.jl")
include("prompt_history.jl")
include("terminal_markdown.jl")
include("terminal_http.jl")
include("terminal_history.jl")
include("cli_recovery_dispatch.jl")
include("terminal_models.jl")
include("thinking_cli.jl")
include("google_thinking.jl")
include("google_budget_thinking.jl")
include("google_thinking_rpc.jl")
include("anthropic_thinking.jl")
include("anthropic_rpc.jl")
include("anthropic_eager_integration.jl")
include("anthropic_context.jl")
include("thinking_update.jl")
include("tool_options.jl")
include("file_arguments.jl")
include("file_cli_loopback.jl")
include("session_catalog.jl")
include("windows_alias_catalog.jl")
include("windows_case_catalog.jl")
include("session_cli.jl")
include("skill_refresh.jl")
include("skill_commands.jl")
include("skill_reload.jl")
include("skill_reload_pty.jl")
include("session_resume.jl")
include("session_corrupt.jl")
include("session_queues.jl")
include("session_reasoning_estimate.jl")
include("session_name_unit.jl")
include("session_names.jl")
include("fork_history.jl")
include("fork_queue.jl")
include("fork_cli.jl")
include("tree_history.jl")
include("tree_cli.jl")

include("provider.jl")
include("provider_status.jl")
include("provider_stream.jl")
include("provider_reasoning.jl")
include("provider_cancel.jl")
include("openrouter_callback.jl")
include("openrouter_persistence.jl")
include("provider_responses.jl")
include("provider_anthropic.jl")
include("provider_google.jl")
include("provider_image_boundary.jl")
include("provider_image_agent.jl")
if Sys.isunix()
    include("chatgpt_identity.jl")
    include("chatgpt_callback.jl")
    include("chatgpt_exchange.jl")
    include("chatgpt_plan.jl")
    include("headless_chatgpt.jl")
    include("chatgpt_store.jl")
    include("chatgpt_recovery.jl")
    include("chatgpt_cas.jl")
    include("chatgpt_cli.jl")
    include("chatgpt_ui.jl")
end
include("provider_invalid.jl")
include("provider_error_common.jl")
include("provider_error_extra.jl")
include("estimates.jl")
include("model_overlays_cli.jl")
include("model_alias_cli.jl")
include("model_validation.jl")

if haskey(ENV, "PI_SOURCE")
    include("headless_differential.jl")
    include("estimates_differential.jl")
    include("prompt_differential.jl")
    include("model_catalog_differential.jl")
    include("model_overlays.jl")
    include("skills_differential.jl")
    include("skill_visibility.jl")
    include("skill_reload_differential.jl")
    include("instructions_differential.jl")
    include("context_differential.jl")
    include("agent_core_differential.jl")
    include("extensions_differential.jl")
    include("queue_differential.jl")
    include("differential.jl")
    include("image_differential.jl")
    include("file_mutations_differential.jl")
end

include("system.jl")
include("durable.jl")
include("durable_replay_dispatch.jl")
include("durable_forks.jl")
include("durable_policy_forks.jl")
include("durable_policy_replay.jl")
include("durable_dispatch.jl")
include("durable_documents.jl")
if haskey(ENV, "PI_SOURCE")
    include("durable_document_differential.jl")
end
include("history.jl")
include("session.jl")
include("kernel.jl")
include("conversation.jl")
include("agent_machine.jl")
include("agent_history.jl")
include("compaction.jl")
include("auto_compaction.jl")
include("auto_boundary.jl")
include("overflow.jl")
include("compaction_cli.jl")
include("compaction_usage.jl")
include("terminal_auto_compaction.jl")
include("pre_compaction.jl")
include("tool_compaction.jl")
include("compaction_edit.jl")
include("headless_auto_compaction.jl")
include("mixed_session_entries.jl")
include("manual_text_history.jl")
include("codec_dispatch.jl")
include("abandon.jl")
include("sqlite_history.jl")
include("execution.jl")
include("kernel_execution.jl")
include("conversation_execution.jl")
include("agent_execution.jl")
include("recorded_execution.jl")
include("recorded_journal.jl")
include("logs.jl")
include("session_export.jl")
include("terminal_export.jl")
include("session_info.jl")
include("model_cost.jl")
include("search.jl")
include("search_bom.jl")
include("tool_search.jl")
include("codemode.jl")
include("codemode_cleanup.jl")
include("codemode_store.jl")
include("codemode_compat.jl")
include("mcp.jl")
include("mcp_image.jl")
include("image_formats.jl")
include("image_switch_rpc.jl")
include("mcp_resources.jl")
module MCPWriteRaceTests
include("mcp_write_race.jl")
end
module MCPProgressTests
include("mcp_progress_native.jl")
end
module MCPProgressHTTPTests
include("mcp_progress_http.jl")
end
module MCPHTTPTests
include("mcp_http.jl")
end
module MCPFractionalTests
include("mcp_fractional.jl")
end
module MCPHTTPSSETests
include("mcp_http_sse.jl")
end
module MCPWireJSONTests
include("mcp_wire_json.jl")
include("mcp_http_batch.jl")
include("mcp_stdio_limit.jl")
end
module MCPPOSTSSETests
include("mcp_post_sse.jl")
end
module MCPSSEBoundaryTests
include("mcp_sse_boundaries.jl")
end
module MCPHTTPGETTests
include("mcp_http_get.jl")
end
module MCPReconnectTests
include("mcp_reconnect.jl")
end
module MCPHTTPLifecycleTests
include("mcp_http_lifecycle.jl")
end
if haskey(ENV, "PI_SOURCE")
    include("tool_search_differential.jl")
    include("mcp_differential.jl")
    include("mcp_progress.jl")
    include("mcp_resources_differential.jl")
    include("mcp_roots_differential.jl")
    include("fullscreen_differential.jl")
end
include("scheduler.jl")
include("json_content.jl")
if haskey(ENV, "PI_SOURCE")
    include("durable_forks_differential.jl")
    include("session_differential.jl")
    include("compaction_differential.jl")
    include("auto_compaction_differential.jl")
    include("session_migration.jl")
    include("system_differential.jl")
    include("system_stream_differential.jl")
    mktempdir() do oracle
        withenv("PI_CODING_AGENT_DIR" => oracle) do
            include("search_differential.jl")
            include("search_crlf_differential.jl")
            include("search_bytes_differential.jl")
            include("search_bom_differential.jl")
        end
    end
end

include("extension_interception.jl")
include("before_tool.jl")
include("tool_termination.jl")
