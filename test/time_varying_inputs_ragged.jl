using Test
using Dates

import ClimaUtilities
import ClimaUtilities: TimeVaryingInputs
import ClimaUtilities.FileReaders: DataSource
import ClimaUtilities.TimeManager: ITime, date, period, epoch
import ClimaUtilities.Utils: interpolate_columns!

import ClimaCore: Domains, Fields, Geometry, Grids, Meshes, Spaces, Topologies
import ClimaComms
@static pkgversion(ClimaComms) >= v"0.6" && ClimaComms.@import_required_backends
import Interpolations
import NCDatasets

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


@testset "InterpolatingTimeVaryingInputRagged" begin
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
        ) = make_spaces(FT; nlevels = 5, z_max = FT(5))

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
                make() = TimeVaryingInputs.TimeVaryingInput(
                    times,
                    vals,
                    center_space;
                    method,
                    epoch = start_date,
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
                            @test_throws "Segment $s of TimeVaryingInput does not cover time" TimeVaryingInputs.evaluate!(
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

@testset "TimeVaryingInput from DataSources" begin
    data_dir = mktempdir()
    start_date = DateTime(2010, 7, 1)
    # Two sites with different levels and time axes; ta is a column variable
    # and ts a surface one
    z_a = Float64[0, 1000, 2000, 3000, 4000, 5000]
    z_b = Float64[500, 1500, 2500, 3500, 4500, 5500]
    dates_a = start_date .+ Hour.(0:23)
    dates_b = start_date .+ Hour.(2:3:26)
    ta_a = [300 - 0.006z + t for z in z_a, t in 0:23]
    ta_b = [290 - 0.005z + 2t for z in z_b, t in 0:8]
    ua_a = [10 + 0.001z - 0.5t for z in z_a, t in 0:23]
    ua_b = [8 + 0.002z - t for z in z_b, t in 0:8]
    hus_a = [0.01 - 1e-6 * z + 1e-4 * t for z in z_a, t in 0:23]
    hus_b = [0.012 - 2e-6 * z + 2e-4 * t for z in z_b, t in 0:8]
    ts_a = 280 .+ (0:23)
    ts_b = 285 .+ 2 .* (0:8)
    file_a = write_column_file(
        joinpath(data_dir, "site_a.nc");
        z = z_a,
        dates = dates_a,
        variables = ["ta" => ta_a, "ua" => ua_a, "hus" => hus_a, "ts" => ts_a],
    )
    file_b = write_column_file(
        joinpath(data_dir, "site_b.nc");
        z = z_b,
        dates = dates_b,
        variables = ["ta" => ta_b, "ua" => ua_b, "hus" => hus_b, "ts" => ts_b],
        z_name = "height",
        time_first = true,
    )
    sources(name) =
        [DataSource(f, name) for f in (file_a, file_b, file_a, file_b)]
    # The second hour is a node of both sites
    node_date = start_date + Hour(2)

    for FT in (Float32, Float64)
        (;
            center_space,
            level_space,
            horizontal_space,
            column_space,
            point_space,
        ) = make_spaces(FT; nlevels = 10, z_max = FT(6000))
        model_z = model_levels(center_space)
        regrid(z, vals) = interpolate_columns!(
            zeros(FT, length(model_z), size(vals, 2)),
            model_z,
            z,
            vals,
        )

        itp = TimeVaryingInputs.TimeVaryingInput(
            sources("ta"),
            center_space;
            start_date,
        )
        @test Array(itp.column_segment) == [1, 2, 1, 2]
        @test length(itp.offsets) == 3
        @test date.(TimeVaryingInputs.segment_times(itp, 1)) == dates_a
        @test date.(TimeVaryingInputs.segment_times(itp, 2)) == dates_b

        # Node values are the file values regridded onto the model levels
        dest = Fields.zeros(center_space)
        TimeVaryingInputs.evaluate!(dest, itp, node_date)
        arr = Array(Fields.field2array(dest))
        @test arr[:, 1] == arr[:, 3] == regrid(z_a, ta_a)[:, 3]
        @test arr[:, 2] == arr[:, 4] == regrid(z_b, ta_b)[:, 1]

        # preprocess_func is applied to the values read
        doubled = TimeVaryingInputs.TimeVaryingInput(
            sources("ta"),
            center_space;
            start_date = Date(start_date),
            preprocess_func = x -> 2x,
        )
        TimeVaryingInputs.evaluate!(dest, doubled, node_date)
        @test Array(Fields.field2array(dest))[:, 1] ==
              2 .* regrid(z_a, ta_a)[:, 3]

        # time_transform shifts the nodes
        shifted = TimeVaryingInputs.TimeVaryingInput(
            [DataSource(file_a, "ta"; time_transform = d -> d + Hour(1))],
            column_space;
            start_date,
        )
        @test date.(TimeVaryingInputs.segment_times(shifted, 1)) ==
              dates_a .+ Hour(1)

        # Surface variables into spaces with a single level
        surface = TimeVaryingInputs.TimeVaryingInput(
            sources("ts"),
            level_space;
            start_date,
        )
        for dest in (Fields.zeros(level_space), Fields.zeros(horizontal_space))
            TimeVaryingInputs.evaluate!(dest, surface, node_date)
            @test vec(Array(Fields.field2array(dest))) ==
                  FT[ts_a[3], ts_b[1], ts_a[3], ts_b[1]]
        end

        # Composing variables equals composing single-variable inputs
        composed = TimeVaryingInputs.TimeVaryingInput(
            [sources("ta"), sources("ua"), sources("hus")],
            center_space;
            start_date,
            compose_function = (a, b, c) -> a .+ b .+ c,
        )
        parts = [
            TimeVaryingInputs.TimeVaryingInput(
                sources(name),
                center_space;
                start_date,
            ) for name in ("ta", "ua", "hus")
        ]
        for t in (node_date, node_date + Minute(20))
            TimeVaryingInputs.evaluate!(dest, composed, t)
            expected = sum(parts) do part
                part_dest = Fields.zeros(center_space)
                TimeVaryingInputs.evaluate!(part_dest, part, t)
                Array(Fields.field2array(part_dest))
            end
            @test Array(Fields.field2array(dest)) ≈ expected
        end
        @test_throws "compose_function is required" TimeVaryingInputs.TimeVaryingInput(
            [sources("ta"), sources("ua")],
            center_space;
            start_date,
        )
        @test_throws "one source per column" TimeVaryingInputs.TimeVaryingInput(
            [sources("ta"), sources("ua")[1:2]],
            center_space;
            start_date,
            compose_function = +,
        )
        @test_throws "share their dates" TimeVaryingInputs.TimeVaryingInput(
            [[DataSource(file_a, "ta")], [DataSource(file_b, "ta")]],
            column_space;
            start_date,
            compose_function = +,
        )

        # One source for every column
        shared = TimeVaryingInputs.TimeVaryingInput(
            DataSource(file_a, "ta"),
            center_space;
            start_date,
        )
        @test Array(shared.column_segment) == [1, 1, 1, 1]
        @test length(shared.offsets) == 2
        TimeVaryingInputs.evaluate!(dest, shared, node_date)
        arr = Array(Fields.field2array(dest))
        @test all(c -> arr[:, c] == regrid(z_a, ta_a)[:, 3], 1:4)

        make(srcs, space; kwargs...) = TimeVaryingInputs.TimeVaryingInput(
            srcs,
            space;
            start_date,
            kwargs...,
        )
        @test_throws "more than max_bytes" make(
            sources("ta"),
            center_space;
            max_bytes = 10,
        )
        @test_throws "but the space has no levels" make(
            [DataSource(file_a, "ta")],
            point_space,
        )
        static_path = write_column_file(
            joinpath(data_dir, "static.nc");
            z = z_a,
            dates = nothing,
            variables = ["ta" => z_a],
        )
        @test_throws "no time dimension" make(
            [DataSource(static_path, "ta")],
            column_space,
        )
        pressure_path = write_column_file(
            joinpath(data_dir, "pressure.nc");
            z = z_a,
            dates = dates_a,
            variables = ["ta" => ta_a],
            z_units = "hPa",
        )
        @test_throws "heights in metres" make(
            [DataSource(pressure_path, "ta")],
            column_space,
        )
        one_time_path = write_column_file(
            joinpath(data_dir, "one_time.nc");
            z = z_a,
            dates = dates_a[1:1],
            variables = ["ta" => ta_a[:, 1:1]],
        )
        @test_throws "at least two times" make(
            [DataSource(one_time_path, "ta")],
            column_space,
        )

        # Horizontal dimensions of length two
        grid_path = joinpath(data_dir, "grid.nc")
        NCDatasets.NCDataset(grid_path, "c") do nc
            NCDatasets.defDim(nc, "z", length(z_a))
            NCDatasets.defDim(nc, "time", length(dates_a))
            NCDatasets.defDim(nc, "x", 2)
            NCDatasets.defDim(nc, "y", 2)
            NCDatasets.defVar(nc, "z", z_a, ("z",))
            NCDatasets.defVar(nc, "time", dates_a, ("time",))
            NCDatasets.defVar(
                nc,
                "ta",
                repeat(ta_a, 1, 1, 2, 2),
                ("z", "time", "x", "y"),
            )
        end
        @test_throws "only time and the vertical coordinate" make(
            [DataSource(grid_path, "ta")],
            column_space,
        )

        # Missing values must be handled by preprocess_func
        gaps_path = joinpath(data_dir, "gaps.nc")
        NCDatasets.NCDataset(gaps_path, "c") do nc
            NCDatasets.defDim(nc, "z", length(z_a))
            NCDatasets.defDim(nc, "time", length(dates_a))
            NCDatasets.defVar(nc, "z", z_a, ("z",))
            NCDatasets.defVar(nc, "time", dates_a, ("time",))
            data = Array{Union{Missing, Float64}}(ta_a)
            data[2, 5] = missing
            NCDatasets.defVar(nc, "ta", data, ("z", "time"); fillvalue = -999.0)
        end
        @test_throws "Missing values" make(
            [DataSource(gaps_path, "ta")],
            column_space,
        )
        filled = make(
            [DataSource(gaps_path, "ta")],
            column_space;
            preprocess_func = x -> coalesce(x, 0.0),
        )
        TimeVaryingInputs.evaluate!(
            Fields.zeros(column_space),
            filled,
            node_date,
        )
    end
end

@testset "Equivalence with the 23D and 0D inputs" begin
    data_dir = mktempdir()
    start_date = DateTime(2010, 7, 1)
    z = collect(0.0:500.0:5000.0)
    dates = start_date .+ Hour.(0:23)
    ta = [280 + 0.01z * cos(t / 4) + sin(t / 3) for z in z, t in 0:23]
    ts = [290 + 5 * sin(t / 5) for t in 0:23]
    file = write_column_file(
        joinpath(data_dir, "site.nc");
        z,
        dates,
        variables = ["ta" => ta, "ts" => ts],
    )
    # Seconds from start_date of the nodes and of times between them
    node_seconds = 3600.0 .* (0:23)
    between_seconds = 3600.0 .* (0:22) .+ 1800.0
    to_date(t) = start_date + Millisecond(round(Int, 1000t))

    for FT in (Float32, Float64)
        (; center_space, level_space, column_space) =
            make_spaces(FT; nlevels = 10, z_max = FT(6000))
        close_enough(a, b) = isapprox(a, b; rtol = 10eps(FT))

        for method in (
            TimeVaryingInputs.LinearInterpolation(),
            TimeVaryingInputs.LinearInterpolation(
                TimeVaryingInputs.PeriodicCalendar(),
            ),
        )
            itp23 = TimeVaryingInputs.TimeVaryingInput(
                file,
                "ta",
                column_space;
                start_date,
                method,
                regridder_type = :InterpolationsRegridder,
                regridder_kwargs = (;
                    extrapolation_bc = (Interpolations.Flat(),)
                ),
            )
            ragged = TimeVaryingInputs.TimeVaryingInput(
                [DataSource(file, "ta")],
                column_space;
                start_date,
                method,
            )
            shared = TimeVaryingInputs.TimeVaryingInput(
                DataSource(file, "ta"),
                center_space;
                start_date,
                method,
            )
            dest23 = Fields.zeros(column_space)
            dest_ragged = Fields.zeros(column_space)
            dest_shared = Fields.zeros(center_space)
            periodic =
                TimeVaryingInputs.extrapolation_bc(method) isa
                TimeVaryingInputs.PeriodicCalendar
            seconds =
                periodic ?
                (
                    node_seconds...,
                    between_seconds...,
                    30 * 3600.0,
                    -5 * 3600.0,
                ) : (node_seconds..., between_seconds...)
            for t in seconds, time in (t, to_date(t))
                TimeVaryingInputs.evaluate!(dest23, itp23, time)
                TimeVaryingInputs.evaluate!(dest_ragged, ragged, time)
                TimeVaryingInputs.evaluate!(dest_shared, shared, time)
                expected = vec(Array(Fields.field2array(dest23)))
                @test close_enough(
                    vec(Array(Fields.field2array(dest_ragged))),
                    expected,
                )
                @test all(
                    col -> close_enough(col, expected),
                    eachcol(Array(Fields.field2array(dest_shared))),
                )
            end
        end

        # A surface series against the scalar and the multi-point 0D inputs,
        # the latter holding the same FT values
        surface = TimeVaryingInputs.TimeVaryingInput(
            DataSource(file, "ts"),
            level_space;
            start_date,
        )
        scalar = TimeVaryingInputs.TimeVaryingInput(node_seconds, ts)
        multipoint = TimeVaryingInputs.TimeVaryingInput(
            node_seconds,
            FT.(repeat(ts', 4, 1)),
            level_space,
        )
        dest_surface = Fields.zeros(level_space)
        dest_multipoint = Fields.zeros(level_space)
        expected = zeros(1)
        for t in (node_seconds..., between_seconds...)
            TimeVaryingInputs.evaluate!(dest_surface, surface, t)
            TimeVaryingInputs.evaluate!(dest_multipoint, multipoint, t)
            TimeVaryingInputs.evaluate!(expected, scalar, t)
            values = vec(Array(Fields.field2array(dest_surface)))
            @test all(v -> close_enough(v, expected[1]), values)
            @test values == vec(Array(Fields.field2array(dest_multipoint)))
        end
    end
end
