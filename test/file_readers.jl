using Artifacts
using Dates
using Test

import ClimaUtilities
import ClimaUtilities.FileReaders
using NCDatasets

@testset "DataSource" begin
    data_dir = mktempdir()
    zs = Float64[1, 2, 3]
    times = [DateTime(2000, 1, 1), DateTime(2000, 1, 2)]

    # Write a single column file. `times === nothing` makes a static file (no
    # time dimension); otherwise the file is time-varying with the given axis.
    function make_source_file(name, times)
        path = joinpath(data_dir, name)
        NCDataset(path, "c") do nc
            defDim(nc, "z", length(zs))
            defVar(nc, "z", zs, ("z",))
            if isnothing(times)
                defVar(nc, "myvar", zs, ("z",))
            else
                defDim(nc, "time", length(times))
                defVar(nc, "time", times, ("time",))
                var = defVar(nc, "myvar", Float64, ("z", "time"))
                for t in eachindex(times)
                    var[:, t] = zs .* t
                end
            end
        end
        return path
    end

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
    @test src.dataset_kwargs == ()

    # `time_transform` is applied elementwise to the dates
    src = FileReaders.DataSource(
        tv_path,
        "myvar";
        time_transform = d -> d + Day(1),
    )
    @test src.available_dates == times .+ Day(1)

    # Multiple files joined along the time dimension
    split_paths = map(eachindex(times)) do t
        make_source_file("ds_split_t$t.nc", [times[t]])
    end
    src = FileReaders.DataSource(split_paths, "myvar")
    @test src.available_dates == times
    @test src.time_index == 2
    @test src.dataset_kwargs == (:aggdim => "time", :deferopen => false)

    # Coordinates must be consistent across files
    mismatch_path = joinpath(data_dir, "ds_split_zmismatch.nc")
    NCDataset(mismatch_path, "c") do nc
        defDim(nc, "z", length(zs))
        defVar(nc, "z", zs .+ 0.5, ("z",))
        defDim(nc, "time", 1)
        defVar(nc, "time", [times[2]], ("time",))
        var = defVar(nc, "myvar", Float64, ("z", "time"))
        var[:, 1] = zs
    end
    @test_throws contains("does not match") FileReaders.DataSource(
        [first(split_paths), mismatch_path],
        "myvar",
    )

    # File with date dimension
    # Some datasets store their time axis as a "date" dimension holding integer
    # yyyymmdd values instead of a CF "time" dimension
    data_dir = mktempdir()
    dates_int = [20000101, 20000102]
    dates = [DateTime(2000, 1, 1), DateTime(2000, 1, 2)]
    path = joinpath(data_dir, "ds_yyyymmdd.nc")
    NCDataset(path, "c") do nc
        defDim(nc, "date", length(dates_int))
        defVar(nc, "date", dates_int, ("date",))
        var = defVar(nc, "myvar", Float64, ("date",))
        for t in eachindex(dates_int)
            var[t] = t
        end
    end

    src = FileReaders.DataSource(path, "myvar")
    @test src.available_dates == dates
    @test src.time_index == 1
    @test isempty(src.dataset_kwargs)

    # Error handling
    @test_throws contains("must contain at least one path") FileReaders.DataSource(
        String[],
        "myvar",
    )
    @test_throws contains("is not available") FileReaders.DataSource(
        static_path,
        "nope",
    )
    unsorted_path = make_source_file("ds_unsorted.nc", reverse(times))
    @test_throws contains("Dates are not sorted") FileReaders.DataSource(
        unsorted_path,
        "myvar",
    )
    duplicate_path = make_source_file("ds_duplicate.nc", [times[1], times[1]])
    @test_throws contains("Dates are not unique") FileReaders.DataSource(
        duplicate_path,
        "myvar",
    )
end

@testset "DataSource coordinate names" begin
    data_dir = mktempdir()
    zs = Float64[1, 2, 3]

    # Write a single static column file whose coordinate variables use the
    # given names.
    function make_coord_file(name, lon_name, lat_name, z_name)
        path = joinpath(data_dir, name)
        NCDataset(path, "c") do nc
            defDim(nc, z_name, length(zs))
            defVar(nc, lon_name, 10.0, ())
            defVar(nc, lat_name, 20.0, ())
            defVar(nc, z_name, zs, (z_name,))
            defVar(nc, "myvar", zs, (z_name,))
        end
        return path
    end

    # Coordinate names should match case-insensitively
    detected_path =
        make_coord_file("cn_detected.nc", "Longitude", "lat", "level")
    src = FileReaders.DataSource(detected_path, "myvar")
    @test src.coord_names == (; lon = "Longitude", lat = "lat", z = "level")

    # Explicit names are validated against the file and stored as given
    custom_path = make_coord_file("cn_custom.nc", "x_lon", "y_lat", "zed")
    src = FileReaders.DataSource(
        custom_path,
        "myvar";
        coord_names = (; lon = "x_lon", lat = "y_lat", z = "zed"),
    )
    @test src.coord_names == (; lon = "x_lon", lat = "y_lat", z = "zed")

    # Detection omits the coordinate types it cannot identify
    src = FileReaders.DataSource(custom_path, "myvar")
    @test src.coord_names == (;)

    # Two candidates for the same type of coordinate
    ambiguous_path = joinpath(data_dir, "cn_ambiguous.nc")
    NCDataset(ambiguous_path, "c") do nc
        defDim(nc, "z", length(zs))
        defVar(nc, "lon", 10.0, ())
        defVar(nc, "longitude", 10.0, ())
        defVar(nc, "latitude", 20.0, ())
        defVar(nc, "z", zs, ("z",))
        defVar(nc, "myvar", zs, ("z",))
    end
    @test_throws contains("multiple lon variables") FileReaders.DataSource(
        ambiguous_path,
        "myvar",
    )

    # Error handling for explicit names
    @test_throws contains("is not available") FileReaders.DataSource(
        custom_path,
        "myvar";
        coord_names = (; lon = "nope", lat = "y_lat"),
    )
    @test_throws contains("Unrecognized coordinate types") FileReaders.DataSource(
        custom_path,
        "myvar";
        coord_names = (; long = "x_lon", lat = "y_lat"),
    )
    @test_throws contains("must be a NamedTuple") FileReaders.DataSource(
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

        # Check double close is an no-op
        close(reader1)

        file_paths = reader2.file_paths
        close(reader2)
        @test !haskey(open_ncfiles, file_paths)

        # Check again that double close is an no-op
        close(reader2)
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
