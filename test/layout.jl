# Layout.jl tests -- nested terminal tiling (Row/Column trees of Geometry/Curves).
using Test
using TPlot

# ---- local helpers ----------------------------------------------------------

const _ANSI = r"\x1b\[[0-9;]*[A-Za-z]"

_rowcount(s) = countlines(IOBuffer(s))
_dw(s) = TPlot._display_width(s)

# Returns true when the last SGR sequence on a line is not a reset.
function _active_color(line)
    active = false
    for m in eachmatch(r"\x1b\[[0-9;]*m", line)
        active = m.match != "\e[0m"
    end
    return active
end

function _render_str(node; size=nothing, tty=false, label=nothing)
    buf = IOBuffer()
    io = tty ? IOContext(buf, :terminal => true) : buf
    @test render(node; io=io, size=size, label=label) === nothing
    return String(take!(buf))
end

_phi() = [-1.0 1.0; 1.0 -1.0]
_t() = collect(0.0:0.1:1.0)
_sin() = sin.(_t())
_cos() = cos.(_t())

# ---- weighted allocation primitives ----------------------------------------

@testset "weighted allocation" begin
    @test TPlot._allocate(40, 2, nothing) == [20, 20]
    @test TPlot._allocate(40, 2, (3.0, 1.0)) == [30, 10]
    @test TPlot._allocate(41, 3, (1.0, 1.0, 1.0)) == [14, 14, 13]
    @test sum(TPlot._allocate(41, 3, (1.0, 1.0, 1.0))) == 41
    @test TPlot._allocate(2, 4, nothing) == [1, 1, 0, 0]
    @test TPlot._allocate(-5, 3, nothing) == [0, 0, 0]
    @test TPlot._allocate(10, 0, nothing) == Int[]
end

# ---- tile halves: geometry left, curves right ------------------------------

@testset "row tiles halves" begin
    node = Row(Geometry(_phi()), Curves(_t(), _sin()); weights=(1, 1))
    out = _render_str(node; size=(12, 40))
    @test _rowcount(out) == 12
    @test all(l -> _dw(l) <= 40, split(out, '\n'))
    @test occursin("φ ≤ 0", out)
    @test occursin("trace", out)
    # The curves tile starts in the right half of the frame.
    title_row = split(out, '\n')[1]
    @test findfirst("trace", title_row).start > 20
end

# ---- stacked independent axes ----------------------------------------------

@testset "column stacks independent curves" begin
    t = _t()
    low = sin.(t)          # y in [-1, 1]
    high = 100 .* cos.(t)  # y in [-100, 100]
    node = Column(Curves(t, low; title="LOW"), Curves(t, high; title="HIGH"))
    out = _render_str(node; size=(16, 30))
    @test _rowcount(out) == 16
    @test all(l -> _dw(l) <= 30, split(out, '\n'))
    # Each panel computes its own y axis from its own data.
    @test occursin("100.00", out)
    @test occursin("1.00", out)
    # LOW renders before HIGH.
    @test findfirst("LOW", out).start < findfirst("HIGH", out).start
end

# ---- required mixed nesting ------------------------------------------------

@testset "half geometry plus stacked curves" begin
    t = _t()
    node = Row(Geometry(_phi()), Column(Curves(t, sin.(t)), Curves(t, cos.(t)));
        weights=(1, 1))
    out = _render_str(node; size=(20, 80))
    @test _rowcount(out) == 20
    @test all(l -> _dw(l) <= 80, split(out, '\n'))
    @test occursin("φ ≤ 0", out)
    # Two independent curve panels -> two legends.
    @test count("series 1", out) == 2
end

# ---- weighted split is visible end to end ----------------------------------

@testset "weighted row" begin
    node = Row(Curves(_t(), _sin(); title="L"), Curves(_t(), _cos(); title="R");
        weights=(3, 1))
    out = _render_str(node; size=(10, 80))
    @test _rowcount(out) == 10
    lcol = findfirst("L", split(out, '\n')[1]).start
    rcol = findfirst("R", split(out, '\n')[1]).start
    @test lcol < rcol
    @test rcol > 40   # narrower right tile begins past the midpoint
end

# ---- resizing / strict bounds across many sizes ----------------------------

@testset "size bounded across resizes" begin
    node = Row(Geometry(_phi()), Column(Curves(_t(), _sin()), Curves(_t(), _cos()));
        weights=(1, 1))
    for (r, c) in ((4, 10), (8, 24), (12, 44), (24, 80), (1, 1), (2, 3), (1, 40), (40, 1))
        out = _render_str(node; size=(r, c))
        @test _rowcount(out) <= r
        @test all(l -> _dw(l) <= c, split(out, '\n'))
    end
    # displaysize is honoured when size is omitted.
    buf = IOBuffer()
    io = IOContext(buf, :displaysize => (6, 20))
    render(node; io=io)
    out = String(take!(buf))
    @test _rowcount(out) == 6
    @test all(l -> _dw(l) <= 20, split(out, '\n'))
end

# ---- container extent invariants after dropping the redundant refits -------

@testset "container extent invariants" begin
    t = _t()
    uneven = Row(Curves(t, sin.(t); title="A"), Curves(t, cos.(t); title="B");
        weights=(1, 3))
    nested = Column(Row(Geometry(_phi()), Curves(t, sin.(t)); weights=(2, 1)),
        Curves(t, cos.(t)); weights=(1, 2))
    # Uneven weights, nested Column(Row), tiny and zero dims, TTY and plain.
    exact = true
    for (r, c) in ((10, 41), (3, 5), (2, 3), (0, 7), (0, 0))
        for tty in (false, true), node in (uneven, nested)
            out = _render_str(node; size=(r, c), tty=tty)
            w = tty ? max(c - 1, 0) : c
            ls = split(chomp(out), '\n')
            exact &= _rowcount(out) == r
            exact &= all(l -> _dw(l) <= w, split(out, '\n'))
            r > 0 && (exact &= all(l -> _dw(l) == w, ls))
        end
    end
    # Children fill the allocation and widths+gaps sum to the parent extent,
    # so every emitted row is exactly the parent width/height (no refit needed).
    @test exact
    # Independent per-panel y axes survive the refit removal.
    axes = Column(Curves(t, sin.(t); title="LOW"),
        Curves(t, 100 .* cos.(t); title="HIGH"))
    out = _render_str(axes; size=(16, 30))
    @test occursin("LOW", out) && occursin("HIGH", out)
    @test occursin("100.00", out) && occursin("1.00", out)
end

# ---- tiny dimensions never throw -------------------------------------------

@testset "tiny dimensions" begin
    node = Column(Curves(_t(), _sin()), Curves(_t(), _cos()))
    for (r, c) in ((0, 0), (1, 1), (2, 2), (3, 5), (5, 1), (1, 30))
        out = _render_str(node; size=(r, c))
        @test _rowcount(out) <= r
        @test all(l -> _dw(l) <= c, split(out, '\n'))
    end
end

# ---- TTY vs plain ----------------------------------------------------------

@testset "tty ansi versus plain" begin
    node = Geometry(_phi(); field=vec([1.0, 2.0, 3.0, 4.0]))
    plain = _render_str(node; size=(8, 30), tty=false)
    @test !occursin("\e[", plain)

    ttyout = _render_str(node; size=(8, 30), tty=true)
    @test startswith(ttyout, "\e[H")
    @test occursin("\e[K", ttyout)
    @test endswith(ttyout, "\e[J")
    @test occursin("\e[38;5;", ttyout)   # coloured geometry
    # Every line ends with all colours reset, and stays inside the terminal.
    for l in split(ttyout, '\n')
        @test !_active_color(l)
        @test _dw(l) <= 30
    end
    # No cursor-movement escapes: the only non-colour escapes are home/clear/eol.
    nonsgr = replace(ttyout, r"\x1b\[[0-9;]*m" => "")
    @test all(m -> m.match in ("\e[H", "\e[K", "\e[J"), eachmatch(_ANSI, nonsgr))
end

# ---- wide unicode labels ---------------------------------------------------

@testset "wide unicode text" begin
    @test TPlot._display_width("中") == 2
    @test TPlot._display_width("😀") == 2
    @test TPlot._fit_cells("中中中", 3) == "中 "
    @test _dw(TPlot._fit_cells("中中中", 3)) == 3
    @test TPlot._fit_cells("ab中", 3) == "ab "
    @test TPlot._fit_cells("abcdef", 4) == "abcd"

    lab = "宽标签😀"
    node = Curves(_t(), _sin(); title="中文标题", ylabel="标签")
    out = _render_str(node; size=(8, 20), label=lab)
    @test occursin("宽标签😀", out)
    @test occursin("中文标题", out)
    @test all(l -> _dw(l) <= 20, split(out, '\n'))
    # Full-width lines still leave the terminal's last column free on TTY.
    ttyout = _render_str(node; size=(8, 20), tty=true, label=lab)
    @test all(l -> _dw(l) <= 19, split(ttyout, '\n'))
end

# ---- user text is sanitized ------------------------------------------------

@testset "sanitize user text" begin
    @test TPlot._sanitize_text("a\nb") == "a b"
    @test TPlot._sanitize_text("x\e[31my") == "xy"
    @test TPlot._sanitize_text("tab\there") == "tab here"
    @test TPlot._sanitize_text(nothing) == ""

    node = Curves(_t(), _sin(); title="evil\e[2J\ntitle")
    out = _render_str(node; size=(8, 30))
    @test !occursin("\e[2J", out)
    @test !occursin("evil\ntitle", out)
end

# ---- invalid construction --------------------------------------------------

@testset "invalid nodes" begin
    phi = _phi()
    t = _t()
    y = _sin()
    @test_throws ArgumentError Row()
    @test_throws ArgumentError Column()
    @test_throws ArgumentError Row(Geometry(phi), 42)
    @test_throws ArgumentError Row(Geometry(phi), Curves(t, y); weights=(1.0,))
    @test_throws ArgumentError Row(Geometry(phi), Curves(t, y); weights=(1.0, 2.0, 3.0))
    @test_throws ArgumentError Row(Geometry(phi), Curves(t, y); weights=(0.0, 1.0))
    @test_throws ArgumentError Row(Geometry(phi), Curves(t, y); weights=(-1.0, 2.0))
    @test_throws ArgumentError Row(Geometry(phi), Curves(t, y); weights=(Inf, 1.0))
    @test_throws ArgumentError Row(Geometry(phi), Curves(t, y); weights=(NaN, 1.0))
    @test_throws ArgumentError Row(Geometry(phi); gap=-1)
    @test_throws ArgumentError Column(Geometry(phi); gap=-0.5)
    @test_throws ArgumentError Geometry(zeros(1, 2))
    @test_throws ArgumentError Geometry(zeros(2, 1))
    @test_throws ArgumentError Geometry(phi; cell_aspect=0.0)
    @test_throws ArgumentError Geometry(phi; cell_aspect=big"1e1000")
    @test_throws ArgumentError Row(Geometry(phi); weights=(big"1e-1000",))
    @test_throws ArgumentError Curves(t, y; xrange=(NaN, 1.0))
    @test_throws DimensionMismatch Geometry(phi; field=[1.0])
    @test_throws DimensionMismatch Geometry(phi; field=ones(1, 4))
    @test_throws ArgumentError Geometry(phi; colorrange=(0.0,))
    @test_throws ArgumentError Geometry(phi; colorrange=(Inf, 2.0))
    @test_throws DimensionMismatch Curves(t, y[1:2])
    @test_throws DimensionMismatch Curves(t, [y y]; labels=["only"])
end

@testset "panels use allocated width and bounded aspect" begin
    out = _render_str(Curves(_t(), _sin()); size=(8, 140))
    border = first(filter(l -> startswith(l, "+"), split(out, '\n')))
    @test textwidth(rstrip(border)) == 140 - 7
    for aspect in (1e308, 1e-308)
        out = _render_str(Geometry(_phi(); cell_aspect=aspect); size=(10, 40))
        @test all(l -> _dw(l) <= 40, split(out, '\n'))
    end
end

# ---- references, not copies ------------------------------------------------

@testset "input mutation reflected" begin
    M = [-1.0 1.0; 1.0 -1.0]
    g = Geometry(M)
    before = _render_str(g; size=(6, 10))
    M[1, 1] = 1.0
    M[1, 2] = -1.0
    M[2, 1] = -1.0
    M[2, 2] = 1.0
    after = _render_str(g; size=(6, 10))
    @test before != after

    t = [0.0, 1.0, 2.0]
    y = [0.0, 1.0, 0.0]
    c = Curves(t, y)
    p1 = _render_str(c; size=(8, 20))
    y[2] = 5.0
    p2 = _render_str(c; size=(8, 20))
    @test p1 != p2

    # References may grow together between frames. Nothing is cached.
    tg = [0.0, 1.0]
    a = [0.0, 1.0]
    b = [1.0, 0.0]
    cg = Curves(tg, [a, b])
    r1 = _render_str(cg; size=(9, 24))
    push!(tg, 2.0)
    push!(a, 0.0)
    push!(b, 0.0)
    r2 = _render_str(cg; size=(9, 24))
    @test r1 != r2
    @test all(l -> _dw(l) <= 24, split(r2, '\n'))
end

# ---- validation cannot be bypassed by a zero-size tile ---------------------

@testset "zero-size tile still validates" begin
    phi = _phi()
    f = collect(1.0:4.0)
    g = Geometry(phi; field=f)
    push!(f, 5.0)                       # now mismatched with phi
    node = Row(g, Curves(_t(), _sin()); weights=(1, 1))
    @test_throws DimensionMismatch render(node; io=IOBuffer(), size=(0, 0))

    t = [0.0, 1.0]
    y = [0.0, 1.0]
    c = Curves(t, y)
    push!(y, 2.0)                       # series no longer matches t
    @test_throws DimensionMismatch render(Column(c, Geometry(phi)); io=IOBuffer(), size=(0, 0))
end

# ---- C1 controls and mutable labels ----------------------------------------

@testset "C1 controls and mutable labels" begin
    # U+009B is an 8-bit CSI. It must not survive sanitization.
    @test TPlot._sanitize_text("\u009b2J") == " 2J"
    @test !occursin("\u009b", TPlot._sanitize_text("a\u009bmb"))

    # Labels live in a caller-owned vector and may be mutated after construction.
    c = Curves(_t(), _sin(); labels=["good"])
    @test occursin("good", _render_str(c; size=(8, 30)))
    c.labels[1] = "evil\u009b2J\e[31mx"
    out = _render_str(c; size=(8, 30))
    @test !occursin("\u009b", out)
    @test !occursin("\e[31m", out)
    @test occursin("evil", out)
end

# ---- reset-safe weights and gaps -------------------------------------------

@testset "extreme weights and gaps" begin
    # Both weights near Float64max: normalization must avoid Inf/NaN.
    @test TPlot._allocate(80, 2, (1.0e308, 1.0e308)) == [40, 40]
    b = TPlot._allocate(80, 2, (1.0e308, 5.0e307))
    @test sum(b) == 80 && !any(isnan, b)
    @test !any(isinf, Float64.(b))

    # Huge (finite) weights construct and render without overflow.
    node = Row(Curves(_t(), _sin()), Curves(_t(), _cos()); weights=(1.0e308, 1.0e308))
    @test all(l -> _dw(l) <= 40, split(_render_str(node; size=(8, 40)), '\n'))

    # Gap must be an integer, not silently rounded.
    phi = _phi()
    @test_throws ArgumentError Row(Geometry(phi), Curves(_t(), _sin()); gap=0.5)
    @test_throws ArgumentError Row(Geometry(phi), Curves(_t(), _sin()); gap=2.9)

    # A giant gap with a tiny terminal must not allocate a giant space run.
    big = Row(Curves(_t(), _sin()), Curves(_t(), _cos()); gap=1_000_000_000)
    tiny = _render_str(big; size=(3, 5))
    @test _rowcount(tiny) <= 3
    @test all(l -> _dw(l) <= 5, split(tiny, '\n'))
end

# ---- frame size validation -------------------------------------------------

@testset "frame size validation" begin
    node = Curves(_t(), _sin())
    for bad in ((-1, 10), (10, -1), (10, 10.0), (10.5, 10), (10,), (10, 20, 30), "10x20")
        @test_throws ArgumentError render(node; io=IOBuffer(), size=bad)
    end
    # Zero rows with a label must emit no content row at all.
    @test _render_str(node; size=(0, 20), label="hello") == ""
    @test _render_str(node; size=(0, 0)) == ""
    # Repeated plain renders are newline-terminated, so they do not concatenate.
    s = _render_str(node; size=(6, 20))
    @test endswith(s, '\n')
    @test _rowcount(s) == 6
    # TTY uses CRLF between rows and no trailing newline.
    t = _render_str(node; size=(6, 20), tty=true)
    @test occursin("\r\n", t)
    @test !endswith(t, '\n')
    @test _rowcount(t) == 6
end

# ---- all-NaN fields and explicit ranges on zero tiles ----------------------

@testset "ranges and NaN field validated at zero size" begin
    phi = _phi()
    @test_throws ArgumentError Geometry(phi; field=fill(NaN, 4))

    f = [1.0, 2.0, 3.0, 4.0]
    g = Geometry(phi; field=f)
    f .= NaN
    @test_throws ArgumentError render(g; io=IOBuffer(), size=(0, 0))

    # xrange stored by reference: mutating it to invalid is caught at render.
    xr = [0.0, 1.0]
    c = Curves([0.0, 1.0], [0.0, 1.0]; xrange=xr)
    xr[1] = NaN
    @test_throws ArgumentError render(c; io=IOBuffer(), size=(0, 0))

    # t must be real. NaN entries are real and remain allowed.
    @test_throws ArgumentError Curves(["a", "b"], [1.0, 2.0])
    @test Curves([NaN, 1.0], [1.0, 2.0]) isa Curves
end
