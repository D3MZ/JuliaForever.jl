using Test, JuliaForever, Base64

@testset "read non-seekable inputs" begin
    if Sys.isunix()
        mktempdir() do dir
            fifo = joinpath(dir, "pipe")
            run(`mkfifo $fifo`)
            source = joinpath(dir, "source")
            script = raw"cat \"$1\" > \"$2\""
            reader = Read(dir)
            function frompipe(bytes)
                write(source, bytes)
                writer = run(`sh -c $script fixture $source $fifo`; wait=false)
                result = try
                    execute(reader, (; path="pipe"))
                catch exception
                    exception
                end
                wait(writer)
                @test success(writer)
                result
            end
            for content in ("ordinary text\n", "R" * repeat("x", 30) * "🐈 tail\n", "")
                result = frompipe(content)
                @test result isa ToolResult
                if result isa ToolResult
                    @test !result.iserror
                    @test result.text == content
                    @test result.image === nothing
                end
            end
            image = read(joinpath(@__DIR__, "fixtures", "pixel.png"))
            result = frompipe(image)
            @test result isa ToolResult
            if result isa ToolResult
                @test !result.iserror
                @test result.image.mime == "image/png"
                @test base64decode(result.image.data) == image
            end
            for file in ("animated.gif", "animated.webp")
                bytes = read(joinpath(@__DIR__, "fixtures", file))
                streamed = frompipe(bytes)
                @test !streamed.iserror && base64decode(streamed.image.data) == bytes
            end
            boundary = [image; zeros(UInt8, 10 * 1024 * 1024 - length(image))]
            result = frompipe(boundary)
            @test result isa ToolResult
            if result isa ToolResult
                @test !result.iserror
                @test result.image.mime == "image/png"
                @test base64decode(result.image.data) == boundary
            end
            oversized = [image; zeros(UInt8, 10 * 1024 * 1024 + 1 - length(image))]
            result = frompipe(oversized)
            @test result isa ToolResult
            if result isa ToolResult
                @test result.iserror
                @test result.image === nothing
                @test occursin("10 MiB", result.text)
            end
        end
    end
end
