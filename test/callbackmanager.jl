import ClimaUtilities: CallbackManager
import Dates
import CFTime
using Test

for FT in (Float32, Float64)
    @testset "test to_datetime for FT=$FT" begin
        # Test non-leap year behavior
        year = 2001
        dt_noleap = CFTime.DateTimeNoLeap(year)
        dt = Dates.DateTime(year)
        @test CallbackManager.to_datetime(dt_noleap) == dt
        # In non-leap year, DateTime and DateTimeNoLeap are the same
        @test CallbackManager.to_datetime(dt_noleap + Dates.Day(365)) ==
              dt + Dates.Day(365)

        # Test leap year behavior
        leap_year = 2000
        dt_noleap_ly = CFTime.DateTimeNoLeap(leap_year)
        dt_ly = Dates.DateTime(leap_year)
        # DateTime includes leap days, DateTimeNoLeap does not, so DateTime has one extra day in leap year
        @test CallbackManager.to_datetime(dt_noleap_ly + Dates.Day(365)) ==
              dt_ly + Dates.Day(366)

    end

    @testset "test strdate_to_datetime for FT=$FT" begin
        @test CallbackManager.strdate_to_datetime("19000101") ==
              Dates.DateTime(1900, 1, 1)
        @test CallbackManager.strdate_to_datetime("00000101") ==
              Dates.DateTime(0, 1, 1)
    end

    @testset "test datetime_to_strdate for FT=$FT" begin
        @test CallbackManager.datetime_to_strdate(Dates.DateTime(1900, 1, 1)) ==
              "19000101"
        @test CallbackManager.datetime_to_strdate(Dates.DateTime(0, 1, 1)) ==
              "00000101"
    end

    @testset "test trigger_callback for FT=$FT" begin
        # Define callback function
        func! = (val) -> val[1] += 1
        # Case 1: date_current == date_nextcall
        # Define list for arg so we can mutate it in `func!`
        arg = [FT(0)]
        arg_copy = copy(arg)
        date_current =
            date_nextcall = date_nextcall_copy = Dates.DateTime(1979, 3, 21)
        date_nextcall = CallbackManager.trigger_callback(
            date_nextcall,
            date_current,
            CallbackManager.Monthly(),
            func!,
            (arg,),
        )
        # Test that cutoff date was updated and `func!` got called
        @test date_nextcall == date_nextcall_copy + Dates.Month(1)
        @test arg[1] == func!(arg_copy)

        # Case 2: date_current > date_nextcall
        date_nextcall = date_nextcall_copy = Dates.DateTime(1979, 3, 21)
        date_current = date_nextcall + Dates.Day(1)
        date_nextcall = CallbackManager.trigger_callback(
            date_nextcall,
            date_current,
            CallbackManager.Monthly(),
            func!,
            (arg,),
        )
        # Test that cutoff date was updated and `func!` got called
        @test date_nextcall == date_nextcall_copy + Dates.Month(1)
        @test arg[1] == func!(arg_copy)

        # Case 3: date_current < date_nextcall
        date_nextcall = date_nextcall_copy = Dates.DateTime(1979, 3, 21)
        date_current = date_nextcall - Dates.Day(1)
        date_nextcall = CallbackManager.trigger_callback(
            date_nextcall,
            date_current,
            CallbackManager.Monthly(),
            func!,
            (arg,),
        )
        # Test that cutoff date is unchanged and `func!` did not get called
        @test date_nextcall == date_nextcall_copy
        @test arg[1] == arg_copy[1]
    end
end
