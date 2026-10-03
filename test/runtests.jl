using Test
using TPlot

@testset "TPlot" begin
    @testset "Rendering compatibility" begin
        include("legacy.jl")
    end
    @testset "Array inputs" begin
        include("arrays.jl")
    end
    @testset "Input validation" begin
        include("validation.jl")
    end
    @testset "Weighted layouts" begin
        include("layout.jl")
    end
end
