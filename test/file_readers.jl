using Artifacts
using Dates
using Test

import ClimaUtilities
import ClimaUtilities.FileReaders
using NCDatasets

include("TestTools.jl")

@testset "DataSource" begin
    data_dir = mktempdir()
    zs = Float64[1, 2, 3]
    times = [DateTime(2000, 1, 1), DateTime(2000, 1, 2)]
    # myvar holds zs .* t at the t-th time, or zs without times
    make_source_file(name, times) = write_column_file(
        joinpath(data_dir, name);
        z = zs,
        dates = times,
        variables = [
            "myvar" => isnothing(times) ? zs : zs .* (1:length(times))',
        ],
    )

    # Static single file: no time dimension
    static_path = make_source_file("ds_static.nc", nothing)
    src = FileReaders.DataSource(static_path, "myvar")
    @test src.file_paths == [static_path]
    @test src.varname == "myvar"
    @test isempty(src.available_dates)
    @test src.time_index == -1
    @test src.coord_names == (; z = "z")
    @test src.dataset_kwargs == ()

    # Time-varying single file
    tv_path = make_source_file("ds_tv.nc", times)
    src = FileReaders.DataSource(tv_path, "myvar")
    @test src.available_dates == times
    @test src.time_index == 2

    # Sources built independently compare equal; time_transform changes the
    # dates
    @test src == FileReaders.DataSource(tv_path, "myvar")
    @test hash(src) == hash(FileReaders.DataSource(tv_path, "myvar"))
    shifted = FileReaders.DataSource(
        tv_path,
        "myvar";
        time_transform = d -> d + Day(1),
    )
    @test shifted.available_dates == times .+ Day(1)
    @test shifted != src

    # Multiple files joined along the time dimension
    split_paths = [
        make_source_file("ds_split_t$t.nc", [times[t]]) for
        t in eachindex(times)
    ]
    src = FileReaders.DataSource(split_paths, "myvar")
    @test src.available_dates == times
    @test src.time_index == 2
    @test src.dataset_kwargs == (:aggdim => "time", :deferopen => false)

    # Coordinates must be consistent across files
    mismatch_path = write_column_file(
        joinpath(data_dir, "ds_mismatch.nc");
        z = zs .+ 0.5,
        dates = [times[2]],
        variables = ["myvar" => reshape(zs, :, 1)],
    )
    @test_throws "does not match" FileReaders.DataSource(
        [first(split_paths), mismatch_path],
        "myvar",
    )

    # A "date" dimension holding yyyymmdd integers
    date_path = joinpath(data_dir, "ds_yyyymmdd.nc")
    NCDataset(date_path, "c") do nc
        defDim(nc, "date", 2)
        defVar(nc, "date", [20000101, 20000102], ("date",))
        defVar(nc, "myvar", [1.0, 2.0], ("date",))
    end
    src = FileReaders.DataSource(date_path, "myvar")
    @test src.available_dates == times
    @test src.time_index == 1

    @test_throws "at least one path" FileReaders.DataSource(String[], "myvar")
    @test_throws "is not available" FileReaders.DataSource(static_path, "nope")
    @test_throws "not sorted" FileReaders.DataSource(
        make_source_file("ds_unsorted.nc", reverse(times)),
        "myvar",
    )
    @test_throws "not unique" FileReaders.DataSource(
        make_source_file("ds_duplicate.nc", [times[1], times[1]]),
        "myvar",
    )
    @test_throws "no temporal dimension" FileReaders.DataSource(
        [static_path, static_path],
        "myvar",
    )
end

@testset "DataSource coordinate names" begin
    data_dir = mktempdir()
    zs = Float64[1, 2, 3]
    make_coord_file(name, lon, lat, z_name) = write_column_file(
        joinpath(data_dir, name);
        z = zs,
        dates = nothing,
        variables = ["myvar" => zs],
        z_name,
        scalars = [lon => 10.0, lat => 20.0],
    )

    # Coordinate names are detected case-insensitively
    detected_path =
        make_coord_file("cn_detected.nc", "Longitude", "lat", "level")
    src = FileReaders.DataSource(detected_path, "myvar")
    @test src.coord_names == (; lon = "Longitude", lat = "lat", z = "level")

    # Explicit names are checked against the file and stored as given
    custom_path = make_coord_file("cn_custom.nc", "x_lon", "y_lat", "zed")
    names = (; lon = "x_lon", lat = "y_lat", z = "zed")
    src = FileReaders.DataSource(custom_path, "myvar"; coord_names = names)
    @test src.coord_names == names
    @test FileReaders.DataSource(custom_path, "myvar").coord_names == (;)

    @test_throws "is not available" FileReaders.DataSource(
        custom_path,
        "myvar";
        coord_names = (; lon = "nope"),
    )
    @test_throws "Unrecognized coordinate types" FileReaders.DataSource(
        custom_path,
        "myvar";
        coord_names = (; long = "x_lon"),
    )
    @test_throws "must be a NamedTuple" FileReaders.DataSource(
        custom_path,
        "myvar";
        coord_names = ("x_lon", "y_lat"),
    )
end

@testset "NCFileReader with time" begin
    # Start from a clean OPEN_NCFILES state
    FileReaders.close_all_ncfiles()
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

        # Mutating a read should not corrupt the cache
        first_read = FileReaders.read(ncreader_u, DateTime(2021, 01, 01, 02))
        fill!(first_read, NaN)
        @test FileReaders.read(ncreader_u, DateTime(2021, 01, 01, 02)) ==
              nc["u10n"][:, :, 3]

        # Test read!
        dest = copy(nc["u10n"][:, :, 2])
        fill!(dest, 0)
        FileReaders.read!(dest, ncreader_u, DateTime(2021, 01, 01, 01))
        @test dest == nc["u10n"][:, :, 2]

        # Test that we need to close all the variables to close the file
        open_ncfiles =
            Base.get_extension(ClimaUtilities, :ClimaUtilitiesNCDatasetsExt).NCFileReaderExt.OPEN_NCFILES

        close(ncreader_sp)
        @test !isempty(open_ncfiles)
        close(ncreader_u)
        @test isempty(open_ncfiles)
    end

    # Test times split across multiple files
    PATHS = [
        joinpath(@__DIR__, "test_data", "era5_1979_1.0x1.0_lai.nc"),
        joinpath(@__DIR__, "test_data", "era5_1980_1.0x1.0_lai.nc"),
    ]
    NCDataset(PATHS, aggdim = "time") do nc
        ncreader_agg = FileReaders.NCFileReader(PATHS, "lai_lv")
        @test FileReaders.available_dates(ncreader_agg) == nc["time"][:]
        @test length(FileReaders.available_dates(ncreader_agg)) == 104
        close(ncreader_agg)
    end
end

@testset "Shared readers of the same variable" begin
    FileReaders.close_all_ncfiles()
    PATH = joinpath(artifact"era5_example", "era5_t2m_sp_u10n_20210101.nc")
    open_ncfiles =
        Base.get_extension(ClimaUtilities, :ClimaUtilitiesNCDatasetsExt).NCFileReaderExt.OPEN_NCFILES
    NCDataset(PATH) do nc
        reader1 = FileReaders.NCFileReader(PATH, "sp")
        reader2 = FileReaders.NCFileReader(PATH, "sp")

        # The two readers share the same underlying dataset
        @test reader1.dataset === reader2.dataset

        # Closing the first reader must not close the file out from under the
        # second reader
        close(reader1)
        @test haskey(open_ncfiles, reader2.file_paths)
        @test FileReaders.read(reader2, DateTime(2021, 01, 01, 01)) ==
              nc["sp"][:, :, 2]

        # Check double close is a no-op
        close(reader1)
        @test haskey(open_ncfiles, reader2.file_paths)
        @test FileReaders.read(reader2, DateTime(2021, 01, 01, 01)) ==
              nc["sp"][:, :, 2]
        file_paths = reader2.file_paths
        close(reader2)
        @test !haskey(open_ncfiles, file_paths)

        # Check again that double close is an no-op
        close(reader2)
        @test !haskey(open_ncfiles, file_paths)

        # Check read from reader3 works after closing reader1 again
        reader3 = FileReaders.NCFileReader(PATH, "sp")
        close(reader1)
        @test haskey(open_ncfiles, file_paths)
        @test FileReaders.read(reader3, DateTime(2021, 01, 01, 01)) ==
              nc["sp"][:, :, 2]

        # Check same behavior if we close all NetCDF files instead of a specific
        # reader
        FileReaders.close_all_ncfiles()
        reader4 = FileReaders.NCFileReader(PATH, "sp")
        close(reader3)
        @test haskey(open_ncfiles, file_paths)
        close(reader4)
        @test !haskey(open_ncfiles, file_paths)
    end
end

@testset "NCFileReader without time" begin
    FileReaders.close_all_ncfiles()
    PATH = joinpath(
        artifact"era5_static_example",
        "era5_t2m_sp_u10n_20210101_static.nc",
    )
    NCDataset(PATH) do nc
        read_dates_func =
            Base.get_extension(ClimaUtilities, :ClimaUtilitiesNCDatasetsExt).NCFileReaderExt.read_available_dates

        available_dates = read_dates_func(nc)
        @test isempty(available_dates)

        ncreader = FileReaders.NCFileReader(PATH, "u10n")

        @test ncreader.dimensions[1] == nc["lon"][:]
        @test ncreader.dimensions[2] == nc["lat"][:]

        # This first read is a cache miss (using the DateTime(0) sentinel)
        first_read = FileReaders.read(ncreader)
        @test first_read == nc["u10n"][:, :]

        # Mutating a read should not corrupt the cache
        fill!(first_read, NaN)
        @test FileReaders.read(ncreader) == nc["u10n"][:, :]

        # Test read!
        dest = copy(nc["u10n"][:, :])
        fill!(dest, 0)
        FileReaders.read!(dest, ncreader)
        @test dest == nc["u10n"][:, :]

        @test isempty(FileReaders.available_dates(ncreader))

        FileReaders.close_all_ncfiles()
        open_ncfiles =
            Base.get_extension(ClimaUtilities, :ClimaUtilitiesNCDatasetsExt).NCFileReaderExt.OPEN_NCFILES
        @test isempty(open_ncfiles)
    end
end

@testset "read_available_dates" begin
    read_dates_func =
        Base.get_extension(ClimaUtilities, :ClimaUtilitiesNCDatasetsExt).NCFileReaderExt.read_available_dates

    data_dir = mktempdir()
    NCDataset(joinpath(data_dir, "test_time_1.nc"), "c") do nc
        defDim(nc, "time", 2)
        times = [DateTime(2022), DateTime(2023)]
        defVar(nc, "time", times, ("time",))
        @test read_dates_func(nc) == times
    end
    NCDataset(joinpath(data_dir, "test_date_1.nc"), "c") do nc
        defDim(nc, "date", 2)
        times = [20220101, 20230101]
        defVar(nc, "date", times, ("date",))
        @test read_dates_func(nc) == DateTime.(string.(times), "yyyymmdd")
    end

    NCDataset(joinpath(@__DIR__, "test_data", "reinterpret_time_dim.nc")) do nc
        @test read_dates_func(nc) == Dates.DateTime.(
            [
                "1850-01-15T12:00:00"
                "1850-02-14T00:00:00"
                "1850-03-15T12:00:00"
                "1850-04-15T00:00:00"
            ],
        )
    end
end

@testset "detect_coord_names" begin
    nc_ext =
        Base.get_extension(ClimaUtilities, :ClimaUtilitiesNCDatasetsExt).NCFileReaderExt
    data_dir = mktempdir()

    # Coordinate variables are matched case-insensitively, by type
    path = joinpath(data_dir, "coords.nc")
    NCDataset(path, "c") do nc
        defDim(nc, "height", 2)
        defDim(nc, "valid_time", 2)
        defVar(nc, "Longitude", 10.0, ())
        defVar(nc, "lat", 20.0, ())
        defVar(nc, "height", [1.0, 2.0], ("height",))
        dates = [DateTime(2000), DateTime(2001)]
        defVar(nc, "valid_time", dates, ("valid_time",))
        @test nc_ext.detect_coord_names(nc, path) ==
              (; lon = "Longitude", lat = "lat", z = "height")
        @test nc_ext.read_available_dates(nc) == dates
    end

    # Types without a match are omitted
    NCDataset(joinpath(data_dir, "no_coords.nc"), "c") do nc
        defDim(nc, "x", 2)
        defVar(nc, "myvar", [1.0, 2.0], ("x",))
        @test nc_ext.detect_coord_names(nc, "no_coords.nc") == (;)
    end

    # Two candidates for one type of coordinate
    NCDataset(joinpath(data_dir, "ambiguous.nc"), "c") do nc
        defVar(nc, "lon", 10.0, ())
        defVar(nc, "longitude", 10.0, ())
        @test_throws "multiple lon variables" nc_ext.detect_coord_names(
            nc,
            "ambiguous.nc",
        )
    end
end

@testset "read_missing_dims" begin
    FileReaders.close_all_ncfiles()
    PATH = joinpath(@__DIR__, "test_data", "missing_dim.nc")
    @test_throws contains(
        "missing_dim.nc\"] does not contain information about dimensions (\"missing_dim\",)",
    ) FileReaders.NCFileReader(PATH, "test_var")

    # A failed construction must not leak the open file in OPEN_NCFILES
    open_ncfiles =
        Base.get_extension(ClimaUtilities, :ClimaUtilitiesNCDatasetsExt).NCFileReaderExt.OPEN_NCFILES
    @test isempty(open_ncfiles)
end
