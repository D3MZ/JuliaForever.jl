using Dates
using Printf

function read_history(path)
    section = ""
    fields = Dict{String,Int}()
    rows = Vector{Vector{Int}}()
    in_project = false
    open(path) do io
        for line in eachline(io)
            if in_project
                if startswith(line, "    ")
                    values = split(strip(line))
                    isempty(values) && continue
                    row = [parse(Int, value) for value in values]
                    any(value -> value < 0, row) && error("Negative Hercules line count")
                    isempty(rows) || length(row) == length(first(rows)) || error("Non-rectangular Hercules matrix")
                    push!(rows, row)
                    continue
                end
                in_project = false
            end
            if line == "hercules:"
                section = "hercules"
            elseif line == "Burndown:"
                section = "burndown"
            elseif section == "burndown" && occursin(r"^  \"?project\"?: \|-\s*$", line)
                in_project = true
            else
                field = match(r"^  (begin_unix_time|granularity|sampling|tick_size):\s*(-?\d+)\s*$", line)
                if field !== nothing
                    key = String(field.captures[1])
                    if (section == "hercules" && key == "begin_unix_time") ||
                       (section == "burndown" && key != "begin_unix_time")
                        fields[key] = parse(Int, field.captures[2])
                    end
                end
            end
        end
    end
    get(fields, "tick_size", 0) == 3600 && get(fields, "granularity", 0) == 1 &&
        get(fields, "sampling", 0) == 1 || error("Expected hourly Hercules cohorts and snapshots")
    haskey(fields, "begin_unix_time") || error("Hercules did not report a start time")
    isempty(rows) && error("Hercules did not report project history")
    isempty(first(rows)) && error("Hercules reported an empty matrix")
    origin = unix2datetime(fld(fields["begin_unix_time"], 3600) * 3600)
    origin, rows
end

const COLORS = [(0x75, 0x71, 0xf9), (0x35, 0x99, 0xe8), (0x02, 0xcf, 0x92),
                (0xc5, 0xd9, 0x59), (0xf5, 0xab, 0x57), (0xf7, 0x80, 0xe2)]

function cohort_color(index, count)
    t = count <= 1 ? 0.0 : (index - 1) / (count - 1)
    position = t * (length(COLORS) - 1)
    i = min(floor(Int, position) + 1, length(COLORS) - 1)
    fraction = position - (i - 1)
    rgb = ntuple(k -> round(Int, (1 - fraction) * COLORS[i][k] + fraction * COLORS[i + 1][k]), 3)
    @sprintf("#%02x%02x%02x", rgb...)
end

commas(n::Integer) = replace(string(n), r"(?<=\d)(?=(\d{3})+(?!\d))" => ",")
coordinate(x) = @sprintf("%.2f", x)

function chart(io, origin, rows)
    count, cohorts = length(rows), length(first(rows))
    totals = [sum(row) for row in rows]
    final = last(totals)
    ymax = max(1, maximum(totals))
    left, right, top, bottom = 108.0, 1138.0, 170.0, 444.0
    x(edge) = left + (right - left) * edge / count
    y(lines) = bottom - (bottom - top) * lines / ymax
    date(time) = Dates.format(time, dateformat"u dd  HH:MM")

    println(io, """<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="650" viewBox="0 0 1200 650" role="img" aria-labelledby="title desc">
<title id="title">Julia code history</title>
<desc id="desc">Stacked hourly cohorts of surviving Julia lines along the first-parent Git history.</desc>
<defs><linearGradient id="cohorts">""")
    for i in eachindex(COLORS)
        color = cohorts == 1 ? cohort_color(1, 1) : cohort_color(i, length(COLORS))
        @printf(io, "<stop offset=\"%.2f%%\" stop-color=\"%s\"/>\n", 100 * (i - 1) / (length(COLORS) - 1), color)
    end
    println(io, """</linearGradient></defs>
<rect width="1200" height="650" fill="#20232b"/>
<g font-family="-apple-system,BlinkMacSystemFont,Segoe UI,DejaVu Sans,sans-serif">
<text x="108" y="64" fill="#c9c8ff" font-size="30" font-weight="700">Julia code history</text>
<text x="108" y="96" fill="#a6abb8" font-size="15">Surviving lines by the hour they were last changed</text>
<text x="1138" y="64" text-anchor="end" fill="#e4e5eb" font-size="26" font-weight="700">$(commas(final)) lines</text>
<text x="1138" y="96" text-anchor="end" fill="#a6abb8" font-size="14">latest committed snapshot</text>""")

    for value in unique(round.(Int, range(0, ymax; length=min(5, ymax + 1))))
        yy = coordinate(y(value))
        println(io, "<path d=\"M$(coordinate(left)) $yy H$(coordinate(right))\" stroke=\"#3a3e49\" stroke-width=\"1\"/>")
        println(io, "<text x=\"92\" y=\"$yy\" text-anchor=\"end\" dominant-baseline=\"middle\" fill=\"#a6abb8\" font-size=\"13\">$(commas(value))</text>")
    end

    lower = zeros(Int, count)
    for cohort in 1:cohorts
        values = [row[cohort] for row in rows]
        first_live = findfirst(!iszero, values)
        first_live === nothing && continue
        last_live = findlast(!iszero, values)
        upper = lower .+ values
        print(io, "<path fill=\"$(cohort_color(cohort, cohorts))\" d=\"M$(coordinate(x(first_live - 1))) $(coordinate(y(upper[first_live])))")
        for i in first_live:last_live
            if i == last_live || upper[i] != upper[i + 1]
                print(io, " H$(coordinate(x(i)))")
                i < last_live && print(io, " V$(coordinate(y(upper[i + 1])))")
            end
        end
        print(io, " L$(coordinate(x(last_live))) $(coordinate(y(lower[last_live])))")
        for i in last_live:-1:first_live
            if i == first_live || lower[i] != lower[i - 1]
                print(io, " H$(coordinate(x(i - 1)))")
                i > first_live && print(io, " V$(coordinate(y(lower[i - 1])))")
            end
        end
        println(io, " Z\"/>")
        lower = upper
    end

    for hour in unique(round.(Int, range(0, count; length=min(5, count + 1))))
        xx = x(hour)
        anchor = hour == 0 ? "start" : hour == count ? "end" : "middle"
        println(io, "<text x=\"$(coordinate(xx))\" y=\"473\" text-anchor=\"$anchor\" fill=\"#a6abb8\" font-size=\"13\">$(date(origin + Hour(hour)))</text>")
    end
    println(io, """<text x="108" y="529" fill="#c5c8d2" font-size="13" font-weight="700" letter-spacing="1">COHORT · LAST CHANGED</text>
<rect x="108" y="546" width="1030" height="12" rx="6" fill="url(#cohorts)"/>
<text x="108" y="581" fill="#a6abb8" font-size="13">$(date(origin)) UTC</text>
<text x="1138" y="581" text-anchor="end" fill="#a6abb8" font-size="13">$(date(origin + Hour(cohorts - 1))) UTC</text>
<text x="108" y="623" fill="#8f95a3" font-size="13">Hercules · first-parent history · Julia files, including tests · end-of-hour snapshots</text>
</g></svg>""")
    final
end

function main(args)
    length(args) == 2 || error("Usage: julia scripts/render_history.jl HERCULES_REPORT OUTPUT.svg")
    origin, rows = read_history(args[1])
    mkpath(dirname(abspath(args[2])))
    final = open(io -> chart(io, origin, rows), args[2], "w")
    println("Rendered $(commas(final)) committed Julia lines across $(length(rows)) hourly snapshots to $(args[2]).")
end

main(ARGS)
