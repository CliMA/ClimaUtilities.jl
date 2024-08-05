using Test

import ClimaUtilities.Utils:
    searchsortednearest, linear_interpolation, isequispaced, wrap_time

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

@testset "isequispaced" begin
    @test isequispaced([1, 2, 3, 4, 5])
    @test !isequispaced([1, 2, 4, 8, 16])
    @test isequispaced([1.0, 2.0, 3.0, 4.0, 5.0])
    @test !isequispaced([1.0, 2.0, 3.1, 4.0, 5.0])
end

@testset "wrap_time" begin
    t_init = 10
    t_end = 20
    dt = 1

    @test wrap_time(15, t_init, t_end) == 15
    @test wrap_time(25, t_init, t_end) == 15
    @test wrap_time(5, t_init, t_end) == 15

    # Wrapping when time equals t_init or t_end
    @test wrap_time(10, t_init, t_end) == 10
    @test wrap_time(20, t_init, t_end) == 10
end
