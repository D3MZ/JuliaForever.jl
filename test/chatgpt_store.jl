using JSON3, HTTP

function fixturelock(path)
    file = Base.Filesystem.open(path, Base.Filesystem.JL_O_CREAT | Base.Filesystem.JL_O_RDWR | Base.Filesystem.JL_O_NOFOLLOW, 0o600)
    ccall(:flock, Cint, (Cint, Cint), Base.fd(file), 6) == 0 || error("fixture lock failed")
    file
end
