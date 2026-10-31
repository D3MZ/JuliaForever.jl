using Test, JuliaForever

function history_validation(args)
    mktemp() do path, io
        status = redirect_stderr(io) do
            JuliaForever.main(args)
        end
        flush(io)
        seekstart(io)
        (; status, diagnostics=read(io, String))
    end
end
