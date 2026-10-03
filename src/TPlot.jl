module TPlot

using Printf: @sprintf

include("Rendering.jl")
include("Layout.jl")

export plot, plot_geometry, plot_curves
export Geometry, Curves, Row, Column, render

end # module TPlot
