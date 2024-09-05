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

@testset "InterpolatingTimeVaryingInput23D" begin
    PATH = joinpath(artifact"era5_example", "era5_t2m_sp_u10n_20210101.nc")
    regridder_types = (:InterpolationsRegridder, :TempestRegridder)

    # Tempestremap is single threaded and CPU only
    if context isa ClimaComms.MPICommsContext ||
       ClimaComms.device() isa ClimaComms.CUDADevice ||
       Sys.iswindows()
        regridder_types = (:InterpolationsRegridder,)
    end
    for FT in (Float32, Float64)
        for regridder_type in regridder_types
            if regridder_type == :TempestRegridder
                target_spaces = (make_spherical_space(FT; context).horizontal,)
            else
                target_spaces = (
                    make_spherical_space(FT; context).horizontal,
                    make_regional_space(FT; context).horizontal,
                )
            end
            for target_space in target_spaces
                data_handler = DataHandling.DataHandler(
                    PATH,
                    "u10n",
                    target_space;
                    reference_date = Dates.DateTime(2021, 1, 1, 1),
                    t_start = 0.0,
                    regridder_type,
                )

                # Test constructor with multiple variables
                regridder_type_interp = :InterpolationsRegridder
                compose_function = (x, y) -> x + y
                input_multiple_vars = TimeVaryingInputs.TimeVaryingInput(
                    PATH,
                    ["u10n", "t2m"],
                    target_space;
                    reference_date = Dates.DateTime(2021, 1, 1, 1),
                    t_start = 0.0,
                    regridder_type = regridder_type_interp,
                    compose_function,
                )

                input_nearest = TimeVaryingInputs.TimeVaryingInput(
                    PATH,
                    "u10n",
                    target_space;
                    reference_date = Dates.DateTime(2021, 1, 1, 1),
                    t_start = 0.0,
                    regridder_type,
                    method = TimeVaryingInputs.NearestNeighbor(),
                )

                input_nearest_flat = TimeVaryingInputs.TimeVaryingInput(
                    PATH,
                    "u10n",
                    target_space;
                    reference_date = Dates.DateTime(2021, 1, 1, 1),
                    t_start = 0.0,
                    regridder_type,
                    method = TimeVaryingInputs.NearestNeighbor(
                        TimeVaryingInputs.Flat(),
                    ),
                )

                input_nearest_periodic_calendar =
                    TimeVaryingInputs.TimeVaryingInput(
                        PATH,
                        "u10n",
                        target_space;
                        reference_date = Dates.DateTime(2021, 1, 1, 1),
                        t_start = 0.0,
                        regridder_type,
                        method = TimeVaryingInputs.NearestNeighbor(
                            TimeVaryingInputs.PeriodicCalendar(),
                        ),
                    )

                input_linear_periodic_calendar =
                    TimeVaryingInputs.TimeVaryingInput(
                        PATH,
                        "u10n",
                        target_space;
                        reference_date = Dates.DateTime(2021, 1, 1, 1),
                        t_start = 0.0,
                        regridder_type,
                        method = TimeVaryingInputs.LinearInterpolation(
                            TimeVaryingInputs.PeriodicCalendar(),
                        ),
                    )

                # Repeat one day over and over
                period = Dates.Day(1)
                repeat_date = Dates.DateTime(2021, 1, 1, 1)

                # Note, the data is define on the day of 2021/1/1, so Dates.DateTime(2021, 1, 1,
                # 1) is one hour in. This allows us to test misaligned periods
                input_nearest_periodic_calendar_date =
                    TimeVaryingInputs.TimeVaryingInput(
                        PATH,
                        "u10n",
                        target_space;
                        reference_date = Dates.DateTime(2021, 1, 1, 1),
                        t_start = 0.0,
                        regridder_type,
                        method = TimeVaryingInputs.NearestNeighbor(
                            TimeVaryingInputs.PeriodicCalendar(
                                period,
                                repeat_date,
                            ),
                        ),
                    )

                input_linear_periodic_calendar_date =
                    TimeVaryingInputs.TimeVaryingInput(
                        PATH,
                        "u10n",
                        target_space;
                        reference_date = Dates.DateTime(2021, 1, 1, 1),
                        t_start = 0.0,
                        regridder_type,
                        method = TimeVaryingInputs.LinearInterpolation(
                            TimeVaryingInputs.PeriodicCalendar(
                                period,
                                repeat_date,
                            ),
                        ),
                    )

                @test 0.0 in input_nearest
                @test !(1e23 in input_nearest)

                available_times = DataHandling.available_times(data_handler)
                dest = Fields.zeros(target_space)

                # Time outside of range
                @test_throws ErrorException TimeVaryingInputs.evaluate!(
                    dest,
                    input_nearest,
                    FT(-40000),
                )

                # We are testing NearestNeighbor, so we can just have to check if the fields agree

                # Left nearest point
                target_time = available_times[10] + 1
                TimeVaryingInputs.evaluate!(dest, input_nearest, target_time)

                # We use isequal to handle NaNs
                @test isequal(
                    Array(parent(dest)),
                    Array(
                        parent(
                            DataHandling.regridded_snapshot(
                                data_handler,
                                available_times[10],
                            ),
                        ),
                    ),
                )

                # Right nearest point
                target_time = available_times[9] - 1
                TimeVaryingInputs.evaluate!(dest, input_nearest, target_time)

                @test isequal(
                    Array(parent(dest)),
                    Array(
                        parent(
                            DataHandling.regridded_snapshot(
                                data_handler,
                                available_times[9],
                            ),
                        ),
                    ),
                )

                # On node
                target_time = available_times[11]
                TimeVaryingInputs.evaluate!(dest, input_nearest, target_time)

                @test isequal(
                    Array(parent(dest)),
                    Array(
                        parent(
                            DataHandling.regridded_snapshot(
                                data_handler,
                                available_times[11],
                            ),
                        ),
                    ),
                )

                # Flat left
                target_time = available_times[begin] - 1
                TimeVaryingInputs.evaluate!(
                    dest,
                    input_nearest_flat,
                    target_time,
                )

                @test isequal(
                    Array(parent(dest)),
                    Array(
                        parent(
                            DataHandling.regridded_snapshot(
                                data_handler,
                                available_times[begin],
                            ),
                        ),
                    ),
                )

                # Flat right
                target_time = available_times[end] + 1
                TimeVaryingInputs.evaluate!(
                    dest,
                    input_nearest_flat,
                    target_time,
                )

                @test isequal(
                    Array(parent(dest)),
                    Array(
                        parent(
                            DataHandling.regridded_snapshot(
                                data_handler,
                                available_times[end],
                            ),
                        ),
                    ),
                )

                # Nearest periodic calendar
                dt = available_times[2] - available_times[1]
                target_time = available_times[end] + 0.1dt
                TimeVaryingInputs.evaluate!(
                    dest,
                    input_nearest_periodic_calendar,
                    target_time,
                )

                @test isequal(
                    Array(parent(dest)),
                    Array(
                        parent(
                            DataHandling.regridded_snapshot(
                                data_handler,
                                available_times[end],
                            ),
                        ),
                    ),
                )

                # With date
                TimeVaryingInputs.evaluate!(
                    dest,
                    input_nearest_periodic_calendar_date,
                    target_time,
                )

                @test isequal(
                    Array(parent(dest)),
                    Array(
                        parent(
                            DataHandling.regridded_snapshot(
                                data_handler,
                                available_times[end],
                            ),
                        ),
                    ),
                )

                dt = available_times[2] - available_times[1]
                target_time = available_times[end] + 0.6dt
                TimeVaryingInputs.evaluate!(
                    dest,
                    input_nearest_periodic_calendar,
                    target_time,
                )

                @test isequal(
                    Array(parent(dest)),
                    Array(
                        parent(
                            DataHandling.regridded_snapshot(
                                data_handler,
                                available_times[begin],
                            ),
                        ),
                    ),
                )

                # Now testing LinearInterpolation
                input_linear = TimeVaryingInputs.TimeVaryingInput(data_handler)

                # Time outside of range
                @test_throws ErrorException TimeVaryingInputs.evaluate!(
                    dest,
                    input_linear,
                    FT(-40000),
                )

                left_value = DataHandling.regridded_snapshot(
                    data_handler,
                    available_times[10],
                )
                right_value = DataHandling.regridded_snapshot(
                    data_handler,
                    available_times[11],
                )

                target_time = available_times[10] + 30
                left_time = available_times[10]
                right_time = available_times[11]

                TimeVaryingInputs.evaluate!(dest, input_linear, target_time)

                expected = Fields.zeros(target_space)
                expected .=
                    left_value .+
                    (target_time - left_time) / (right_time - left_time) .*
                    (right_value .- left_value)

                @test parent(dest) ≈ parent(expected)

                # LinearInterpolation with PeriodicCalendar
                time_delta = 0.1dt
                target_time = available_times[end] + time_delta

                left_value = DataHandling.regridded_snapshot(
                    data_handler,
                    available_times[end],
                )
                right_value = DataHandling.regridded_snapshot(
                    data_handler,
                    available_times[begin],
                )

                time_delta = 0.1dt
                target_time = available_times[end] + time_delta
                left_time = available_times[10]
                right_time = available_times[11]

                TimeVaryingInputs.evaluate!(
                    dest,
                    input_linear_periodic_calendar,
                    target_time,
                )

                expected = Fields.zeros(target_space)
                expected .=
                    left_value .+ time_delta / dt .* (right_value .- left_value)

                @test parent(dest) ≈ parent(expected)

                # With offset of one period
                TimeVaryingInputs.evaluate!(
                    dest,
                    input_linear_periodic_calendar_date,
                    target_time + 86400,
                )

                @test parent(dest) ≈ parent(expected)

                close(input_multiple_vars)
                close(input_nearest)
                close(input_linear)
                close(input_nearest_flat)
                close(input_nearest_periodic_calendar)
                close(input_linear_periodic_calendar)
            end
        end
    end
end
