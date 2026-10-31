using Sockets

Base.cumulative_compile_timing(true)
server = listen(ip"127.0.0.1", 0)
open(ENV["JF_UI_COMPILE_PORT"], "w") do io
    println(io, getsockname(server)[2])
end
@async while isopen(server)
    client = accept(server)
    compile, recompile = Base.cumulative_compile_time_ns()
    println(client, compile, ' ', recompile)
    flush(client)
    close(client)
end

using JuliaForever
exit(JuliaForever.main(ARGS))
