using Test, JuliaForever, JSON3
const MCP = JuliaForever.MCP

if haskey(ENV, "PI_SOURCE")
    @testset "Pi MCP failed write while stdout remains open" begin
        source = ENV["PI_SOURCE"]
        @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
        for timeout in ("zero", "inf")
            mktempdir() do dir
                holdfile, readyfile, stopfile = joinpath.((dir,), ("hold", "ready", "stop"))
                script = joinpath(@__DIR__, "mcp_write_race_pi.mjs")
                project = joinpath(dir, "project")
                mkpath(project)
                active = dirname(Base.active_project())
                cp(joinpath(active, "Project.toml"), joinpath(project, "Project.toml"))
                manifest = joinpath(active, "Manifest.toml")
                isfile(manifest) && cp(manifest, joinpath(project, "Manifest.toml"))
                reference = JSON3.read(read(`node $script $source $(first(Base.julia_cmd().exec)) $project $holdfile $readyfile $stopfile $timeout`, String), Dict{String, Any})
                @test reference["outcome"] == "failed"
                @test reference["buffered"] == Dict("result" => Dict("done" => true))
                @test reference["waiting"] == "pending" && reference["closed"] == Dict("failed" => true)
            end
        end
    end
end
