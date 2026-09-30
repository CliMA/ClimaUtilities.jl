using Test
using Dates

import ClimaUtilities
import ClimaUtilities: TimeVaryingInputs
import ClimaUtilities.TimeManager: ITime, date, period, epoch

import ClimaCore: Domains, Fields, Geometry, Grids, Meshes, Spaces, Topologies
import ClimaComms
@static pkgversion(ClimaComms) >= v"0.6" && ClimaComms.@import_required_backends

const context = ClimaComms.context()
ClimaComms.init(context)

include("TestTools.jl")

# Interpolate each row of vals at time with a scalar 0D input
function evaluate_0d(times, vals::AbstractMatrix, time; method)
    return map(axes(vals, 1)) do k
        input = TimeVaryingInputs.TimeVaryingInput(times, vals[k, :]; method)
        dest = zeros(eltype(vals), 1)
        TimeVaryingInputs.evaluate!(dest, input, time)
        dest[1]
    end
end

# Evaluate itp into dest and compare every column with the 0D input of its
# segment, built from ref_times
function check_columns(dest, itp, ref_times, vals, column_segment, time; method)
    TimeVaryingInputs.evaluate!(dest, itp, time)
    arr = Array(Fields.field2array(dest))
    arr = ndims(arr) == 1 ? reshape(arr, 1, :) : arr
    for (c, s) in enumerate(column_segment)
        @test arr[:, c] ≈ evaluate_0d(ref_times[s], vals[s], time; method)
    end
end

# Values on nlevels levels at the nodes of each segment, given in hours
segment_values(FT, nlevels, hours) = [
    [FT(s) * sin(FT(h)) + FT(k) for k in 1:nlevels, h in hours[s]] for
    s in eachindex(hours)
]

@testset "RaggedInterpolatingTimeVaryingInput" begin
    start_date = DateTime(2014)
    # Nodes of four segments with different spacing and range, in hours, and
    # the same nodes as ITime counters with a different period per segment
    hours = (0.0:1.0:10.0, 0.5:0.5:9.0, 2.0:2.0:12.0, -1.0:1.0:7.0)
    counters = (0:2:20, 2:2:36, 2:2:12, -2:2:14)
    periods = (Minute(30), Minute(15), Hour(1), Minute(30))
    floats(FT) = [collect(FT, 3600 .* h) for h in hours]
    itimes(ep) = [
        [ITime(c; period = p, epoch = ep) for c in cs] for
        (cs, p) in zip(counters, periods)
    ]
    dates = [start_date .+ Minute.(round.(Int, 60 .* h)) for h in hours]
    ms_itimes = [
        [
            ITime(
                Dates.value(d - start_date);
                period = Millisecond(1),
                epoch = start_date,
            ) for d in ds
        ] for ds in dates
    ]
    # Hours inside and outside the range common to all segments, and the
    # first segment not covering each of the latter
    inside = (2.0, 3.25, 6.75, 7.0)
    outside = (8.5, 0.25, 13.0, -3.0)
    uncovered = (4, 2, 1, 1)

    for FT in (Float32, Float64)
        (;
            center_space,
            level_space,
            horizontal_space,
            column_space,
            point_space,
        ) = make_column_spaces(FT; nlevels = 5, z_max = FT(5))

        vals = segment_values(FT, 5, hours)
        surface_vals = segment_values(FT, 1, hours)
        AT = ClimaComms.array_type(ClimaComms.device(center_space))

        @testset "Construction, FT = $FT" begin
            times = floats(FT)
            itp = TimeVaryingInputs.TimeVaryingInput(times, vals, center_space)
            @test itp.times isa AT && itp.vals isa AT
            @test Array(itp.times) == reduce(vcat, times)
            @test Array(itp.offsets) == [1, 12, 30, 36, 45]
            @test Array(itp.vals) == reduce(hcat, vals)
            @test Array(itp.column_segment) == 1:4
            @test itp.range == (FT(2 * 3600), FT(7 * 3600))
            @test all(
                s -> TimeVaryingInputs.segment_times(itp, s) == times[s],
                1:4,
            )
            @test FT(3 * 3600) in itp
            @test !(FT(3600) in itp) && !(FT(8 * 3600) in itp)

            # ITimes are promoted to a common period across segments
            for ep in (nothing, start_date)
                itp = TimeVaryingInputs.TimeVaryingInput(
                    itimes(ep),
                    vals,
                    center_space,
                )
                for s in 1:4
                    st = TimeVaryingInputs.segment_times(itp, s)
                    @test st == itimes(ep)[s]
                    @test all(
                        t -> period(t) == Minute(15) && epoch(t) == ep,
                        st,
                    )
                end
                @test itp.range == (
                    ITime(2; period = Hour(1), epoch = ep),
                    ITime(7; period = Hour(1), epoch = ep),
                )
                @test ITime(3; period = Hour(1), epoch = ep) in itp
            end
            # ITimes without an epoch are counted from epoch
            itp = TimeVaryingInputs.TimeVaryingInput(
                itimes(nothing),
                vals,
                center_space;
                epoch = start_date,
            )
            @test start_date + Hour(3) in itp

            # Number times have no epoch
            @test_logs (:warn, r"epoch is not used") TimeVaryingInputs.TimeVaryingInput(
                times,
                vals,
                center_space;
                epoch = start_date,
            )

            # Dates become ITimes counted from epoch
            @test_throws "epoch is required" TimeVaryingInputs.TimeVaryingInput(
                dates,
                vals,
                center_space,
            )
            itp = TimeVaryingInputs.TimeVaryingInput(
                dates,
                vals,
                center_space;
                epoch = start_date,
            )
            @test all(
                s -> date.(TimeVaryingInputs.segment_times(itp, s)) == dates[s],
                1:4,
            )
            @test start_date + Hour(3) in itp

            # Warn only when the segments repeat with different periods
            periodic = TimeVaryingInputs.LinearInterpolation(
                TimeVaryingInputs.PeriodicCalendar(),
            )
            @test_logs (:warn, r"different periods") TimeVaryingInputs.TimeVaryingInput(
                times,
                vals,
                center_space;
                method = periodic,
            )
            equal_hours = (0.0:1.0:10.0, 0.0:0.5:10.5)
            @test_logs TimeVaryingInputs.TimeVaryingInput(
                [collect(FT, 3600 .* h) for h in equal_hours],
                segment_values(FT, 5, equal_hours),
                center_space;
                column_segment = [1, 2, 1, 2],
                method = periodic,
            )
            # Segments that no column reads are not compared
            @test_logs TimeVaryingInputs.TimeVaryingInput(
                times,
                vals,
                center_space;
                column_segment = [1, 1, 1, 1],
                method = periodic,
            )
        end

        @testset "Evaluation, FT = $FT" begin
            to_itime(t; kwargs...) =
                ITime(round(Int, 60t); period = Minute(1), kwargs...)
            to_date(t) = start_date + Minute(round(Int, 60t))
            # Times of the segments, times for the 0D reference, and
            # conversions of hours to the time passed to evaluate!
            kinds = (
                (floats(FT), floats(FT), (t -> FT(3600t), t -> ITime(3600t))),
                (itimes(nothing), itimes(nothing), (to_itime, t -> 3600t)),
                (
                    itimes(start_date),
                    itimes(start_date),
                    (t -> to_itime(t; epoch = start_date), t -> 3600t, to_date),
                ),
                (
                    dates,
                    ms_itimes,
                    (t -> to_itime(t; epoch = start_date), t -> 3600t, to_date),
                ),
            )
            methods = (
                TimeVaryingInputs.LinearInterpolation(),
                TimeVaryingInputs.LinearInterpolation(TimeVaryingInputs.Flat()),
                TimeVaryingInputs.LinearInterpolation(
                    TimeVaryingInputs.PeriodicCalendar(),
                ),
                TimeVaryingInputs.NearestNeighbor(),
                TimeVaryingInputs.NearestNeighbor(TimeVaryingInputs.Flat()),
                TimeVaryingInputs.NearestNeighbor(
                    TimeVaryingInputs.PeriodicCalendar(),
                ),
            )
            dest = Fields.zeros(center_space)
            for (times, ref_times, converters) in kinds, method in methods
                bc = TimeVaryingInputs.extrapolation_bc(method)
                ep = eltype(first(times)) <: Number ? nothing : start_date
                make() = TimeVaryingInputs.TimeVaryingInput(
                    times,
                    vals,
                    center_space;
                    method,
                    epoch = ep,
                )
                itp = if bc isa TimeVaryingInputs.PeriodicCalendar
                    @test_logs (:warn, r"different periods") make()
                else
                    make()
                end
                for convert in converters
                    for t in inside
                        check_columns(
                            dest,
                            itp,
                            ref_times,
                            vals,
                            1:4,
                            convert(t);
                            method,
                        )
                    end
                    for (t, s) in zip(outside, uncovered)
                        if bc isa TimeVaryingInputs.Throw
                            @test_throws "Column $s of TimeVaryingInput reads segment $s, which does not cover time" TimeVaryingInputs.evaluate!(
                                dest,
                                itp,
                                convert(t),
                            )
                        else
                            check_columns(
                                dest,
                                itp,
                                ref_times,
                                vals,
                                1:4,
                                convert(t);
                                method,
                            )
                        end
                    end
                end
            end

            # Several columns reading one segment
            times = floats(FT)
            linear = TimeVaryingInputs.LinearInterpolation()
            column_segment = [1, 1, 3, 2]
            itp = TimeVaryingInputs.TimeVaryingInput(
                times,
                vals,
                center_space;
                column_segment,
            )
            @test Array(itp.column_segment) == column_segment
            for t in inside
                check_columns(
                    dest,
                    itp,
                    times,
                    vals,
                    column_segment,
                    FT(3600t);
                    method = linear,
                )
            end

            # A segment that no column reads does not restrict the range
            itp = TimeVaryingInputs.TimeVaryingInput(
                times[[1, 3]],
                vals[[1, 3]],
                center_space;
                column_segment = [1, 1, 1, 1],
            )
            @test FT(3600) in itp
            check_columns(
                dest,
                itp,
                times,
                vals,
                [1, 1, 1, 1],
                FT(3600);
                method = linear,
            )

            # A node returns the stored values exactly
            itp = TimeVaryingInputs.TimeVaryingInput(times, vals, center_space)
            TimeVaryingInputs.evaluate!(dest, itp, FT(2 * 3600))
            arr = Array(Fields.field2array(dest))
            for s in 1:4
                @test arr[:, s] == vals[s][:, findfirst(==(2.0), hours[s])]
            end

            # Single-level segments into a level and a horizontal space
            itp = TimeVaryingInputs.TimeVaryingInput(
                times,
                surface_vals,
                level_space,
            )
            for dest in
                (Fields.zeros(level_space), Fields.zeros(horizontal_space)),
                t in inside

                check_columns(
                    dest,
                    itp,
                    times,
                    surface_vals,
                    1:4,
                    FT(3600t);
                    method = linear,
                )
            end

            # The same times everywhere reproduce the multi-point input
            matrix = [FT(c) * sin(FT(h)) for c in 1:4, h in hours[1]]
            multipoint = TimeVaryingInputs.TimeVaryingInput(
                times[1],
                matrix,
                level_space,
            )
            ragged = TimeVaryingInputs.TimeVaryingInput(
                [times[1] for _ in 1:4],
                [matrix[c:c, :] for c in 1:4],
                level_space,
            )
            dest_multipoint, dest_ragged =
                Fields.zeros(level_space), Fields.zeros(level_space)
            for t in (inside..., 9.5)
                TimeVaryingInputs.evaluate!(
                    dest_multipoint,
                    multipoint,
                    FT(3600t),
                )
                TimeVaryingInputs.evaluate!(dest_ragged, ragged, FT(3600t))
                @test Array(Fields.field2array(dest_ragged)) ==
                      Array(Fields.field2array(dest_multipoint))
            end

            # One segment on a column and on a point
            itp = TimeVaryingInputs.TimeVaryingInput(
                times[1:1],
                vals[1:1],
                column_space,
            )
            for t in inside
                check_columns(
                    Fields.zeros(column_space),
                    itp,
                    times,
                    vals,
                    [1],
                    FT(3600t);
                    method = linear,
                )
            end
            itp = TimeVaryingInputs.TimeVaryingInput(
                times[1:1],
                surface_vals[1:1],
                point_space,
            )
            for t in inside
                check_columns(
                    Fields.zeros(point_space),
                    itp,
                    times,
                    surface_vals,
                    [1],
                    FT(3600t);
                    method = linear,
                )
            end
        end

        @testset "Errors, FT = $FT" begin
            times = floats(FT)
            @test_throws "different lengths" TimeVaryingInputs.TimeVaryingInput(
                times[1:3],
                vals,
                center_space,
            )
            @test_throws "column_segment has 2 entries" TimeVaryingInputs.TimeVaryingInput(
                times,
                vals,
                center_space;
                column_segment = [1, 2],
            )
            @test_throws "does not exist" TimeVaryingInputs.TimeVaryingInput(
                times,
                vals,
                center_space;
                column_segment = [1, 2, 3, 5],
            )
            @test_throws "last dimension of vals" TimeVaryingInputs.TimeVaryingInput(
                times[1:1],
                vals[2:2],
                column_space,
            )
            @test_throws "rows, but the space has 1 levels" TimeVaryingInputs.TimeVaryingInput(
                times,
                vals,
                level_space,
            )
            @test_throws "at least two times" TimeVaryingInputs.TimeVaryingInput(
                [times[1][1:1]],
                [vals[1][:, 1:1]],
                column_space,
            )
            @test_throws "strictly increasing" TimeVaryingInputs.TimeVaryingInput(
                [reverse(times[1])],
                vals[1:1],
                column_space,
            )
            @test_throws "one kind" TimeVaryingInputs.TimeVaryingInput(
                [times[1], itimes(nothing)[2]],
                vals[1:2],
                center_space;
                column_segment = [1, 2, 1, 2],
            )
            @test_throws "non uniform" TimeVaryingInputs.TimeVaryingInput(
                [FT[0, 1, 3]],
                [vals[1][:, 1:3]],
                column_space;
                method = TimeVaryingInputs.LinearInterpolation(
                    TimeVaryingInputs.PeriodicCalendar(),
                ),
            )
            @test_throws "PeriodicCalendar(period)" TimeVaryingInputs.TimeVaryingInput(
                times[1:1],
                vals[1:1],
                column_space;
                method = TimeVaryingInputs.LinearInterpolation(
                    TimeVaryingInputs.PeriodicCalendar(Year(1), start_date),
                ),
            )
            @test_throws "LinearPeriodFillingInterpolation is not supported" TimeVaryingInputs.TimeVaryingInput(
                times[1:1],
                vals[1:1],
                column_space;
                method = TimeVaryingInputs.LinearPeriodFillingInterpolation(),
            )
            @test_throws MethodError TimeVaryingInputs.TimeVaryingInput(
                times[1:1],
                vals[1:1],
                make_box_space(FT),
            )
            @test_throws "does not match the epoch" TimeVaryingInputs.TimeVaryingInput(
                itimes(start_date),
                vals,
                center_space;
                epoch = start_date + Day(1),
            )
            # Large integer times collide once promoted to Float32
            @test_throws "strictly increasing" TimeVaryingInputs.TimeVaryingInput(
                AbstractVector[[2^24, 2^24 + 1, 2^24 + 2], Float32[0, 1, 2]],
                [vals[1][:, 1:3], vals[2][:, 1:3]],
                center_space;
                column_segment = [1, 2, 1, 2],
            )
            itp = TimeVaryingInputs.TimeVaryingInput(times, vals, center_space)
            @test_throws "dest is not defined on the space" TimeVaryingInputs.evaluate!(
                Fields.zeros(level_space),
                itp,
                FT(3 * 3600),
            )
            @test_throws "Cannot evaluate" TimeVaryingInputs.evaluate!(
                Fields.zeros(center_space),
                itp,
                start_date,
            )
        end
    end
end
