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

    @testset "Range" begin
        start = ITime(0, period = Hour(1))
        step = ITime(1, period = Second(1), epoch = Date(2011))
        stop = ITime(1, period = Minute(1))
        stop1 = ITime(0, period = Day(1), epoch = Date(2012))

        start2stop = collect(start:step:stop)
        @test length(start2stop) == 61
        @test start2stop[begin] ==
              ITime(0, period = Second(1), epoch = Date(2011))
        @test start2stop[2] == ITime(1, period = Second(1), epoch = Date(2011))
        @test start2stop[end] ==
              ITime(60, period = Second(1), epoch = Date(2011))

        @test_throws ErrorException start:step:stop1
    end

    @testset "% and mod operators" begin
        t1 = ITime(0, period = Hour(1))
        t2 = ITime(1, period = Second(1))
        t3 = ITime(10, period = Day(1))
        t4 = ITime(7, period = Second(1))
        t5 = ITime(2, period = Second(1))
        t6 = ITime(7 // 2, period = Second(1))
        t7 = ITime(7 // (2 * 60), period = Minute(1))
        t8 = ITime(9, period = Second(2))
        t9 = ITime(2, period = Second(2))
        @test t1 % t2 == ITime(0, period = Second(1))
        @test t3 % t2 == ITime(0, period = Second(1))
        @test t4 % t5 == ITime(1, period = Second(1))
        @test t6 % t5 == ITime(3 // 2, period = Second(1))
        @test t7 % t5 == ITime(3 // 2, period = Second(1))
        @test t8 % t9 == ITime(1, period = Second(2))

        @test mod(t1, t2) == ITime(0, period = Second(1))
        @test mod(t3, t2) == ITime(0, period = Second(1))
        @test mod(t4, t5) == ITime(1, period = Second(1))
        @test mod(t6, t5) == ITime(3 // 2, period = Second(1))
        @test mod(t7, t5) == ITime(3 // 2, period = Second(1))
        @test t8 % t9 == ITime(1, period = Second(2))
    end

    @testset "iszero" begin
        t1 = ITime(0, period = Hour(1))
        t2 = ITime(1, period = Second(1))
        @test iszero(t1) == true
        @test iszero(t2) == false
    end

    @testset "length" begin
        t1 = ITime(0, period = Hour(1))
        @test length(t1) == 1
    end

    @testset "Int32 test" begin
        # Check if any operation with Int32 in ITime can lead to an Int64
        t1 = ITime(Int32(0), period = Second(1))
        t2 = ITime(Int32(1), period = Minute(1))
        t3 = ITime(Int32(2), period = Hour(1), epoch = DateTime(2010))
        t4 = ITime(Int32(1) // Int32(2), period = Second(1))
        t5 = ITime(Int32(3) // Int32(4), period = Minute(1))
        t6 = ITime(
            Int32(7) // Int32(8),
            period = Minute(1),
            epoch = DateTime(2011),
        )

        # Test promote
        tt1, tt2, tt3, tt4, tt5 = promote(t1, t2, t3, t4, t5)
        @test typeof(tt1.counter) == Int32
        @test typeof(tt2.counter) == Int32
        @test typeof(tt3.counter) == Int32
        @test typeof(tt4.counter) == Rational{Int32}
        @test typeof(tt5.counter) == Int32

        t7 = t1 + t2
        t8 = t2 + t3
        t9 = t4 + t5
        t10 = t5 + t6
        t11 = t1 + t4
        t12 = t1 + t6
        t13 = t3 + t4
        @test typeof(t7.counter) == Int32
        @test typeof(t8.counter) == Int32
        @test typeof(t9.counter) == Rational{Int32}
        @test typeof(t10.counter) == Rational{Int32}
        @test typeof(t11.counter) == Rational{Int32}
        @test typeof(t12.counter) == Rational{Int32}
        @test typeof(t13.counter) == Rational{Int32}

        t7 = t1 - t2
        t8 = t2 - t3
        t9 = t4 - t5
        t10 = t5 - t6
        t11 = t1 - t4
        t12 = t1 - t6
        t13 = t3 - t4
        @test typeof(t7.counter) == Int32
        @test typeof(t8.counter) == Int32
        @test typeof(t9.counter) == Rational{Int32}
        @test typeof(t10.counter) == Rational{Int32}
        @test typeof(t11.counter) == Rational{Int32}
        @test typeof(t12.counter) == Rational{Int32}
        @test typeof(t13.counter) == Rational{Int32}

        t7 = t1 / Int32(1)
        t8 = t2 / Int32(4)
        t9 = t3 / Int32(3)
        t10 = t4 / (Int32(1) // Int32(2))
        t11 = t5 / Int32(4)
        t12 = t6 / Int32(2)
        @test typeof(t7.counter) == Int32
        @test typeof(t8.counter) == Rational{Int32}
        @test typeof(t9.counter) == Rational{Int32}
        @test typeof(t10.counter) == Int32
        @test typeof(t11.counter) == Rational{Int32}
        @test typeof(t12.counter) == Rational{Int32}

        t7 = t1 * Int32(1)
        t8 = t2 * (Int32(4) // Int32(3))
        t9 = t3 * Int32(3)
        t10 = t4 * Int32(2)
        t11 = t5 * Int32(7)
        t12 = t6 * Int32(2)
        @test typeof(t7.counter) == Int32
        @test typeof(t8.counter) == Rational{Int32}
        @test typeof(t9.counter) == Int32
        @test typeof(t10.counter) == Int32
        @test typeof(t11.counter) == Rational{Int32}
        @test typeof(t12.counter) == Rational{Int32}

        @test typeof(oneunit(t1).counter) == Int32
        @test typeof(oneunit(t4).counter) == Int32
        @test typeof(zero(t1).counter) == Int32
        @test typeof(zero(t4).counter) == Int32

        @test typeof(mod(t4, t5).counter) == Rational{Int32}
        @test typeof(mod(t4, t3).counter) == Rational{Int32}
        @test typeof(mod(t3, t4).counter) == Int32
        @test typeof(mod(t3, t2).counter) == Int32
    end
end
