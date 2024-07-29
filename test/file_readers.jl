using Artifacts
using Dates
using Test

import ClimaUtilities
import ClimaUtilities.FileReaders
using NCDatasets

@testset "NCFileReader with time" begin
    PATH = joinpath(artifact"era5_example", "era5_t2m_sp_u10n_20210101.nc")
    NCDataset(PATH) do nc
        ncreader_sp = FileReaders.NCFileReader(PATH, "sp")
        ncreader_u = FileReaders.NCFileReader(PATH, "u10n")

        # Test that the underlying dataset is the same
        @test ncreader_u.dataset === ncreader_sp.dataset

        @test length(ncreader_u.available_dates) == 24
        @test length(ncreader_sp.available_dates) == 24

        @test FileReaders.available_dates(ncreader_u) ==
              ncreader_u.available_dates

        available_dates = ncreader_sp.available_dates
        @test available_dates[2] == DateTime(2021, 01, 01, 01)

        @test ncreader_sp.dimensions[1] == nc["lon"][:]
        @test ncreader_sp.dimensions[2] == nc["lat"][:]

        @test FileReaders.read(ncreader_u, DateTime(2021, 01, 01, 01)) ==
              nc["u10n"][:, :, 2]

        @test FileReaders.read(ncreader_sp, DateTime(2021, 01, 01, 01)) ==
              nc["sp"][:, :, 2]

        # Read it a second time to check that the cache works
        @test FileReaders.read(ncreader_u, DateTime(2021, 01, 01, 01)) ==
              nc["u10n"][:, :, 2]

        # Test read!
        dest = copy(nc["u10n"][:, :, 2])
        fill!(dest, 0)
        FileReaders.read!(dest, ncreader_u, DateTime(2021, 01, 01, 01))
        @test dest == nc["u10n"][:, :, 2]

        # Test that we need to close all the variables to close the file
        open_ncfiles =
            Base.get_extension(
                ClimaUtilities,
                :ClimaUtilitiesNCDatasetsExt,
            ).NCFileReaderExt.OPEN_NCFILES

        close(ncreader_sp)
        @test !isempty(open_ncfiles)
        close(ncreader_u)
        @test isempty(open_ncfiles)
    end
end

@testset "NCFileReader without time" begin
    PATH = joinpath(
        artifact"era5_static_example",
        "era5_t2m_sp_u10n_20210101_static.nc",
    )
    NCDataset(PATH) do nc
        read_dates_func =
            Base.get_extension(
                ClimaUtilities,
                :ClimaUtilitiesNCDatasetsExt,
            ).NCFileReaderExt.read_available_dates

        available_dates = read_dates_func(nc)
        @test isempty(available_dates)

        ncreader = FileReaders.NCFileReader(PATH, "u10n")

        @test ncreader.dimensions[1] == nc["lon"][:]
        @test ncreader.dimensions[2] == nc["lat"][:]

        @test FileReaders.read(ncreader) == nc["u10n"][:, :]

        @test isempty(FileReaders.available_dates(ncreader))

        FileReaders.close_all_ncfiles()
        open_ncfiles =
            Base.get_extension(
                ClimaUtilities,
                :ClimaUtilitiesNCDatasetsExt,
            ).NCFileReaderExt.OPEN_NCFILES
        @test isempty(open_ncfiles)
    end
end
