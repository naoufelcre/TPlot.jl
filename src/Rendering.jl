# Rendering.jl -- generic terminal rendering primitives for TPlot.
#
# This file is included by src/TPlot.jl. It has no dependencies beyond Printf.
# Everything here operates on plain arrays:
#   * a geometry is an AbstractMatrix{<:Real} of level-set samples, shape (nx, ny)
#     with one-based axes and at least two nodes per dimension.
#   * a field is either a matching matrix or a vector in column-major order.
#   * a curve is any real vector, or a vector of real vectors, or a matrix whose
#     columns are the series.
#
# The `_*_rows` helpers return vectors of strings (rows). Rows may contain ANSI
# SGR color sequences, but never screen clears or cursor controls, so the layout
# layer can compose them into tiles and own the framing. The legacy public API
# (`plot`, `plot_geometry`, `plot_curves`) at the bottom keeps the original
# TerminalPlot output contracts and does its own framing.

# ANSI approximations of Julia's purple, blue, green, and red logo colors.
const FIELD_COLORS = (54, 55, 56, 57, 63, 69, 75, 81, 80, 79, 78, 77, 76,
    112, 148, 184, 220, 214, 208, 202, 196)

# Curve palette sampled from the field ramp, so a field and its summary curves
# read as one visual system. Order: min, avg, max, then cycling.
const CURVE_COLORS = (FIELD_COLORS[4], FIELD_COLORS[11], FIELD_COLORS[19])
const CURVE_GLYPHS = ('*', '+', 'x', 'o', '#', '@')
const MIN_CURVE_WIDTH = 30
const MAX_CURVE_WIDTH = 60
const COLORBAR_WIDTH = 10

_istty(io::IO) = io isa Base.TTY || get(io, :terminal, false)

function _clean_label(label, columns::Int)
    isnothing(label) && return nothing
    return join(Iterators.take(_sanitize_text(first(split(string(label), '\n'))), columns))
end

# Left-aligned title padded/truncated to the panel's visible width.
_fit(text, width::Int) = rpad(join(Iterators.take(_sanitize_text(text), width)), width)

_curve_title(curvetitle, ylabel) =
    isnothing(curvetitle) ? (isnothing(ylabel) ? "trace" : "$(ylabel)(t)") : string(curvetitle)

_number(v::Real) = lpad(@sprintf("%.2f", v), 6)

function _emit(io::IO, tty::Bool, frame::IOBuffer)
    tty && print(io, "\e[H")
    write(io, take!(frame))
    flush(io)
    return nothing
end

# --- Validation ---------------------------------------------------------------

# Validate an explicit (low, high) range. Bounds must be real and finite, and
# low <= high. Equal bounds are allowed and curves expand them so an axis never
# collapses. `nothing` passes through unchanged.
function _range2(range, name::AbstractString)
    isnothing(range) && return nothing
    length(range) == 2 || throw(ArgumentError("$name must have exactly two bounds"))
    lo, hi = range[1], range[2]
    (lo isa Real && hi isa Real) || throw(ArgumentError("$name bounds must be real numbers"))
    lo, hi = float(lo), float(hi)
    (isfinite(lo) && isfinite(hi)) || throw(ArgumentError("$name bounds must be finite"))
    lo <= hi || throw(ArgumentError("$name low bound $lo exceeds high bound $hi"))
    return (lo, hi)
end

# Finite extrema without allocating a filtered copy. Returns `nothing` when no
# finite value exists.
function _finite_extrema(values)
    lo, hi, found = Inf, -Inf, false
    for v in values
        isfinite(v) || continue
        lo = min(lo, v)
        hi = max(hi, v)
        found = true
    end
    return found ? (lo, hi) : nothing
end

# --- Series normalization -----------------------------------------------------

"""
    _normalize_series(t, y)

Validate time/series inputs and return `(t, series)` without copying the data:
`t` is passed through by reference and each series is either the input vector or
a column view of the input matrix. Nested inputs must be one-based and match
`length(t)`. Non-nested inputs must be real and match `length(t)`.
"""
function _normalize_series(t::AbstractVector, y::AbstractVector)
    Base.require_one_based_indexing(t)
    eltype(t) <: Real || throw(ArgumentError("t values must be real numbers"))
    if eltype(y) <: AbstractVector
        Base.require_one_based_indexing(y)
        for s in y
            Base.require_one_based_indexing(s)
            eltype(s) <: Real || throw(ArgumentError("series values must be real numbers"))
            length(s) == length(t) ||
                throw(DimensionMismatch("series lengths $(map(length, y)) do not match t length $(length(t))"))
        end
        return t, y
    end
    Base.require_one_based_indexing(y)
    eltype(y) <: Real || throw(ArgumentError("series values must be real numbers"))
    length(y) == length(t) ||
        throw(DimensionMismatch("y length $(length(y)) does not match t length $(length(t))"))
    return t, [y]
end

function _normalize_series(t::AbstractVector, Y::AbstractMatrix)
    Base.require_one_based_indexing(t)
    eltype(t) <: Real || throw(ArgumentError("t values must be real numbers"))
    Base.require_one_based_indexing(Y)
    eltype(Y) <: Real || throw(ArgumentError("series values must be real numbers"))
    size(Y, 1) == length(t) ||
        throw(DimensionMismatch("Y has $(size(Y, 1)) rows, expected $(length(t))"))
    return t, [view(Y, :, k) for k in axes(Y, 2)]
end

# --- Geometry panel -----------------------------------------------------------

# Map a field argument to a matrix view matching `phi`, or `nothing`.
_field_values(::AbstractMatrix, ::Nothing) = nothing
function _field_values(phi::AbstractMatrix, field::AbstractVector{<:Real})
    Base.require_one_based_indexing(field)
    length(field) == length(phi) ||
        throw(DimensionMismatch("field has $(length(field)) values, expected $(length(phi))"))
    return reshape(field, size(phi))
end
function _field_values(phi::AbstractMatrix, field::AbstractMatrix{<:Real})
    Base.require_one_based_indexing(field)
    size(field) == size(phi) ||
        throw(DimensionMismatch("field has size $(size(field)), expected $(size(phi))"))
    return field
end
_field_values(::AbstractMatrix, field) =
    throw(ArgumentError("field must be a real vector or matrix"))

"""
    _geometry_rows(phi, width, height, field, colorrange, tty; colorbar)

Build the bordered level-set panel rows for a level-set matrix `phi` (shape
`(nx, ny)`). A real `field` (vector in column-major order or matching matrix)
colors the interior on TTY output. `colorrange` fixes the color scale.
"""
function _geometry_rows(phi::AbstractMatrix{<:Real}, width::Int, height::Int,
    field, colorrange, tty::Bool; colorbar::Bool)
    Base.require_one_based_indexing(phi)
    nx, ny = size(phi)
    nx > 1 && ny > 1 ||
        throw(ArgumentError("plot requires at least 2 nodes in each dimension"))
    values = _field_values(phi, field)
    cr = _range2(colorrange, "colorrange")
    lo, hi = if isnothing(values)
        (0.0, 1.0)
    else
        ex = _finite_extrema(values)
        isnothing(ex) && throw(ArgumentError("field has no finite values"))
        isnothing(cr) ? ex : cr
    end
    color(v) = FIELD_COLORS[1 + round(Int, (length(FIELD_COLORS) - 1) * _unit(v, lo, hi))]

    inside(column, halfrow) = any(phi[i, j] <= 0
        for i in fld((column - 1) * nx, width) + 1:fld(column * nx - 1, width) + 1,
            j in fld((halfrow - 1) * ny, 2height) + 1:fld(halfrow * ny - 1, 2height) + 1)
    function cellvalue(column, halfrow)
        cell = (values[i, j] for
            i in fld((column - 1) * nx, width) + 1:fld(column * nx - 1, width) + 1,
            j in fld((halfrow - 1) * ny, 2height) + 1:fld(halfrow * ny - 1, 2height) + 1
            if phi[i, j] <= 0 && isfinite(values[i, j]))
        total, count = 0.0, 0
        for v in cell
            total += v
            count += 1
        end
        count == 0 && return lo
        isfinite(total) && return total / count
        # Overflow fallback: compute a convex running mean without a large sum.
        average = 0.0
        for (k, v) in enumerate(cell)
            average = average * ((k - 1) / k) + v / k
        end
        return average
    end

    rows = String[]
    push!(rows, '+' * repeat("-", width) * '+')
    for row in height:-1:1
        buf = IOBuffer()
        print(buf, '|')
        for column in 1:width
            upper = inside(column, 2row)
            lower = inside(column, 2row - 1)
            if tty && !isnothing(values) && (upper || lower)
                upper && print(buf, "\e[38;5;$(color(cellvalue(column, 2row)))m")
                lower && print(buf, "\e[48;5;$(color(cellvalue(column, 2row - 1)))m")
                print(buf, upper ? '▀' : ' ')
                print(buf, "\e[0m")
            else
                print(buf, upper ? (lower ? '█' : '▀') : (lower ? '▄' : ' '))
            end
        end
        print(buf, '|')
        if colorbar && tty && !isnothing(values)
            # Gradient swatch on every row keeps all rows the same visual width,
            # so a side-by-side curve panel stays aligned. Numbers only top/mid/bottom.
            fraction = (row - 0.5) / height
            barvalue = lo * (1 - fraction) + hi * fraction
            # Visual row from the top, matching the curve panel's tick convention
            # (row counts from the bottom here). Equal for odd and even heights.
            visual = height - row + 1
            text = visual == 1 ? _number(hi) : visual == cld(height, 2) ? _number(lo / 2 + hi / 2) : visual == height ? _number(lo) : "      "
            print(buf, "  \e[48;5;$(color(barvalue))m \e[0m ", text)
        end
        push!(rows, String(take!(buf)))
    end
    push!(rows, '+' * repeat("-", width) * '+')
    return rows
end

# --- Curve panel --------------------------------------------------------------

# Widen a degenerate axis (lo == hi) while keeping both bounds finite and
# ordered. Small values retain the original ±0.5 padding. For large values, a
# relative pad prevents the floating-point ULP from swallowing the added delta.
function _expand_range(lo, hi)
    hi > lo && return (lo, hi)
    v = float(lo)
    pad = max(0.5, abs(v) * 0.05)
    low, high = v - pad, v + pad
    if !(isfinite(low) && isfinite(high)) || !(high > low)
        low, high = prevfloat(v), nextfloat(v)
        isfinite(low) || (low = v)
        isfinite(high) || (high = v)
    end
    return (low, high)
end

# Normalize v on [lo, hi] (any sign order, hi != lo) into [0, 1] before any
# integer rounding, so far-out finite samples saturate instead of overflowing
# `round(Int, ...)`.
function _unit(v, lo, hi)
    d = hi - lo
    d == 0 && return 0.0
    f = isfinite(d) ? (v - lo) / d : (v / 2 - lo / 2) / (hi / 2 - lo / 2)
    isnan(f) && return 0.5
    return clamp(f, 0.0, 1.0)
end

function _curve_limits(t, series, xrange, yrange)
    xr = _range2(xrange, "xrange")
    yr = _range2(yrange, "yrange")
    x0, x1 = isnothing(xr) ? something(_finite_extrema(t), (0.0, 1.0)) : xr
    y0, y1 = isnothing(yr) ? something(_finite_extrema(Iterators.flatten(series)), (0.0, 1.0)) : yr
    x0, x1 = _expand_range(x0, x1)
    y0, y1 = _expand_range(y0, y1)
    return x0, x1, y0, y1
end

"""
    _curve_rows(t, series, width, height, xrange, yrange, tty)

Build the bordered curve panel rows. `series` is a collection of real vectors
sharing the time vector `t`. Passing the same fixed `xrange`/`yrange` in a loop
stops axis flashing.
"""
function _curve_rows(t, series, width::Int, height::Int, xrange, yrange, tty::Bool)
    x0, x1, y0, y1 = _curve_limits(t, series, xrange, yrange)
    cells = fill(' ', height, width)
    owners = zeros(Int, height, width)
    colof(x) = clamp(1 + round(Int, _unit(x, x0, x1) * (width - 1)), 1, width)
    rowof(y) = clamp(1 + round(Int, _unit(y, y1, y0) * (height - 1)), 1, height)
    for (s, ys) in enumerate(series)
        glyph = CURVE_GLYPHS[mod1(s, length(CURVE_GLYPHS))]
        prev = nothing
        for (x, y) in zip(t, ys)
            if !(isfinite(x) && isfinite(y))
                prev = nothing
                continue
            end
            c, r = colof(x), rowof(y)
            cells[r, c] = glyph
            owners[r, c] = s
            if !isnothing(prev)
                pc, pr = prev
                for rr in min(r, pr):max(r, pr)
                    if cells[rr, c] == ' '
                        cells[rr, c] = '·'
                        owners[rr, c] = s
                    end
                end
            end
            prev = (c, r)
        end
    end
    rows = String[]
    push!(rows, '+' * repeat("-", width) * '+')
    for r in 1:height
        buf = IOBuffer()
        print(buf, '|')
        for c in 1:width
            if tty && owners[r, c] != 0
                print(buf, "\e[38;5;$(CURVE_COLORS[mod1(owners[r, c], length(CURVE_COLORS))])m",
                    cells[r, c], "\e[0m")
            else
                print(buf, cells[r, c])
            end
        end
        print(buf, '|')
        text = r == 1 ? _number(y1) : r == cld(height, 2) ? _number(y0 / 2 + y1 / 2) : r == height ? _number(y0) : ""
        isempty(text) || print(buf, ' ', text)
        push!(rows, String(take!(buf)))
    end
    push!(rows, '+' * repeat("-", width) * '+')
    return rows
end

function _legend(t, series, xrange, yrange, ylabel, labels, tty::Bool)
    names = isnothing(labels) ? ["series $i" for i in eachindex(series)] : collect(labels)
    length(names) == length(series) ||
        throw(DimensionMismatch("got $(length(names)) labels for $(length(series)) series"))
    x0, x1, _, _ = _curve_limits(t, series, xrange, yrange)
    parts = String[]
    for (s, rawname) in enumerate(names)
        name = _sanitize_text(rawname)
        glyph = CURVE_GLYPHS[mod1(s, length(CURVE_GLYPHS))]
        if tty
            push!(parts, "\e[38;5;$(CURVE_COLORS[mod1(s, length(CURVE_COLORS))])m$glyph\e[0m $name")
        else
            push!(parts, "$glyph $name")
        end
    end
    head = isnothing(ylabel) ? "" : string(_sanitize_text(ylabel), ", ")
    return head * "t ∈ [$(_number(x0)), $(_number(x1))]: " * join(parts, "   ")
end

# --- Legacy public API --------------------------------------------------------
# Kept byte-compatible with EvolvingDomains' original TerminalPlot so existing
# callers and tests do not change. Geometry is now a plain level-set matrix.

"""
    plot_geometry(phi::AbstractMatrix{<:Real}; io=stdout, size=nothing, label=nothing,
                  field=nothing, colorrange=nothing)

Render the negative level-set region of `phi` (shape `(nx, ny)`) with Unicode
block characters. Repeated calls in a terminal replace the previous frame and
adapt to the current terminal size. `label` adds a line above the plot. Pass a
nodal scalar `field` (matching vector or matrix) to color the interior in ANSI
terminals.
"""
function plot_geometry(phi::AbstractMatrix{<:Real}; io::IO=stdout,
    size::Union{Nothing,Tuple{Int,Int}}=nothing, label=nothing,
    field::Union{Nothing,AbstractVector{<:Real},AbstractMatrix{<:Real}}=nothing,
    colorrange=nothing)
    Base.require_one_based_indexing(phi)
    nx, ny = Base.size(phi)
    nx > 1 && ny > 1 ||
        throw(ArgumentError("plot requires at least 2 nodes in each dimension"))
    rows, columns = isnothing(size) ? displaysize(io) : size
    tty = _istty(io)
    lab = _clean_label(label, columns)
    width = max(columns - 2 - (tty && !isnothing(field) ? COLORBAR_WIDTH : 0), 1)
    height = max(rows - 2 - !isnothing(lab), 1)

    # Most terminal cells are roughly twice as tall as they are wide.
    width = min(width, max(1, round(Int, 2 * height * (nx - 1) / (ny - 1))))
    height = min(height, max(1, round(Int, width * (ny - 1) / (2 * (nx - 1)))))
    grows = _geometry_rows(phi, width, height, field, colorrange, tty; colorbar=true)

    frame = IOBuffer()
    clearline = tty ? "\e[K" : ""
    isnothing(lab) || println(frame, lab, clearline)
    for r in grows
        println(frame, r, clearline)
    end
    tty && print(frame, "\e[J")
    _emit(io, tty, frame)
    return nothing
end

function _single_curves(io::IO, size, label, t, series, xrange, yrange, labels, ylabel, curvetitle)
    rows, columns = isnothing(size) ? displaysize(io) : size
    tty = _istty(io)
    lab = _clean_label(label, columns)
    legend = _legend(t, series, xrange, yrange, ylabel, labels, tty)
    width = min(max(columns - 2, 1), MAX_CURVE_WIDTH)
    height = max(rows - 2 - !isnothing(lab) - 2, 1)
    crows = _curve_rows(t, series, width, height, xrange, yrange, tty)
    frame = IOBuffer()
    clearline = tty ? "\e[K" : ""
    isnothing(lab) || println(frame, lab, clearline)
    println(frame, _fit(_curve_title(curvetitle, ylabel), width + 2), clearline)
    for r in crows
        println(frame, r, clearline)
    end
    println(frame, legend, clearline)
    tty && print(frame, "\e[J")
    _emit(io, tty, frame)
    return nothing
end

"""
    plot_curves(t, y; io=stdout, size=nothing, label=nothing, curvetitle=nothing,
                xrange=nothing, yrange=nothing, labels=nothing, ylabel=nothing)

GNUplot-style ASCII time series. `y` is one vector, a vector of vectors, or a
matrix whose columns are multi-series. Pass fixed `xrange`/`yrange` in loops to
stop axis flashing.
"""
function plot_curves(t::AbstractVector, y::Union{AbstractVector,AbstractMatrix};
    io::IO=stdout, size::Union{Nothing,Tuple{Int,Int}}=nothing, label=nothing,
    curvetitle=nothing, xrange=nothing, yrange=nothing, labels=nothing, ylabel=nothing)
    tt, series = _normalize_series(t, y)
    _single_curves(io, size, label, tt, series, xrange, yrange, labels, ylabel, curvetitle)
    return nothing
end

function _dual(io::IO, size, label, phi::AbstractMatrix{<:Real}, t, series,
    field, colorrange, xrange, yrange, labels, ylabel, geotitle, curvetitle)
    rows, columns = isnothing(size) ? displaysize(io) : size
    tty = _istty(io)
    lab = _clean_label(label, columns)
    legend = _legend(t, series, xrange, yrange, ylabel, labels, tty)
    Base.require_one_based_indexing(phi)
    nx, ny = Base.size(phi)
    nx > 1 && ny > 1 ||
        throw(ArgumentError("plot requires at least 2 nodes in each dimension"))
    showbar = tty && !isnothing(field)
    avail_h = max(rows - 2 - !isnothing(lab) - 2, 1)
    avail_w = max(columns - 4 - 2 - (showbar ? COLORBAR_WIDTH : 0), 1)
    wg_fit = max(1, round(Int, 2 * avail_h * (nx - 1) / (ny - 1)))
    wg = min(wg_fit, max(avail_w - MIN_CURVE_WIDTH, 1))
    wc = min(max(avail_w - wg, 1), MAX_CURVE_WIDTH)
    hg = min(avail_h, max(1, round(Int, wg * (ny - 1) / (2 * (nx - 1)))))
    grows = _geometry_rows(phi, wg, hg, field, colorrange, tty; colorbar=true)
    crows = _curve_rows(t, series, wc, hg, xrange, yrange, tty)
    # Legend starts under the curve panel, past geometry + colorbar + separator.
    indent = " " ^ (wg + 2 + (showbar ? COLORBAR_WIDTH : 0) + 2)
    frame = IOBuffer()
    clearline = tty ? "\e[K" : ""
    isnothing(lab) || println(frame, lab, clearline)
    println(frame, _fit(geotitle, wg + 2), "  ", _fit(_curve_title(curvetitle, ylabel), wc + 2), clearline)
    for i in eachindex(grows)
        println(frame, grows[i], "  ", crows[i], clearline)
    end
    println(frame, indent, legend, clearline)
    tty && print(frame, "\e[J")
    _emit(io, tty, frame)
    return nothing
end

"""
    plot(phi::AbstractMatrix; kwargs...)

Dispatch entry point: `plot_geometry` for a lone level-set matrix,
`plot_curves` for `plot(t, y)`, dual geometry+curves panel for
`plot(phi, t, y)`. The node-based layout API uses `render`.
"""
plot(phi::AbstractMatrix{<:Real}; kwargs...) = plot_geometry(phi; kwargs...)
plot(t::AbstractVector, y::Union{AbstractVector,AbstractMatrix}; kwargs...) =
    plot_curves(t, y; kwargs...)

function plot(phi::AbstractMatrix{<:Real}, t::AbstractVector,
    y::Union{AbstractVector,AbstractMatrix};
    io::IO=stdout, size::Union{Nothing,Tuple{Int,Int}}=nothing, label=nothing,
    field::Union{Nothing,AbstractVector{<:Real},AbstractMatrix{<:Real}}=nothing,
    colorrange=nothing, xrange=nothing, yrange=nothing, labels=nothing, ylabel=nothing,
    geotitle="φ ≤ 0", curvetitle=nothing)
    tt, series = _normalize_series(t, y)
    _dual(io, size, label, phi, tt, series, field, colorrange, xrange, yrange,
        labels, ylabel, geotitle, curvetitle)
    return nothing
end
