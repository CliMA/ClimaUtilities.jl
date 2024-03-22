using Test

import ClimaUtilities.Utils: searchsortednearest, linear_interpolation

@testset "searchsortednearest" begin
    A = 10 * collect(range(1, 10))

    @test searchsortednearest(A, 0) == 1
    @test searchsortednearest(A, 1000) == 10
    @test searchsortednearest(A, 20) == 2
    @test searchsortednearest(A, 21) == 2
    @test searchsortednearest(A, 29) == 3
end

@testset "linearinterpolation" begin
    @test linear_interpolation([1.0, 2.0, 3.0], [2.0, 4.0, 6.0], 1.5) ≈ 3.0
    @test linear_interpolation([1.0, 2.0, 3.0], [2.0, 4.0, 6.0], 2.5) ≈ 5.0

    # Test first element
    @test linear_interpolation([1.0, 2.0, 3.0], [2.0, 4.0, 6.0], 1.0) ≈ 2.0
    # Test last element
    @test linear_interpolation([1.0, 2.0, 3.0], [2.0, 4.0, 6.0], 3.0) ≈ 6.0
    # Test with different starting value
    @test linear_interpolation([0.0, 1.0, 2.0], [1.0, 4.0, 9.0], 0.5) ≈ 2.5
end
