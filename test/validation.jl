# Trust-boundary tests for Rendering.jl inputs and coordinate mapping.
# The runner includes this file separately.

using Test
using TPlot

@testset "series input validation" begin
    io = IOBuffer()
    # Complex time vector.
    @test_throws ArgumentError plot_curves([1.0 + 0im, 2.0 + 0im], [1.0, 2.0]; io=io)
    # Complex plain series.
    @test_throws ArgumentError plot_curves([0.0, 1.0], [1.0 + 0im, 2.0 + 0im]; io=io)
    # Complex nested series (vector of vectors): first inner check must catch it.
    @test_throws ArgumentError plot_curves([0.0, 1.0],
        [[1.0 + 0im, 2.0 + 0im], [1.0, 2.0]]; io=io)
    # Complex matrix series.
    @test_throws ArgumentError plot_curves([0.0, 1.0], ComplexF64[1 2; 3 4]; io=io)
end

@testset "coordinate mapping saturation" begin
    io = IOBuffer()
    # Finite values far outside a narrow fixed range must saturate in the panel
    # instead of throwing an InexactError from `round(Int, huge)`.
    plot_curves([1e30, 2.0, -1e30], [1e30, 0.0, -1e30]; io=io, size=(8, 40),
        xrange=(-1.0, 1.0), yrange=(-1.0, 1.0))
    out = String(take!(io))
    @test occursin("+", out)
    @test occursin("*", out)

    # Extremely large constant data must not stay degenerate after expansion.
    plot_curves([1e20, 1e20], [1e20, 1e20]; io=io, size=(8, 40))
    @test occursin("+", String(take!(io)))

    # Explicit degenerate ranges are expanded by a relative pad.
    plot_curves([1e20, 1e20], [1e20, 1e20]; io=io, size=(8, 40),
        xrange=(1e20, 1e20), yrange=(1e20, 1e20))
    @test occursin("+", String(take!(io)))

    # A large constant field with a degenerate color range must not divide by zero.
    phi = reshape([-1.0, 1.0, 1.0, -1.0], 2, 2)
    tio = IOContext(IOBuffer(), :terminal => true)
    plot_geometry(phi; io=tio, size=(10, 40), field=fill(1e20, 4),
        colorrange=(1e20, 1e20))
    @test occursin("+", String(take!(tio.io)))

    # Finite ranges spanning nearly the full float domain retain their endpoints.
    @test TPlot._unit(-1e308, -1e308, 1e308) == 0.0
    @test TPlot._unit(0.0, -1e308, 1e308) == 0.5
    @test TPlot._unit(1e308, -1e308, 1e308) == 1.0
    @test TPlot._unit(1e308, 1e308, -1e308) == 0.0
    @test all(isfinite, TPlot._expand_range(floatmax(Float64), floatmax(Float64)))
    for field in ([1e308, -1e308, 1e308, -1e308], fill(1e308, 4))
        plot_geometry(phi; io=tio, size=(10, 40), field=field,
            colorrange=(-1e308, 1e308))
        @test occursin("+", String(take!(tio.io)))
    end
    plot_geometry(fill(-1.0, 2, 2); io=tio, size=(4, 14), field=fill(1e308, 4))
    @test occursin("+", String(take!(tio.io)))
end

@testset "legacy text sanitization" begin
    phi = [-1.0 1.0; 1.0 -1.0]
    io = IOBuffer()
    plot_geometry(phi; io=io, size=(6, 20), label="unsafe\e[2J\u009b2J")
    output = String(take!(io))
    @test !occursin('\e', output) && !occursin('\u009b', output)
    plot(phi, [0.0, 1.0], [0.0, 1.0]; io=io, size=(10, 70),
        geotitle="unsafe\e[2J", curvetitle="unsafe\e[2J",
        labels=["unsafe\e[2J"], ylabel="unsafe\e[2J")
    @test !occursin('\e', String(take!(io)))
end
