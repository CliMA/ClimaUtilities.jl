import ClimaUtilities
using ClimaUtilities.TimeManager

using Test, Dates

@testset "ITime" begin
    @testset "Constructors" begin
        # Constructor with just an integer counter
        t1 = ITime(10)
        @test t1.counter == 10
        @test t1.period == Dates.Second(1)
        @test isnothing(t1.epoch)

        # Constructor with just an integer counter in Int32
        t1_int32 = ITime(Int32(10))
        @test t1_int32.counter isa Int32
        @test t1_int32.counter == 10

        # Constructor with just an integer ratio
        t2 = ITime(1 // 2)
        @test t2.counter == 1 // 2
        @test t2.period == Dates.Second(1)
        @test isnothing(t2.epoch)

        # Constructor with start date
        epoch = Dates.DateTime(2024, 1, 1)
        t3 = ITime(10, epoch = epoch)
        @test t3.epoch == epoch

        # Start date as Date (not DateTime)
        t4 = ITime(10, epoch = Dates.Date(2024, 1, 1))
        @test t4.epoch == epoch

        # Explicit period
        t5 = ITime(10, period = Dates.Millisecond(100))
        @test t5.period == Dates.Millisecond(100)

        # Rational with denominator 1 converts to Integer
        t6 = ITime(3 // 1)
        @test t6.counter == 3
        @test t6.counter isa Int

        # From float
        t6 = ITime(0.0)
        @test t6.counter == 0
        @test t6.period == Dates.Second(1)

        t7 = ITime(1.0)
        @test t7.counter == 1
        @test t7.period == Dates.Second(1)

        t8 = ITime(0.001)
        @test t8.counter == 1
        @test t8.period == Dates.Millisecond(1)

        t9 = ITime(1.5)
        @test t9.counter == 1500
        @test t9.period == Dates.Millisecond(1)


        t10 = ITime(1.5; epoch = Dates.DateTime(2020, 1, 1))
        @test t10.epoch == Dates.DateTime(2020, 1, 1)

        # Cannot be represented exactly
        @test_throws ErrorException ITime(1e-20)
    end

    @testset "Accessors" begin
        t = ITime(10, Dates.Millisecond(50), Dates.DateTime(2024, 1, 1))
        @test counter(t) == 10
        @test period(t) == Dates.Millisecond(50)
        @test epoch(t) == Dates.DateTime(2024, 1, 1)
    end

    @testset "date" begin
        t1 = ITime(10, epoch = Dates.DateTime(2024, 1, 1))
        @test date(t1) == Dates.DateTime(2024, 1, 1) + Dates.Second(10)
        @test Dates.DateTime(t1) ==
              Dates.DateTime(2024, 1, 1) + Dates.Second(10)

        # Correct conversion with rational counter
        t2 = ITime(1 // 2, epoch = Dates.DateTime(2024, 1, 1))
        @test date(t2) == t2.epoch + Dates.Millisecond(500)

        # Cannot convert to date without a start date
        t3 = ITime(10)
        @test_throws ErrorException date(t3) # No start date
    end

    @testset "Promote" begin
        t1 = ITime(10, period = Dates.Millisecond(100))
        t2 = ITime(100, period = Dates.Millisecond(10))
        t1_promoted, t2_promoted = promote(t1, t2)
        @test t1_promoted.counter == 100
        @test t2_promoted.counter == 100
        @test t1_promoted.period == Dates.Millisecond(10)

        t3 = ITime(10, epoch = Dates.DateTime(2024, 1, 1))
        t4 = ITime(20)

        t3_promoted, t4_promoted = promote(t3, t4)
        @test t3_promoted.epoch == Dates.DateTime(2024, 1, 1)
        @test t4_promoted.epoch == Dates.DateTime(2024, 1, 1)

        @test_throws ErrorException promote(
            t3,
            ITime(10, epoch = Dates.DateTime(2024, 1, 2)),
        )
    end

    @testset "Arithmetic Operations" begin
        t1 = ITime(10)
        t2 = ITime(5)
        @test t1 + t2 == ITime(15)
        @test t1 - t2 == ITime(5)
        @test -t1 == ITime(-10)
        @test abs(t1) == ITime(10)

        t3 = ITime(10, period = Dates.Millisecond(100))
        t4 = ITime(100, period = Dates.Millisecond(10))
        @test t3 + t4 == ITime(200, period = Dates.Millisecond(10)) # 10*100 + 100*10 = 2000 ms = 2s

        @test !(t1 < t2)
        @test t1 > t2
        @test t1 == ITime(10)
        @test t1 != ITime(5)
        @test isapprox(t1, ITime(10))

        @test t1 / 2 == ITime(5)
        @test t1 * 2 == ITime(20)
        @test 2 * t1 == ITime(20)
        @test div(t1, 2) == ITime(5)
        @test t1 / t2 == 2
        @test t2 / t1 == 1 // 2

        @test one(t1) == 1
        @test oneunit(t1) == ITime(1)
        @test zero(t1) == ITime(0)


        t5 = ITime(10, epoch = Dates.DateTime(2024, 1, 1))
        t6 = ITime(5, epoch = Dates.DateTime(2024, 1, 1))
        @test (t5 + t6).epoch == t5.epoch

        t7 = ITime(5, epoch = Dates.DateTime(2024, 10, 1))
        # Arithmetic operations between ITime with different epochs are disallowed
        @test_throws ErrorException t6 + t7
    end

    @testset "Float Conversion and Broadcasting" begin
        t1 = ITime(10, period = Dates.Millisecond(100))
        @test float(t1) == 1.0

        # Test broadcasting (simple example)
        @test float.(t1) == 1.0
    end

    @testset "Show method" begin
        t1 = ITime(10)
        @test sprint(show, t1) == "10 seconds [counter = 10, period = 1 second]"

        t2 = ITime(10, epoch = Dates.DateTime(2024, 1, 1))
        @test sprint(show, t2) ==
              "10 seconds (2024-01-01T00:00:10) [counter = 10, period = 1 second, epoch = 2024-01-01T00:00:00]"

        t3 = ITime(1 // 2)
        @test sprint(show, t3) ==
              "1//2 seconds [counter = 1//2, period = 1 second]"

        t4 = ITime(
            10,
            period = Dates.Hour(1),
            epoch = Dates.DateTime(2024, 1, 1),
        )
        @test sprint(show, t4) ==
              "10 hours (2024-01-01T10:00:00) [counter = 10, period = 1 hour, epoch = 2024-01-01T00:00:00]"
    end

    @testset "Rational counter tests" begin
        t1 = ITime(2)
        t2 = ITime(1 // 2)

        @test t1 + t2 == ITime(5 // 2)
        @test t1 - t2 == ITime(3 // 2)
        @test t2 - t1 == ITime(-3 // 2)
        @test t2 * 2 == ITime(1)
        @test t1 / 2 == ITime(1)
    end

    @testset "Find common epoch" begin
        t1 = ITime(0, period = Second(1), epoch = Date(2011))
        t2 = ITime(0, period = Minute(1), epoch = Date(2011))
        t3 = ITime(0, period = Hour(1))
        t4 = ITime(0, period = Day(1), epoch = Date(2012))

        @test ClimaUtilities.TimeManager.find_common_epoch(t1, t2) == Date(2011)
        @test ClimaUtilities.TimeManager.find_common_epoch(t1, t3) == Date(2011)
        @test_throws ErrorException ClimaUtilities.TimeManager.find_common_epoch(
            t1,
            t4,
        )
        @test_throws ErrorException ClimaUtilities.TimeManager.find_common_epoch(
            t1,
            t2,
            t3,
            t4,
        )
    end
end
