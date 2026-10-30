using JuliaForever

directory, commandfile = ARGS
execute(PowerShell(directory), (; command=read(commandfile, String), timeout=60))
