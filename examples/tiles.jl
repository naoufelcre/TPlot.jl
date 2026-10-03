using TPlot

# Run with: julia --project=TPlot.jl TPlot.jl/examples/tiles.jl
function demo(; frames=100, delay=0.05, io=stdout)
    x = collect(range(-1.0, 1.0; length=96))
    phi = [hypot(a, b) - 0.5 for a in x, b in x]
    field = [a + b for a in x, b in x]
    t, area, radius = Float64[], Float64[], Float64[]
    dashboard = Row(
        Geometry(phi; field, colorrange=(-2.0, 2.0), title="moving region"),
        Column(
            Curves(t, area; title="area", yrange=(0.0, 2.0), labels=["πr²"]),
            Curves(t, radius; title="radius", yrange=(0.0, 1.0), labels=["r"])),
        weights=(1, 1))
    for step in 1:frames
        r = 0.5 + 0.2sin(step / 10)
        for j in eachindex(x), i in eachindex(x)
            phi[i, j] = hypot(x[i], x[j]) - r
        end
        push!(t, step)
        push!(area, pi * r^2)
        push!(radius, r)
        render(dashboard; io, label="step $step — resize the terminal")
        delay > 0 && sleep(delay)
    end
    return dashboard
end

abspath(PROGRAM_FILE) == (@__FILE__) && demo()
