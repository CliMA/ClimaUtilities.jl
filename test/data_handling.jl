using Dates
using Artifacts
using Test

import ClimaUtilities
import ClimaUtilities.DataHandling

import ClimaCore
import ClimaComms
import Interpolations
import ClimaCoreTempestRemap
using NCDatasets

const context = ClimaComms.context()

@testset "DataHandler, static" begin
    PATH = joinpath(
        artifact"era5_static_example",
        "era5_t2m_sp_u10n_20210101_static.nc",
    )
    varname = "sp"
    for regridder_type in (:InterpolationsRegridder, :TempestRegridder)
        for FT in (Float32, Float64)
            radius = FT(6731e3)
            helem = 40
            Nq = 4

            horzdomain = ClimaCore.Domains.SphereDomain(radius)
            horzmesh =
                ClimaCore.Meshes.EquiangularCubedSphere(horzdomain, helem)
            horztopology = ClimaCore.Topologies.Topology2D(context, horzmesh)
            quad = ClimaCore.Spaces.Quadratures.GLL{Nq}()
            target_space =
                ClimaCore.Spaces.SpectralElementSpace2D(horztopology, quad)

            data_handler = DataHandling.DataHandler(
                PATH,
                varname,
                target_space;
                regridder_type,
            )

            @test DataHandling.available_dates(data_handler) == DateTime[]

            field = DataHandling.regridded_snapshot(data_handler)
            # Most basic testing, to get a sense that we are doing things right
            @test field isa ClimaCore.Fields.Field
            @test axes(field) == target_space
            @test eltype(field) == FT
            @test minimum(field) >=
                  minimum(data_handler.file_reader.dataset[varname][:, :])
            @test maximum(field) <=
                  maximum(data_handler.file_reader.dataset[varname][:, :])

            close(data_handler)
        end
    end
end

@testset "DataHandler, TempestRegridder, time data" begin
    PATH = joinpath(artifact"era5_example", "era5_t2m_sp_u10n_20210101.nc")
    varname = "sp"
    for regridder_type in (:InterpolationsRegridder, :TempestRegridder)
        for FT in (Float32, Float64)
            radius = FT(6731e3)
            helem = 40
            Nq = 4

            horzdomain = ClimaCore.Domains.SphereDomain(radius)
            horzmesh =
                ClimaCore.Meshes.EquiangularCubedSphere(horzdomain, helem)
            horztopology = ClimaCore.Topologies.Topology2D(context, horzmesh)
            quad = ClimaCore.Spaces.Quadratures.GLL{Nq}()
            target_space =
                ClimaCore.Spaces.SpectralElementSpace2D(horztopology, quad)

            data_handler = DataHandling.DataHandler(
                PATH,
                varname,
                target_space,
                reference_date = Dates.DateTime(2000, 1, 1),
                t_start = 0.0;
                regridder_type,
            )

            @test DataHandling.available_dates(data_handler) ==
                  data_handler.file_reader.available_dates
            @test data_handler.reference_date .+
                  Second.(DataHandling.available_times(data_handler)) ==
                  DataHandling.available_dates(data_handler)

            available_times = DataHandling.available_times(data_handler)
            available_dates = DataHandling.available_dates(data_handler)

            # Previous time with time
            @test DataHandling.previous_time(
                data_handler,
                available_times[10] + 1,
            ) == available_times[10]
            @test DataHandling.previous_time(
                data_handler,
                available_times[1] + 1,
            ) == available_times[1]
            # Previous time with date
            @test DataHandling.previous_time(
                data_handler,
                available_dates[10] + Second(1),
            ) == available_times[10]
            @test DataHandling.previous_time(
                data_handler,
                available_dates[10],
            ) == available_times[10]

            # On node
            @test DataHandling.previous_time(
                data_handler,
                available_times[10],
            ) == available_times[10]
            @test DataHandling.previous_time(
                data_handler,
                available_times[1],
            ) == available_times[1]
            @test DataHandling.previous_time(
                data_handler,
                available_dates[10],
            ) == available_times[10]

            # Next time with time
            @test DataHandling.next_time(
                data_handler,
                available_times[10] + 1,
            ) == available_times[11]
            @test DataHandling.next_time(
                data_handler,
                available_times[1] + 1,
            ) == available_times[2]
            # Next time with date
            @test DataHandling.next_time(
                data_handler,
                available_dates[10] + Second(1),
            ) == available_times[11]

            # On node
            @test DataHandling.next_time(data_handler, available_times[10]) ==
                  available_times[11]
            @test DataHandling.next_time(data_handler, available_dates[10]) ==
                  available_times[11]

            # Asking for a regridded_snapshot without specifying the time
            @test_throws ErrorException DataHandling.regridded_snapshot(
                data_handler,
            )

            # Asking for a regridded_snapshot with time that does not exist
            @test_throws ErrorException DataHandling.regridded_snapshot(
                data_handler,
                -1234.0,
            )

            field = DataHandling.regridded_snapshot(
                data_handler,
                available_times[10],
            )

            # Most basic testing, to get a sense that we are doing things right
            @test field isa ClimaCore.Fields.Field
            @test axes(field) == target_space
            @test eltype(field) == FT
            @test minimum(field) >=
                  minimum(data_handler.file_reader.dataset[varname][:, :, 10])
            @test maximum(field) <=
                  maximum(data_handler.file_reader.dataset[varname][:, :, 10])

            close(data_handler)
        end
    end
end
