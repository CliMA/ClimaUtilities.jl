using Test
using Dates
using Artifacts

import ClimaUtilities
import ClimaUtilities: DataHandling
import ClimaUtilities: TimeVaryingInputs
using ClimaUtilities.TimeManager

import ClimaCore:
    CommonSpaces, Domains, Geometry, Fields, Grids, Meshes, Topologies, Spaces
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

# A collection of functions for testing with vector and matrix inputs for the
# TimeVaryingInputs
value_at(vals::AbstractVector, k) = vals[k]
value_at(vals::AbstractMatrix, k) = vals[:, k]

read_value(dest, _::AbstractVector) = Array(parent(dest))[1]
read_value(dest, _::AbstractMatrix) = vec(Array(Fields.field2array(dest)))

make_input(times, vals::AbstractVector, _space; kwargs...) =
    TimeVaryingInputs.TimeVaryingInput(times, vals; kwargs...)
make_input(times, vals::AbstractMatrix, space; kwargs...) =
    TimeVaryingInputs.TimeVaryingInput(times, vals, space; kwargs...)

# This is for a single point where the time series data is on CPU
check_vals(input, vals::AbstractVector, _) = @test input.vals == vals
# This is for multiple points where the time series data is on GPU
function check_vals(input, vals::AbstractMatrix, space)
    @test input.vals isa ClimaComms.array_type(ClimaComms.device(space))
    @test Array(input.vals) == vals
end

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

    # test promote when some input times do not contain an epoch
    promotion_tvi = TimeVaryingInputs.TimeVaryingInput(
        [ITime(0; epoch = DateTime(2010)), ITime(2; period = Dates.Day(1))],
        ys,
    )
    @test all(t -> t.epoch == DateTime(2010), promotion_tvi.times)
    @test all(t -> t.period == Dates.Second(1), promotion_tvi.times)


    # test with ITimes with different Epochs
    @test_throws ErrorException TimeVaryingInputs.TimeVaryingInput(
        [ITime(0; epoch = DateTime(2010)), ITime(1; epoch = DateTime(2011))],
        ys,
    )

    # test with non-uniformly spaced ITimes
    @test_throws ErrorException TimeVaryingInputs.TimeVaryingInput(
        [ITime(0; epoch = DateTime(2010)), ITime(1), ITime(3), ITime(4)],
        [1.0, 2.0, 3.0, 4.0];
        method = TimeVaryingInputs.NearestNeighbor(
            TimeVaryingInputs.PeriodicCalendar(),
        ),
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

        # Prepare times in terms of ITime and floating point
        start_date = Dates.DateTime(2014)
        times_ft = collect(FT(0):FT(0.5):FT(100))
        itime_no_epoch = [promote(ITime.(times_ft)...)...]
        add_test_epoch = t -> promote(t, ITime(0; epoch = start_date))[1]
        itime_with_epoch = [promote(add_test_epoch.(itime_no_epoch)...)...]

        points = [
            Geometry.LatLongPoint(FT(lat), FT(long)) for (lat, long) in
            zip((-30.0, 0.0, 30.0, 60.0), (0.0, 45.0, 90.0, 180.0))
        ]
        center_space = MultiColumnSpace(
            FT;
            points,
            z_elem = 10,
            z_min = FT(0),
            z_max = FT(5),
            radius = FT(6.371229e6),
            staggering = Grids.CellCenter(),
        )
        cloud_space = Spaces.level(center_space, 1)
        ncols = Spaces.ncolumns(cloud_space)
        @test ncols == length(points)
        single_level_space = MultiColumnSpace(
            FT;
            points,
            z_elem = 1,
            z_min = FT(0),
            z_max = FT(5),
            radius = FT(6.371229e6),
            staggering = Grids.CellCenter(),
        )

        # Cases are in the form of (case_label, vals, space, dests)
        scalar_cases = [(
            "scalar vals",
            sin.(times_ft),
            point_space,
            (point_field, column_field),
        ),]
        matrix_cases = [
            (
                "matrix vals, 1 column",
                collect(reshape(sin.(times_ft), 1, :)),
                point_space,
                (Fields.zeros(point_space),),
            ),
            (
                "matrix vals, $ncols points",
                [FT(c) * sin(t) + FT(c - 1) for c in 1:ncols, t in times_ft],
                cloud_space,
                (
                    Fields.zeros(cloud_space),
                    Fields.zeros(Spaces.horizontal_space(center_space)),
                ),
            ),
            (
                "matrix vals, $ncols points, single vertical level",
                [FT(c) * sin(t) + FT(c - 1) for c in 1:ncols, t in times_ft],
                single_level_space,
                (Fields.zeros(single_level_space),),
            ),
        ]
        cases = [scalar_cases..., matrix_cases...]

        # case_label is used for the name of the testset
        # vals is the time series data to build the TimeVaryingInput
        # dests is an iterable of fields defined on the space that will be
        # interpolated onto
        for (case_label, vals, space, dests) in cases
            @testset "$case_label, FT = $FT" begin
                # tuple where first element is vector used to create test TimeVaryingInputs
                # second element converts floats into the desired test inputs
                # third element converts the elements of the times vector to the desired test inputs
                for (times, ft_to_input, time_to_input) in (
                    (times_ft, identity, identity), # FT TVI, inputs as FT
                    (times_ft, ITime, ITime), # FT TVI, inputs as ITime no date
                    (
                        times_ft,
                        t -> add_test_epoch(ITime(t)),
                        t -> add_test_epoch(ITime(t)),
                    ), # FT TVI, inputs as ITime with date
                    (itime_no_epoch, ITime, identity), # ITime TVI no dates, inputs as ITime (no dates)
                    (itime_no_epoch, identity, float), # ITime TVI no dates, inputs as floats
                    (
                        itime_no_epoch,
                        t -> add_test_epoch(ITime(t)),
                        add_test_epoch,
                    ), # ITime TVI no dates, inputs as ITime with dates
                    (itime_with_epoch, t -> add_test_epoch(ITime(t)), identity), # ITime TVI with dates, inputs as ITime with dates
                    (
                        itime_with_epoch,
                        t -> ITime(t),
                        t -> ITime(t.counter; period = t.period),
                    ), # ITime TVI with dates, inputs as ITime with no dates
                    (itime_with_epoch, identity, float), # ITime TVI with dates, inputs as floats
                    (
                        itime_with_epoch,
                        t ->
                            start_date +
                            Millisecond(round(Int, 1000 * Float64(t))),
                        DateTime,
                    ), # ITime TVI with dates, inputs as datetimes
                )
                    dt = times[2] - times[1]
                    # Nearest neighbor interpolation
                    input = make_input(
                        times,
                        vals,
                        space;
                        method = TimeVaryingInputs.NearestNeighbor(),
                    )

                    # Nearest neighbor interpolation with Flat
                    input_clamp = make_input(
                        times,
                        vals,
                        space;
                        method = TimeVaryingInputs.NearestNeighbor(
                            TimeVaryingInputs.Flat(),
                        ),
                    )

                    # Linear interpolation
                    input_linear = make_input(times, vals, space)

                    # Linear interpolation with Flat
                    input_flat_linear = make_input(
                        times,
                        vals,
                        space;
                        method = TimeVaryingInputs.LinearInterpolation(
                            TimeVaryingInputs.Flat(),
                        ),
                    )

                    # Nearest neighbor interpolation with PeriodicCalendar
                    input_periodic_calendar = make_input(
                        times,
                        vals,
                        space;
                        method = TimeVaryingInputs.NearestNeighbor(
                            TimeVaryingInputs.PeriodicCalendar(),
                        ),
                    )

                    # Linear interpolation with PeriodicCalendar
                    input_periodic_calendar_linear = make_input(
                        times,
                        vals,
                        space;
                        method = TimeVaryingInputs.LinearInterpolation(
                            TimeVaryingInputs.PeriodicCalendar(),
                        ),
                    )

                    # Test extrapolation_bc
                    @test TimeVaryingInputs.extrapolation_bc(
                        TimeVaryingInputs.NearestNeighbor(),
                    ) == TimeVaryingInputs.Throw()

                    check_vals(input, vals, space)

                    # Test in
                    if ft_to_input(FT(3.0)) isa eltype(times)
                        @test FT(3.0) in input
                        @test !(FT(-3.0) in input)
                    end

                    for dest in dests
                        # Time outside of range
                        @test_throws ErrorException TimeVaryingInputs.evaluate!(
                            dest,
                            input,
                            ft_to_input(FT(-4)),
                        )

                        # Time outside of range with Flat left
                        TimeVaryingInputs.evaluate!(
                            dest,
                            input_clamp,
                            ft_to_input(FT(-4)),
                        )
                        @test read_value(dest, vals) == value_at(vals, 1)

                        # Time outside of range with Flat right
                        TimeVaryingInputs.evaluate!(
                            dest,
                            input_clamp,
                            ft_to_input(FT(400)),
                        )
                        @test read_value(dest, vals) ==
                              value_at(vals, length(times))

                        # Time inside of range with Flat
                        TimeVaryingInputs.evaluate!(
                            dest,
                            input_clamp,
                            time_to_input(times[10]),
                        )
                        @test read_value(dest, vals) == value_at(vals, 10)

                        # Time inside of range, between snapshots, with Flat
                        TimeVaryingInputs.evaluate!(
                            dest,
                            input_clamp,
                            time_to_input(times[10] + 0.3dt),
                        )
                        @test read_value(dest, vals) == value_at(vals, 10)

                        # Time outside of range with PeriodicCalendar
                        TimeVaryingInputs.evaluate!(
                            dest,
                            input_periodic_calendar,
                            time_to_input(times[begin]),
                        )
                        @test read_value(dest, vals) == value_at(vals, 1)

                        TimeVaryingInputs.evaluate!(
                            dest,
                            input_periodic_calendar,
                            time_to_input(times[end]),
                        )
                        @test read_value(dest, vals) ==
                              value_at(vals, length(times))

                        TimeVaryingInputs.evaluate!(
                            dest,
                            input_periodic_calendar,
                            time_to_input(times[end] + 10dt),
                        )
                        @test read_value(dest, vals) == value_at(vals, 10)

                        # Check after times[end] but before times[end] + 0.5dt,
                        # should lead be equivalent to times[end]
                        TimeVaryingInputs.evaluate!(
                            dest,
                            input_periodic_calendar,
                            time_to_input(times[end] + 0.3dt),
                        )
                        @test read_value(dest, vals) ==
                              value_at(vals, length(times))

                        # Check after times[end] and after times[end] + 0.5dt,
                        # should lead be equivalent to times[begin]
                        TimeVaryingInputs.evaluate!(
                            dest,
                            input_periodic_calendar,
                            time_to_input(times[end] + 0.8dt),
                        )
                        @test read_value(dest, vals) == value_at(vals, 1)

                        # Linear interpolation

                        TimeVaryingInputs.evaluate!(
                            dest,
                            input,
                            time_to_input(times[10]),
                        )

                        @test read_value(dest, vals) == value_at(vals, 10)

                        # Linear interpolation
                        TimeVaryingInputs.evaluate!(
                            dest,
                            input_linear,
                            ft_to_input(FT(10)),
                        )
                        linear_in_range = read_value(dest, vals)

                        # Time in range with Flat
                        TimeVaryingInputs.evaluate!(
                            dest,
                            input_flat_linear,
                            ft_to_input(FT(10)),
                        )
                        @test read_value(dest, vals) ≈ linear_in_range

                        if eltype(times) <: AbstractFloat
                            # searchsortedfirst only needs to work with floats, as TVI0d will
                            # internally handle conversions
                            TimeVaryingInputs.evaluate!(
                                dest,
                                input_linear,
                                ft_to_input(FT(0.25)),
                            )
                            index = searchsortedfirst(times, FT(0.25))
                            @test times[index - 1] <= FT(0.25) <= times[index]
                            expected =
                                value_at(vals, index - 1) +
                                (
                                    value_at(vals, index) -
                                    value_at(vals, index - 1)
                                ) / (times[index] - times[index - 1]) *
                                (FT(0.25) - times[index - 1])
                            @test read_value(dest, vals) ≈ expected
                        end

                        # Mid-grid linear query (w = 0.5), also exercised
                        # with ITime times
                        TimeVaryingInputs.evaluate!(
                            dest,
                            input_linear,
                            ft_to_input(FT(4.75)),
                        )
                        @test read_value(dest, vals) ≈
                              (value_at(vals, 10) + value_at(vals, 11)) / 2

                        # Check edge case
                        TimeVaryingInputs.evaluate!(
                            dest,
                            input_linear,
                            ft_to_input(FT(0.0)),
                        )
                        @test read_value(dest, vals) ≈ value_at(vals, 1)

                        # Linear interpolation with PeriodicCalendar
                        TimeVaryingInputs.evaluate!(
                            dest,
                            input_periodic_calendar_linear,
                            time_to_input(times[10]),
                        )
                        @test read_value(dest, vals) == value_at(vals, 10)

                        TimeVaryingInputs.evaluate!(
                            dest,
                            input_periodic_calendar_linear,
                            time_to_input(times[1]),
                        )
                        @test read_value(dest, vals) == value_at(vals, 1)

                        TimeVaryingInputs.evaluate!(
                            dest,
                            input_periodic_calendar_linear,
                            time_to_input(times[end]),
                        )
                        @test read_value(dest, vals) ==
                              value_at(vals, length(times))

                        # t_end + dt is equivalent to t_init
                        TimeVaryingInputs.evaluate!(
                            dest,
                            input_periodic_calendar_linear,
                            time_to_input(times[end] + dt),
                        )
                        @test read_value(dest, vals) ≈ value_at(vals, 1)

                        # t_end + 2dt is equivalent to t_init + dt
                        TimeVaryingInputs.evaluate!(
                            dest,
                            input_periodic_calendar_linear,
                            time_to_input(times[end] + 2dt),
                        )
                        @test read_value(dest, vals) ≈ value_at(vals, 2)

                        # In between t_end and t_init
                        expected =
                            value_at(vals, length(times)) .+
                            (
                                value_at(vals, 1) .-
                                value_at(vals, length(times))
                            ) ./ FT(float(dt)) .* FT(0.1 * float(dt))
                        TimeVaryingInputs.evaluate!(
                            dest,
                            input_periodic_calendar_linear,
                            time_to_input(times[end] + 0.1dt),
                        )
                        eltype(times) <: Number &&
                            @test read_value(dest, vals) ≈ expected
                    end
                end

                # test errors when using datetime with TVI of floats or ITime without epoch
                for dest in dests, times in (times_ft, itime_no_epoch)
                    input = make_input(
                        times,
                        vals,
                        space;
                        method = TimeVaryingInputs.NearestNeighbor(),
                    )
                    @test_throws ErrorException TimeVaryingInputs.evaluate!(
                        dest,
                        input,
                        start_date,
                    )
                end
            end
        end
    end
end

@testset "Matrix vals constructor validation" begin
    FT = Float32
    domain = Domains.IntervalDomain(
        Geometry.ZPoint{FT}(0),
        Geometry.ZPoint{FT}(5),
        boundary_names = (:bottom, :top),
    )
    mesh = Meshes.IntervalMesh(domain; nelems = 10)
    topology = Topologies.IntervalTopology(singleton_cpu_context, mesh)
    column_space = Spaces.CenterFiniteDifferenceSpace(topology)
    point_space = Spaces.level(column_space, 1)
    center_space = MultiColumnSpace(
        FT;
        points = [Geometry.LatLongPoint(FT(0), FT(0))],
        z_elem = 10,
        z_min = FT(0),
        z_max = FT(5),
        radius = FT(6.371229e6),
        staggering = Grids.CellCenter(),
    )

    times = FT[0, 1]

    # Times are not sorted
    @test_throws ErrorException TimeVaryingInputs.TimeVaryingInput(
        reverse(times),
        FT[1 2],
        point_space,
    )
    # Times and the last dimension of vals disagree
    @test_throws ErrorException TimeVaryingInputs.TimeVaryingInput(
        times,
        FT[1 2 3],
        point_space,
    )
    # The rows of vals must match the columns of the space
    @test_throws ErrorException TimeVaryingInputs.TimeVaryingInput(
        times,
        FT[1 2; 3 4],
        point_space,
    )
    # Spaces with a vertical component are rejected
    @test_throws ErrorException TimeVaryingInputs.TimeVaryingInput(
        times,
        FT[1 2],
        column_space,
    )
    @test_throws ErrorException TimeVaryingInputs.TimeVaryingInput(
        times,
        FT[1 2],
        center_space,
    )
end
