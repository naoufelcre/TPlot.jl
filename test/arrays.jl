phi = reshape([-1.0, 1.0, 1.0, -1.0], 2, 2)
t = [0.0, 1.0]
Y = [1.0 2.0; 3.0 4.0]
a, b = IOBuffer(), IOBuffer()
plot_curves(t, Y; io=a, size=(8, 40))
plot_curves(t, [Y[:, 1], Y[:, 2]]; io=b, size=(8, 40))
@test take!(a) == take!(b)
plot(phi, t, Y; io=a, size=(8, 40))
plot(phi, t, [Y[:, 1], Y[:, 2]]; io=b, size=(8, 40))
@test take!(a) == take!(b)

for tty in (false, true)
    aa, bb = IOContext(a, :terminal => tty), IOContext(b, :terminal => tty)
    plot_geometry(phi; io=aa, size=(10, 40), field=Y)
    plot_geometry(phi; io=bb, size=(10, 40), field=vec(Y))
    @test take!(a) == take!(b)
end
@test_throws DimensionMismatch plot_geometry(phi; io=a, field=ones(1, 4))
@test_throws ArgumentError plot_geometry(phi; io=a, field=fill(NaN, 4))
@test_throws DimensionMismatch plot_curves(t, [1.0 2.0]; io=a)
@test_throws DimensionMismatch plot_curves(t, Y; io=a, labels=["one"])
plot_curves([0.0, 1.0, 2.0], [1.0, NaN, 2.0]; io=a, size=(8, 40),
    xrange=(0.0, 3.0), curvetitle="custom")
@test startswith(String(take!(a)), "custom")
plot_curves([NaN, Inf], [NaN, Inf]; io=a, size=(8, 40))
@test occursin("+", String(take!(a)))
@test_throws ArgumentError plot_curves(t, Y; io=a, xrange=(NaN, 1.0))
@test_throws ArgumentError plot_curves(t, Y; io=a, yrange=(2.0, 1.0))
@test_throws ArgumentError plot_geometry(phi; io=a, field=vec(Y), colorrange=(Inf, 2.0))
