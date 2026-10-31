function shellfixture(dir, id)
    gate = "gate-$id"
    run(`mkfifo $(joinpath(dir, gate))`)
    write(joinpath(dir, "grandchild-$id.sh"), "printf '%s' \"\$\$\" > grandchild-$id\nprintf ready > ready-$id\nread -r < $gate\nprintf late > late-$id\n")
    write(joinpath(dir, "child-$id.sh"), "printf '%s' \"\$\$\" > child-$id\nbash grandchild-$id.sh &\nwait\n")
    "printf '%s' \"\$\$\" > leader-$id; printf before; bash child-$id.sh & wait"
end

function shellpids(dir, id)
    [parse(Int, read(joinpath(dir, "$name-$id"), String)) for name in ("leader", "child", "grandchild")]
end

function gone(pid)
    ccall(:kill, Cint, (Cint, Cint), pid, 0) == -1 && Base.Libc.errno() == Base.Libc.ESRCH
end
