using TPlot

# A warmed, dependency-free check of render cost. Output goes to a reusable buffer.
function benchmark(; samples=50)
    x = range(-1.0, 1.0; length=128)
    phi = [hypot(a, b) - 0.6 for a in x, b in x]
    t = collect(range(0.0, 10.0; length=1000))
    dashboard = Row(Geometry(phi; field=phi),
        Column(Curves(t, sin.(t); title="sine"),
               Curves(t, 10cos.(t); title="cosine")))
    buffer = IOBuffer()
    io = IOContext(buffer, :terminal => true)
    frame() = (truncate(buffer, 0); seekstart(buffer);
               render(dashboard; io, size=(40, 120)))
    for _ in 1:5
        frame()
    end
    times = sort([@elapsed frame() for _ in 1:samples])
    bytes = @allocated frame()
    println("median render: ", round(1000times[cld(samples, 2)]; digits=3), " ms")
    println("allocation: ", bytes, " bytes/frame")
    return times, bytes
end

abspath(PROGRAM_FILE) == (@__FILE__) && benchmark()
