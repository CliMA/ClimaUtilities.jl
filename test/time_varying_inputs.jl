using Test
using Dates
using Artifacts

import ClimaUtilities
import ClimaUtilities: DataHandling
import ClimaUtilities: TimeVaryingInputs

import ClimaCore: Domains, Geometry, Fields, Meshes, Topologies, Spaces
import ClimaComms
@static pkgversion(ClimaComms) >= v"0.6" && ClimaComms.@import_required_backends

import Interpolations
import NCDatasets
import ClimaCoreTempestRemap

const context = ClimaComms.context()
ClimaComms.init(context)
const singleton_cpu_context =
    ClimaComms.SingletonCommsContext(ClimaComms.device())

include("TestTools.jl")

@testset "Analytic TimeVaryingInput" begin
    fun = (x) -> 2x
    input = TimeVaryingInputs.TimeVaryingInput(fun)

    FT = Float32

    # Prepare a field
    domain = Domains.IntervalDomain(
        Geometry.ZPoint{FT}(0),
        Geometry.ZPoint{FT}(5),
        boundary_names = (:bottom, :top),
    )
    mesh = Meshes.IntervalMesh(domain; nelems = 10)
    topology = Topologies.IntervalTopology(singleton_cpu_context, mesh)

    column_space = Spaces.CenterFiniteDifferenceSpace(topology)
    column_field = Fields.zeros(column_space)

    TimeVaryingInputs.evaluate!(column_field, input, 10.0)
    @test Array(parent(column_field))[1] == fun(10.0)

    # Check with args and kwargs
    fun2 = (x, y; z) -> 2x * y * z
    input2 = TimeVaryingInputs.TimeVaryingInput(fun2)

    TimeVaryingInputs.evaluate!(column_field, input2, 10.0, 20.0; z = 30.0)
    @test Array(parent(column_field))[1] == fun2(10.0, 20.0; z = 30.0)
end

@testset "InterpolatingTimeVaryingInput0D" begin
    # Check times not sorted
    xs = [1.0, 0.0]
    ys = [1.0, 2.0]

    @test_throws ErrorException TimeVaryingInputs.TimeVaryingInput(xs, ys)

    # Test with PeriodicCalendar with a given period
    # This is not allowed for 1D data because we don't have dates
    @test_throws ErrorException TimeVaryingInputs.TimeVaryingInput(
        sort(xs),
        ys,
        method = TimeVaryingInputs.NearestNeighbor(
            TimeVaryingInputs.PeriodicCalendar(Month(1), Date(2024)),
        ),
    )

    # Test with LinearPeriodFillingInterpolation with a given period
    # This is not allowed for 1D data because we don't have dates
    @test_throws ErrorException TimeVaryingInputs.TimeVaryingInput(
        sort(xs),
        ys,
        method = TimeVaryingInputs.LinearPeriodFillingInterpolation(),
    )

    # Test PeriodicCalendar with non simple duration
    @test_throws ErrorException TimeVaryingInputs.PeriodicCalendar(
        Month(2),
        Date(2024),
    )

    # Test LinearPeriodFillingInterpolation with non simple duration
    @test_throws ErrorException TimeVaryingInputs.LinearPeriodFillingInterpolation(
        Month(2),
        TimeVaryingInputs.Throw(),
    )

    # Test LinearPeriodFillingInterpolation with PeriodicCalendar (they are incompatible)
    @test_throws ErrorException TimeVaryingInputs.LinearPeriodFillingInterpolation(
        Year(1),
        TimeVaryingInputs.PeriodicCalendar(),
    )

    for FT in (Float32, Float64)
        # Prepare spaces/fields

        domain = Domains.IntervalDomain(
            Geometry.ZPoint{FT}(0),
            Geometry.ZPoint{FT}(5),
            boundary_names = (:bottom, :top),
        )
        mesh = Meshes.IntervalMesh(domain; nelems = 10)
        topology = Topologies.IntervalTopology(singleton_cpu_context, mesh)

        column_space = Spaces.CenterFiniteDifferenceSpace(topology)
        point_space = Spaces.level(column_space, 1)
        column_field = Fields.zeros(column_space)
        point_field = Fields.zeros(point_space)

        times = collect(range(FT(0), FT(8π), 100))
        vals = sin.(times)
        dt = times[2] - times[1]

        # Nearest neighbor interpolation
        input = TimeVaryingInputs.TimeVaryingInput(
            times,
            vals;
            method = TimeVaryingInputs.NearestNeighbor(),
        )

        # Nearest neighbor interpolation with Flat
        input_clamp = TimeVaryingInputs.TimeVaryingInput(
            times,
            vals;
            method = TimeVaryingInputs.NearestNeighbor(
                TimeVaryingInputs.Flat(),
            ),
        )

        # Nearest neighbor interpolation with PeriodicCalendar
        input_periodic_calendar = TimeVaryingInputs.TimeVaryingInput(
            times,
            vals;
            method = TimeVaryingInputs.NearestNeighbor(
                TimeVaryingInputs.PeriodicCalendar(),
            ),
        )

        # Linear interpolation with PeriodicCalendar
        input_periodic_calendar_linear = TimeVaryingInputs.TimeVaryingInput(
            times,
            vals;
            method = TimeVaryingInputs.LinearInterpolation(
                TimeVaryingInputs.PeriodicCalendar(),
            ),
        )

        # Test extrapolation_bc
        @test TimeVaryingInputs.extrapolation_bc(
            TimeVaryingInputs.NearestNeighbor(),
        ) == TimeVaryingInputs.Throw()

        # Test in
        @test FT(3.0) in input
        @test !(FT(-3.0) in input)

        # Test with different types of spaces
        for dest in (point_field, column_field)
            # Time outside of range
            @test_throws ErrorException TimeVaryingInputs.evaluate!(
                dest,
                input,
                FT(-4),
            )

            # Time outside of range with Flat left
            TimeVaryingInputs.evaluate!(dest, input_clamp, FT(-4))

            @test Array(parent(dest))[1] == vals[begin]

            # Time outside of range with Flat right
            TimeVaryingInputs.evaluate!(dest, input_clamp, FT(40))

            @test Array(parent(dest))[1] == vals[end]

            # Time outside of range with PeriodicCalendar
            TimeVaryingInputs.evaluate!(
                dest,
                input_periodic_calendar,
                times[begin],
            )
            @test Array(parent(dest))[1] == vals[begin]

            TimeVaryingInputs.evaluate!(
                dest,
                input_periodic_calendar,
                times[end],
            )
            @test Array(parent(dest))[1] == vals[end]

            TimeVaryingInputs.evaluate!(
                dest,
                input_periodic_calendar,
                times[end] + 10dt,
            )
            @test Array(parent(dest))[1] == vals[begin + 9]

            # Check after times[end] but before times[end] + 0.5dt, should lead be
            # equivalent to times[end]
            TimeVaryingInputs.evaluate!(
                dest,
                input_periodic_calendar,
                times[end] + 0.3dt,
            )
            @test Array(parent(dest))[1] == vals[end]

            # Check after times[end] and after times[end] + 0.5dt, should lead be equivalent
            # to times[begin]
            TimeVaryingInputs.evaluate!(
                dest,
                input_periodic_calendar,
                times[end] + 0.8dt,
            )
            @test Array(parent(dest))[1] == vals[begin]

            # Linear interpolation

            TimeVaryingInputs.evaluate!(dest, input, times[10])

            @test Array(parent(dest))[1] == vals[10]

            # Linear interpolation
            input = TimeVaryingInputs.TimeVaryingInput(times, vals)

            TimeVaryingInputs.evaluate!(dest, input, 0.1)

            index = searchsortedfirst(times, 0.1)
            @test times[index - 1] <= 0.1 <= times[index]
            expected =
                vals[index - 1] +
                (vals[index] - vals[index - 1]) /
                (times[index] - times[index - 1]) * (0.1 - times[index - 1])

            @test Array(parent(dest))[1] ≈ expected

            # Check edge case
            TimeVaryingInputs.evaluate!(dest, input, 0.0)

            @test Array(parent(dest))[1] ≈ 0.0

            # Linear interpolation with PeriodicCalendar
            TimeVaryingInputs.evaluate!(
                dest,
                input_periodic_calendar_linear,
                times[10],
            )
            @test Array(parent(dest))[1] == vals[10]

            TimeVaryingInputs.evaluate!(
                dest,
                input_periodic_calendar_linear,
                times[1],
            )
            @test Array(parent(dest))[1] == vals[1]

            TimeVaryingInputs.evaluate!(
                dest,
                input_periodic_calendar_linear,
                times[end],
            )
            @test Array(parent(dest))[1] == vals[end]

            # t_end + dt is equivalent to t_init
            TimeVaryingInputs.evaluate!(
                dest,
                input_periodic_calendar_linear,
                times[end] + dt,
            )
            @test Array(parent(dest))[1] ≈ vals[1]

            # t_end + 2dt is equivalent to t_init + dt
            TimeVaryingInputs.evaluate!(
                dest,
                input_periodic_calendar_linear,
                times[end] + 2dt,
            )
            @test Array(parent(dest))[1] ≈ vals[2]

            # In between t_end and t_init
            expected = vals[end] + (vals[begin] - vals[end]) / dt * 0.1dt
            TimeVaryingInputs.evaluate!(
                dest,
                input_periodic_calendar_linear,
                times[end] + 0.1dt,
            )
            @test Array(parent(dest))[1] ≈ expected
        end
    end
end
