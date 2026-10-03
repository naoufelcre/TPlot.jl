# Layout.jl -- nested terminal tiling for TPlot.
#
# A tiny immutable row/column tree of leaf panels (Geometry, Curves).  Leaves hold
# references to the caller's data. Nothing is copied and nothing is cached, so a
# panel reflects mutations to the underlying arrays on the next `render`.  Every
# render (re)validates the data because those references can change between frames.
#
# This file is included into module TPlot *after* Rendering.jl, so the low-level
# helpers (_geometry_rows, _curve_rows, _normalize_series, _field_values, _range2,
# _finite_extrema, _legend, _curve_title, _number, _istty) and the constants
# COLORBAR_WIDTH/MAX_CURVE_WIDTH live in the same module and are used directly.

# ANSI SGR/EL sequences emitted by the render helpers.  Used only to measure and
# clip display cells. User text is sanitized before it ever reaches the output.
const _ANSI_RE = r"\x1b\[[0-9;]*[A-Za-z]"
# C0 controls, DEL, and the C1 block U+0080--U+009F (which includes the 8-bit CSI
# U+009B, e.g. "\u009b2J").  Newlines/escape bytes must not reach the frame.
const _CTRL_RE = r"[\x00-\x1f\x7f\u0080-\u009f]"

# Strip terminal control sequences *and* control bytes from user text.
_sanitize_text(::Nothing) = ""
_sanitize_text(s) = replace(replace(string(s), _ANSI_RE => ""), _CTRL_RE => " ")

# Preserve `nothing` (the helpers use it to pick defaults) while sanitizing text.
_sanitize_opt(::Nothing) = nothing
_sanitize_opt(s) = _sanitize_text(s)

# --- ANSI / Unicode aware cell geometry --------------------------------------

# Visible width in terminal cells, ignoring ANSI escapes and counting wide
# characters (CJK, emoji) as two cells and combining marks as zero.
function _display_width(s::AbstractString)
    return textwidth(replace(s, _ANSI_RE => ""))
end

# Keep the first `width` display cells, copying ANSI escapes verbatim.  Never
# splits a wide character and closes an active color if clipping cuts it off.
function _clip_ansi(s::AbstractString, width::Int)
    width <= 0 && return ""
    out = IOBuffer()
    w = 0
    pos = 1
    active = false
    last = lastindex(s)
    for m in eachmatch(_ANSI_RE, s)
        if m.offset > pos
            for c in SubString(s, pos, prevind(s, m.offset))
                cw = textwidth(c)
                if w + cw > width
                    active && print(out, "\e[0m")
                    return String(take!(out))
                end
                print(out, c)
                w += cw
            end
        end
        print(out, m.match)
        active = m.match == "\e[0m" ? false : true
        pos = m.offset + ncodeunits(m.match)
    end
    if pos <= last
        for c in SubString(s, pos, last)
            cw = textwidth(c)
            if w + cw > width
                active && print(out, "\e[0m")
                return String(take!(out))
            end
            print(out, c)
            w += cw
        end
    end
    active && print(out, "\e[0m")
    return String(take!(out))
end

# Clip then right-pad to exactly `width` display cells.
function _fit_cells(s::AbstractString, width::Int)
    width <= 0 && return ""
    clipped = _clip_ansi(s, width)
    w = _display_width(clipped)
    w < width && return clipped * repeat(" ", width - w)
    return clipped
end

# Clip/pad a block to exactly max(height,0) rows of exactly max(width,0) cells.
function _fit_block(lines, width::Int, height::Int)
    h = max(height, 0)
    out = Vector{String}(undef, h)
    for r in 1:h
        line = r <= length(lines) ? lines[r] : ""
        out[r] = _fit_cells(line, width)
    end
    return out
end

# --- Data model ---------------------------------------------------------------

struct Geometry{M<:AbstractMatrix{<:Real},F,CR}
    phi::M
    field::F
    colorrange::CR
    title::String
    cell_aspect::Float64
end

struct Curves{T<:AbstractVector,Y<:Union{AbstractVector,AbstractMatrix},XR,YR,L}
    t::T
    y::Y
    xrange::XR
    yrange::YR
    labels::L
    ylabel::Union{Nothing,String}
    title::Union{Nothing,String}
end

struct Row{C<:Tuple,W}
    children::C
    weights::W
    gap::Int
end

struct Column{C<:Tuple,W}
    children::C
    weights::W
    gap::Int
end

const _LayoutNode = Union{Geometry,Curves,Row,Column}

# --- Validation (reuses the core Rendering.jl helpers) -----------------------

# Geometry data + explicit ranges.  Called at construction and again on every
# render (including zero-sized tiles), so mutated references cannot slip through.
function _validate_geometry(phi, field, colorrange)
    Base.require_one_based_indexing(phi)
    size(phi, 1) >= 2 && size(phi, 2) >= 2 ||
        throw(ArgumentError("Geometry requires at least 2 nodes in each dimension"))
    values = _field_values(phi, field)
    if values !== nothing
        _finite_extrema(values) === nothing &&
            throw(ArgumentError("field has no finite values"))
    end
    _range2(colorrange, "colorrange")
    return nothing
end

# --- Constructors -------------------------------------------------------------

function Geometry(phi::AbstractMatrix{<:Real}; field=nothing, colorrange=nothing,
    title="φ ≤ 0", cell_aspect::Real=2.0)
    _validate_geometry(phi, field, colorrange)
    aspect = Float64(cell_aspect)
    (isfinite(aspect) && aspect > 0) ||
        throw(ArgumentError("cell_aspect must be positive and finite as Float64"))
    return Geometry{typeof(phi),typeof(field),typeof(colorrange)}(
        phi, field, colorrange, _sanitize_text(title), aspect)
end

function Curves(t::AbstractVector, y::Union{AbstractVector,AbstractMatrix};
    xrange=nothing, yrange=nothing, labels=nothing, ylabel=nothing, title=nothing)
    # Core validator checks t/series are real, one-based, and matching, without
    # copying the data. Labels stay a reference. _legend sanitizes them per call.
    _, series = _normalize_series(t, y)
    _range2(xrange, "xrange")
    _range2(yrange, "yrange")
    if labels !== nothing && length(labels) != length(series)
        throw(DimensionMismatch("got $(length(labels)) labels for $(length(series)) series"))
    end
    return Curves{typeof(t),typeof(y),typeof(xrange),typeof(yrange),typeof(labels)}(
        t, y, xrange, yrange, labels, _sanitize_opt(ylabel), _sanitize_opt(title))
end

function _container_validate(children, weights, gap)
    isempty(children) && throw(ArgumentError("layout requires at least one child"))
    for c in children
        c isa _LayoutNode ||
            throw(ArgumentError("invalid layout child of type $(typeof(c))"))
    end
    (gap isa Real && isfinite(gap) && isinteger(gap) && gap >= 0) ||
        throw(ArgumentError("gap must be a non-negative integer"))
    gap <= typemax(Int) || throw(ArgumentError("gap is too large"))
    w = nothing
    if weights !== nothing
        ws = collect(weights)
        length(ws) == length(children) ||
            throw(ArgumentError("weights length $(length(ws)) must match $(length(children)) children"))
        for x in ws
            (x isa Real && isfinite(x) && x > 0) ||
                throw(ArgumentError("weights must be positive finite numbers"))
        end
        w = Tuple(Float64(x) for x in ws)
        all(x -> isfinite(x) && x > 0, w) ||
            throw(ArgumentError("weights must be representable as positive finite Float64"))
    end
    return Int(gap), w
end

function Row(children...; weights=nothing, gap::Real=2)
    g, w = _container_validate(children, weights, gap)
    return Row{typeof(children),typeof(w)}(children, w, g)
end

function Column(children...; weights=nothing, gap::Real=1)
    g, w = _container_validate(children, weights, gap)
    return Column{typeof(children),typeof(w)}(children, w, g)
end

# --- Weighted cell allocation -------------------------------------------------

# Largest-remainder split of `total` cells across `n` children.  Weights are
# normalized by their maximum *before* summing/multiplying so huge (e.g. 1e308)
# weights cannot overflow to Inf/NaN.  Zero growth when there is no space.
function _allocate(total::Int, n::Int, weights)
    n <= 0 && return Int[]
    total <= 0 && return zeros(Int, n)
    if weights === nothing
        base = div(total, n)
        extra = total - base * n
        return Int[base + (i <= extra ? 1 : 0) for i in 1:n]
    end
    wmax = maximum(weights)
    scaled = Float64[w / wmax for w in weights]
    sw = sum(scaled)
    exact = Float64[total * (s / sw) for s in scaled]
    base = floor.(Int, exact)
    extra = clamp(total - sum(base), 0, n)
    frac = exact .- base
    order = sortperm(frac; rev=true)
    for i in 1:extra
        base[order[i]] += 1
    end
    return base
end

# Split a gap across the available extent so a huge `gap` with a tiny terminal
# cannot allocate oversized whitespace runs.
_gap_for(gap::Int, extent::Int, n::Int) = n <= 1 ? 0 : min(gap, max(extent, 0) ÷ (n - 1))

# --- Leaf panels --------------------------------------------------------------

function _render_lines(node::Geometry, width::Int, height::Int, tty::Bool)
    # Validate on every render, including zero-sized tiles.
    _validate_geometry(node.phi, node.field, node.colorrange)
    (width <= 0 || height <= 0) && return _fit_block(String[], width, height)

    nx, ny = size(node.phi, 1), size(node.phi, 2)
    title = node.title
    title_h = isempty(title) ? 0 : 1
    showbar = tty && node.field !== nothing
    bar = showbar ? COLORBAR_WIDTH : 0

    iw = max(width - 2 - bar, 1)
    ih = max(height - title_h - 2, 1)
    # Preserve the data node aspect using the panel's cell aspect.
    # ponytail: preserve aspect with one clamp pass, leave unused tile space.
    a = node.cell_aspect
    iw = round(Int, clamp(a * ih * ((nx - 1) / (ny - 1)), 1, iw))
    ih = round(Int, clamp(iw * ((ny - 1) / (nx - 1)) / a, 1, ih))

    rows = _geometry_rows(node.phi, iw, ih, node.field, node.colorrange, tty; colorbar=showbar)
    lines = String[]
    title_h == 1 && push!(lines, title)
    append!(lines, rows)
    return _fit_block(lines, width, height)
end

function _render_lines(node::Curves, width::Int, height::Int, tty::Bool)
    # Normalizing validates t/series on every render. Labels stay a reference.
    # _legend sanitizes them on every call, so mutated vectors cannot leak.
    tt, series = _normalize_series(node.t, node.y)
    _range2(node.xrange, "xrange")
    _range2(node.yrange, "yrange")
    labels = node.labels
    if labels !== nothing && length(labels) != length(series)
        throw(DimensionMismatch("got $(length(labels)) labels for $(length(series)) series"))
    end
    (width <= 0 || height <= 0) && return _fit_block(String[], width, height)

    title = _curve_title(node.title, node.ylabel)
    legend = _legend(tt, series, node.xrange, node.yrange, node.ylabel, labels, tty)

    # Budget: one title row, one legend row, plus the two box borders.
    # ponytail: clip titles/legends to one line, wrap only if callers need it.
    ih = max(height - 4, 1)
    # Leave room for the right-hand tick text (7 cells) so it is not clipped.
    cw = max(width - 2 - 7, 1)
    crows = _curve_rows(tt, series, cw, ih, node.xrange, node.yrange, tty)
    lines = String[]
    isempty(title) || push!(lines, string(title))
    append!(lines, crows)
    push!(lines, legend)
    return _fit_block(lines, width, height)
end

# --- Container panels ---------------------------------------------------------

function _render_lines(node::Row, width::Int, height::Int, tty::Bool)
    n = length(node.children)
    g = _gap_for(node.gap, width, n)
    ws = _allocate(width - g * (n - 1), n, node.weights)
    blocks = [_render_lines(node.children[i], ws[i], height, tty) for i in 1:n]
    h = max(height, 0)
    out = Vector{String}(undef, h)
    for r in 1:h
        parts = String[]
        for i in 1:n
            push!(parts, blocks[i][r])
            i < n && push!(parts, repeat(" ", g))
        end
        out[r] = join(parts)
    end
    # Children are fitted to the allocated widths and the gaps plus those widths
    # sum to `width`, so `out` is already exactly width x height: no refit.
    return out
end

function _render_lines(node::Column, width::Int, height::Int, tty::Bool)
    n = length(node.children)
    g = _gap_for(node.gap, height, n)
    hs = _allocate(height - g * (n - 1), n, node.weights)
    out = String[]
    for i in 1:n
        append!(out, _render_lines(node.children[i], width, hs[i], tty))
        i < n && append!(out, [repeat(" ", max(width, 0)) for _ in 1:g])
    end
    # Children are fitted to the allocated heights and the gaps plus those
    # heights sum to `height`, so `out` is already exactly width x height: no refit.
    return out
end

# --- Entry point --------------------------------------------------------------

# Exactly two non-negative integers, or `nothing` for the current displaysize.
function _frame_size(io, size)
    if size === nothing
        r, c = displaysize(io)
    elseif (size isa Tuple || size isa AbstractVector) && length(size) == 2
        r, c = size
    else
        throw(ArgumentError("size must be a (rows, columns) pair"))
    end
    (r isa Integer && c isa Integer) ||
        throw(ArgumentError("size entries must be integers"))
    (r >= 0 && c >= 0) ||
        throw(ArgumentError("size entries must be non-negative"))
    return Int(r), Int(c)
end

"""
    render(node; io=stdout, size=nothing, label=nothing)

Draw a `Geometry`/`Curves`/`Row`/`Column` tree into `io`.  The frame is built in a
single buffer. Plain streams get newline-terminated lines and no escape bytes at
all. Terminals get only frame-home/clear-to-EOL/clear-below with CRLF row breaks.
Output is strictly bounded by the terminal (or `size`) dimensions, and a
one-column right margin on terminals avoids the bottom-right autowrap scroll.
"""
function render(node::_LayoutNode; io::IO=stdout, size=nothing, label=nothing)
    # Recompute from live data and current terminal dimensions.
    rows, cols = _frame_size(io, size)
    tty = _istty(io)
    # Safe margin: never fill the last column, so no line can trigger autowrap.
    # ponytail: reserve one column, use cursor-addressed rows if full width matters.
    width = tty ? max(cols - 1, 0) : cols

    if rows == 0
        # No content row may be emitted, but the tree must still validate.
        _render_lines(node, width, 0, tty)
        return nothing
    end

    lab = _sanitize_text(label)
    lab_h = isempty(lab) ? 0 : 1
    body_h = rows - lab_h
    lines = _render_lines(node, width, body_h, tty)
    lab_h == 1 && pushfirst!(lines, _fit_cells(lab, width))

    buf = IOBuffer()
    if tty
        print(buf, "\e[H")
        for (i, ln) in enumerate(lines)
            i > 1 && print(buf, "\r\n")
            print(buf, ln, "\e[K")
        end
        print(buf, "\e[J")
    else
        for (i, ln) in enumerate(lines)
            i > 1 && print(buf, '\n')
            print(buf, ln)
        end
        # Terminate the last line so repeated frames never concatenate.
        isempty(lines) || print(buf, '\n')
    end
    write(io, take!(buf))
    flush(io)
    return nothing
end
