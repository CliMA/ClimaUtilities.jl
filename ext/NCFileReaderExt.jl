module NCFileReaderExt

import ClimaUtilities.DataStructures
import ClimaUtilities.FileReaders

import Dates
import NCDatasets

include("nc_common.jl")

# We allow multiple NCFileReader to share the same underlying NCDataset. For this, we put
# all the NCDataset into a dictionary where we keep track of them. OPEN_NCFILES is a
# dictionary that maps Vector of file paths (or a single string) to a Tuple with the first
# element being the NCDataset and the second element being a Dict counting, per variable
# name, how many readers are currently reading that variable from the file. The dataset
# is closed when the last reader using it is closed.
const OPEN_NCFILES = Dict{
    Union{String, Vector{String}},
    Tuple{NetCDFDataset, Dict{String, Int}},
}()

"""
    NCFileReader

A struct to read and process NetCDF files.

NCFileReader wants to be smart, e.g., caching reads, or spinning the I/O off to a different
thread (not implemented yet). Multiple NetCDF files can be read at the same time as long as
they can be aggregated along the time dimension.
"""
struct NCFileReader{
    VSTR <: Vector{STR} where {STR <: AbstractString},
    STR2 <: AbstractString,
    DIMS <: Tuple,
    NC <: NetCDFDataset,
    DATES <: AbstractArray{Dates.DateTime},
    PREP <: Function,
    CACHE <: DataStructures.LRUCache{Dates.DateTime, <:AbstractArray},
} <: FileReaders.AbstractFileReader
    """Path of the NetCDF file(s)"""
    file_paths::VSTR

    """Name of the dataset in the NetCDF files"""
    varname::STR2

    """A tuple of arrays with the various physical dimensions where the data is defined
    (e.g., lon/lat)"""
    dimensions::DIMS

    """A tuple with the names of the physical dimensions, in the same order as `dimensions`"""
    dim_names::Tuple

    """A vector of DateTime collecting all the available dates in the files"""
    available_dates::DATES

    """NetCDF dataset opened by NCDataset. Don't forget to close the reader!"""
    dataset::NC

    """Optional function that is applied to the read dataset. Useful to do unit-conversion
    or remove NaNs. Not suitable for anything more complicated than that."""
    preprocess_func::PREP

    """A place where to store values that have been already read. Uses an LRU cache,
    which contains a dictionary mapping dates to arrays, and has a fixed maximum size.
    For static data sets, a sentinel date `DateTime(0)` is used as key."""
    _cached_reads::CACHE

    """Index of the time dimension in the array (typically first). -1 for static datasets"""
    time_index::Int

    """Size of the output array. This is used by read to initialize an array."""
    output_size::Tuple{Vararg{Int}}
end

"""
    FileReaders.NCFileReader(
        file_paths,
        varname::AbstractString;
        preprocess_func = identity,
        cache_max_size:Int = 128,
    )

A struct to efficiently read and process NetCDF files.

When more than one file is passed, the files should contain the time development of one or
multiple variables. Files are joined along the time dimension.

## Argument

`file_paths` can be a string, or a collection of paths to files that contain the
same variables but at different times.

"""
function FileReaders.NCFileReader(
    file_paths,
    varname::AbstractString;
    preprocess_func = identity,
    cache_max_size::Int = 128,
)
    # file_paths could be a vector/tuple or a string. Let's start by standardizing to a
    # vector
    file_paths isa AbstractString && (file_paths = [file_paths])
    only_one_file = length(file_paths) == 1

    # If we have more than one file, we have to aggregate them
    aggtime_kwarg = ()
    if !only_one_file
        # Let's first try to identify the time dimension, if it exists. To do that, we open the
        # first dataset. We need this to aggregate multiple datasets, if data is split across
        # multiple files
        NCDatasets.NCDataset(first(file_paths)) do first_dataset
            is_time = x -> x in TIME_NAMES
            time_dims = filter(is_time, NCDatasets.dimnames(first_dataset))
            if !isempty(time_dims)
                # When loading multifile dataset using NCDatasets.jl, the NetCDF files are
                # not kept open due to the common limitation of 1024 open files per user on
                # Linux. However, for our use case, we will not reach this limit. Hence, we
                # keep the files open with deferopen = false.
                # See: https://github.com/JuliaGeo/NCDatasets.jl/issues/277
                aggtime_kwarg =
                    (:aggdim => first(time_dims), :deferopen => false)
            else
                error(
                    "Multiple files given, but no temporal dimension found. Combining multiple files is only possible along the temporal dimension.",
                )
            end
        end
    end

    # When we have only no time data, we have to pass this as a string
    file_path_to_ncdataset =
        isempty(aggtime_kwarg) ? first(file_paths) : file_paths

    # Get dataset from global dictionary. If not available, open the new dataset and add
    # entry to global dictionary
    # We map the collection of files to the dataset
    dataset, open_varnames = get!(OPEN_NCFILES, file_paths) do
        (
            NCDatasets.NCDataset(file_path_to_ncdataset; aggtime_kwarg...),
            Dict{String, Int}(),
        )
    end
    _register_file!(open_varnames, varname)

    # The dataset is now registered in OPEN_NCFILES; release it if any of the
    # validations below error, so a failed construction does not leak the open
    # file (there is no reader to close yet)
    try
        available_dates = read_available_dates(dataset)

        time_index = -1

        dim_names = NCDatasets.dimnames(dataset[varname])

        if !isempty(available_dates)
            is_time = x -> x in TIME_NAMES

            time_index_vec = findall(is_time, dim_names)
            length(time_index_vec) == 1 ||
                error("Could not find (unique) time dimension")
            time_index = time_index_vec[]

            issorted(available_dates) || error(
                "Cannot process files that are not sorted in time in ($file_paths)",
            )

            # Remove time from the dim names
            dim_names = filter(!is_time, dim_names)
        end

        if all(d in keys(dataset) for d in dim_names)
            dimensions = Tuple(
                NCDatasets.nomissing(Array(dataset[d])) for d in dim_names
            )
        else
            error(
                "$file_paths does not contain information about dimensions $(filter(!in(keys(dataset)), dim_names))",
            )
        end

        # Preprocess the first time point to get the size and element type of the output array
        sample_date =
            isempty(available_dates) ? Dates.DateTime(0) :
            first(available_dates)
        sample = if time_index == -1
            preprocess_func.(Array(dataset[varname]))
        else
            var = dataset[varname]
            slicer = [
                i == time_index ? 1 : Colon() for
                i in 1:length(NCDatasets.dimnames(var))
            ]
            preprocess_func.(var[slicer...])
        end
        output_size = size(sample)

        # Use an LRU cache to store regridded fields
        _cached_reads = DataStructures.LRUCache{Dates.DateTime, typeof(sample)}(
            max_size = cache_max_size,
        )
        _cached_reads[sample_date] = sample

        return NCFileReader(
            file_paths,
            varname,
            dimensions,
            dim_names,
            available_dates,
            dataset,
            preprocess_func,
            _cached_reads,
            time_index,
            output_size,
        )
    catch
        _release_file(file_paths, varname)
        rethrow()
    end
end

"""
    _register_file!(open_varnames, varname)

Count one more reader of `varname` in `open_varnames`, the per-variable reader
counts of an entry of `OPEN_NCFILES`.
"""
function _register_file!(open_varnames, varname)
    open_varnames[varname] = get(open_varnames, varname, 0) + 1
    return nothing
end

"""
    _release_file(file_paths, varname)

Count one fewer reader of `varname` from the files `file_paths` in
`OPEN_NCFILES`, closing and deregistering the NetCDF dataset when no reader is
left. Files that are not registered (e.g. already closed) are skipped.
"""
function _release_file(file_paths, varname)
    haskey(OPEN_NCFILES, file_paths) || return nothing
    dataset, open_varnames = OPEN_NCFILES[file_paths]
    count = get(open_varnames, varname, 0)
    if count > 1
        open_varnames[varname] = count - 1
    else
        delete!(open_varnames, varname)
        if isempty(open_varnames)
            NCDatasets.close(dataset)
            delete!(OPEN_NCFILES, file_paths)
        end
    end
    return nothing
end

"""
    close(file_reader::NCFileReader)

Close `NCFileReader`. If no other `NCFileReader` is using the same file, close the NetCDF file.
"""
function Base.close(file_reader::NCFileReader)
    _release_file(file_reader.file_paths, file_reader.varname)
    return nothing
end

"""
    close_all_ncfiles()

Close all the `NCFileReader` currently open.
"""
function FileReaders.close_all_ncfiles()
    foreach(OPEN_NCFILES) do (_, ds_vars)
        NCDatasets.close(ds_vars[begin])
    end
    empty!(OPEN_NCFILES)
    return nothing
end

"""
    read(file_reader::NCFileReader, date::Dates.DateTime)

Read and preprocess the data at the given `date`.
"""
function FileReaders.read(file_reader::NCFileReader, date::Dates.DateTime)
    dest = valtype(file_reader._cached_reads)(undef, file_reader.output_size...)
    FileReaders.read!(dest, file_reader, date)
    return dest
end

"""
    available_dates(file_reader::NCFileReader)

Returns the dates in the given file.
"""
function FileReaders.available_dates(file_reader::NCFileReader)
    return file_reader.available_dates
end

"""
    read(file_reader::NCFileReader)

Read and preprocess data (for static datasets).
"""
function FileReaders.read(file_reader::NCFileReader)
    dest = valtype(file_reader._cached_reads)(undef, file_reader.output_size...)
    FileReaders.read!(dest, file_reader)
    return dest
end

"""
    read!(dest, file_reader::NCFileReader)

Read and preprocess data (for static datasets), saving the output to `dest`.
"""
function FileReaders.read!(dest, file_reader::NCFileReader)
    isempty(file_reader.available_dates) ||
        error("File contains temporal data, date required")
    dest .= get!(file_reader._cached_reads, Dates.DateTime(0)) do
        file_reader.preprocess_func.(
            Array(file_reader.dataset[file_reader.varname]),
        )
    end
    return nothing
end

"""
    read!(dest, file_reader::NCFileReader, date::Dates.DateTime)

Read and preprocess the data at the given `date`, saving the output to `dest`.
"""
function FileReaders.read!(
    dest,
    file_reader::NCFileReader,
    date::Dates.DateTime,
)
    # DateTime(0) is the sentinel value for static datasets
    if date == Dates.DateTime(0)
        dest .= get!(file_reader._cached_reads, date) do
            file_reader.preprocess_func.(
                Array(file_reader.dataset[file_reader.varname]),
            )
        end
        return nothing
    end

    dest .= get!(file_reader._cached_reads, date) do
        index = findall(d -> d == date, file_reader.available_dates)
        length(index) == 1 || error(
            "Problem with date $date in one of $(file_reader.file_paths)",
        )
        index = index[]
        var = file_reader.dataset[file_reader.varname]
        slicer = [
            i == file_reader.time_index ? index : Colon() for
            i in 1:length(NCDatasets.dimnames(var))
        ]
        file_reader.preprocess_func.(var[slicer...])
    end
    return nothing
end

"""
    MultiColumnNCFileReader

A struct to read and process NetCDF files for multiple columns.
"""
struct MultiColumnNCFileReader{
    VSTR <: AbstractVector,
    STR2 <: AbstractString,
    HDIMS <: Tuple,
    VDIM <: AbstractArray,
    DATES <: AbstractArray{Dates.DateTime},
    PCD <: AbstractVector{<:AbstractArray{Dates.DateTime}},
    NC <: AbstractVector,
    PREP <: Function,
    CACHE <: DataStructures.LRUCache{Dates.DateTime, <:AbstractArray},
    VEC <: AbstractVector{Int},
} <: FileReaders.AbstractFileReader

    """Path of the NetCDF file(s), one collection per column"""
    file_paths::VSTR

    """Name of the dataset in the NetCDF files"""
    varname::STR2

    """A tuple of arrays with the horizontal physical dimensions where the data is
    defined (e.g., (lons, lats))"""
    horizontal_dimensions::HDIMS

    """An array of the vertical levels with size (Nz, Ncolumn). If there is no vertical
    dimension, then this is an array of size (0, Ncolumn)."""
    vertical_dimension::VDIM

    """A vector of DateTime collecting all the available dates in the files"""
    available_dates::DATES

    """A vector containing vectors of dates for each column."""
    per_column_dates::PCD

    """NetCDF datasets opened by NCDataset, one per column. Don't forget to close the
    reader!"""
    datasets::NC

    """Optional function that is applied to the read dataset. Useful to do unit-conversion
    or remove NaNs. Not suitable for anything more complicated than that."""
    preprocess_func::PREP

    """A place where to store values that have been already read. Uses an LRU cache,
    which contains a dictionary mapping dates to arrays, and has a fixed maximum size.
    For static data sets, a sentinel data `DateTime(0)` is used as key."""
    _cached_reads::CACHE

    """Per-column index of the time dimension in the array (typically first). -1 for static
    datasets"""
    time_indices::VEC

    """The tuple `(Nz, Ncolumn)` which is the size of the output array. Used by `read` to
    allocate."""
    output_size::NTuple{2, Int}
end

"""
    _open_source_dataset(source)

Open (or fetch from the `OPEN_NCFILES` cache) the NetCDF dataset for a single
`DataSource`, registering the source's `varname` so the file is closed only
once every reader using it is closed.
"""
function _open_source_dataset(source)
    column_paths = source.file_paths
    ncdataset_arg =
        length(column_paths) == 1 ? first(column_paths) : column_paths
    dataset, open_varnames = get!(OPEN_NCFILES, column_paths) do
        (
            NCDatasets.NCDataset(ncdataset_arg; source.dataset_kwargs...),
            Dict{String, Int}(),
        )
    end
    _register_file!(open_varnames, source.varname)
    return dataset
end

"""
    _stack_columns(columns, file_paths, quantity)

Stack the per-column vectors in `columns` into an `(Nz, Ncolumn)` array.

This errors when the columns do not have the same length and uses `quantity` to
name the inconsistent quantity in the error message.
"""
function _stack_columns(columns, file_paths, quantity)
    allequal(length.(columns)) || error(
        "Columns have inconsistent $quantity; ragged columns are not supported. " *
        join(
            (
                "$(first(fp)): $(length(c))" for
                (fp, c) in zip(file_paths, columns)
            ),
            ", ",
        ),
    )
    return stack(columns)
end

"""
    _read_scalar_coord(dataset, name, file_paths)

Read the single value of the coordinate variable `name` in `dataset`, erroring
when the variable holds more than one value (`file_paths` is not a single
column).
"""
function _read_scalar_coord(dataset, name, file_paths)
    values = dataset[name][:]
    length(values) == 1 || error(
        "Expected a single $name value in $file_paths, found $(length(values)); each column must hold a single (lon, lat) location",
    )
    return only(values)
end

"""
    FileReaders.MultiColumnNCFileReader(
        sources;
        preprocess_func = identity,
        cache_max_size::Int = 128,
    )

Create a `MultiColumnNCFileReader` from `sources`, one column per `DataSource`.

## Arguments

`sources` is a single `DataSource` (one column) or a vector of `DataSource`
(one per column). All sources must read the same variable.

`preprocess_func` preprocesses the data before returning it. This is useful for
handling `NaN`s or converting units.

The `cache_max_size` is the size of the cache used to store data after loading
it from the files.

!!! note "Common times"
    Only the times common to all columns in the datasets are considered.
"""
function FileReaders.MultiColumnNCFileReader(
    sources;
    preprocess_func = identity,
    cache_max_size::Int = 128,
)
    sources = sources isa AbstractVector ? sources : [sources]
    isempty(sources) && error("At least one DataSource must be provided")

    # All data sources should have the same variable name
    varname = first(sources).varname
    all(source -> source.varname == varname, sources) || error(
        "All sources must read the same variable, got $(unique(source.varname for source in sources))",
    )

    file_paths = [source.file_paths for source in sources]

    opened_sources = []
    try
        datasets = map(sources) do source
            dataset = _open_source_dataset(source)
            push!(opened_sources, source)
            dataset
        end

        # In the future, if we want to support x and y instead of lat and lon, we can add it
        # here

        # Per-column longitude, latitude, and z levels. Each column file is
        # assumed to hold a single (lon, lat) location. The coordinate variable
        # names are recorded on each DataSource (user-provided or detected at
        # construction).
        for source in sources
            (
                haskey(source.coord_names, :lon) &&
                haskey(source.coord_names, :lat)
            ) || error(
                "No longitude/latitude variables identified in $(first(source.file_paths)) (searched $(COORD_NAMES.lon) and $(COORD_NAMES.lat)); pass `coord_names` to DataSource",
            )
        end
        lons = [
            _read_scalar_coord(
                dataset,
                source.coord_names.lon,
                source.file_paths,
            ) for (source, dataset) in zip(sources, datasets)
        ]
        lats = [
            _read_scalar_coord(
                dataset,
                source.coord_names.lat,
                source.file_paths,
            ) for (source, dataset) in zip(sources, datasets)
        ]

        # Create an array of size (Nz, Ncolumn) where each column of the array
        # is the vertical levels for that column. It is not necessarily true
        # that the vertical levels are the same across columns.
        z_columns = [
            NCDatasets.nomissing(dataset[source.coord_names.z][:]) for
            (source, dataset) in zip(sources, datasets) if
            haskey(source.coord_names, :z)
        ]
        length(z_columns) == 0 ||
            length(z_columns) == length(datasets) ||
            error(
                "Inconsistent vertical levels: $(length(z_columns)) of $(length(datasets)) columns have a vertical coordinate. Either all columns or no columns must have vertical levels.",
            )
        zs =
            isempty(z_columns) ? Array{Float64}(undef, 0, length(datasets)) :
            _stack_columns(z_columns, file_paths, "numbers of z levels")

        # Per-column index of the time dimension. A column whose variable has no
        # time dimension is "static" and gets the sentinel value of -1
        time_indices = [source.time_index for source in sources]
        per_column_dates = [source.available_dates for source in sources]

        # All columns are static or time varying
        is_static = all(==(-1), time_indices)
        is_time_varying = all(!=(-1), time_indices)
        is_static ||
            is_time_varying ||
            error("Some columns have a time dimension and some do not")

        # Only the times common to all columns are considered. The result is
        # sorted because intersect keeps the order of its first argument, which
        # DataSource validated as sorted. Keep each column's own dates
        # (`per_column_dates`) so reads can look up a date's position within a
        # column without re-reading it from disk.
        available_dates = reduce(intersect, per_column_dates)
        is_time_varying &&
            isempty(available_dates) &&
            error("Columns are time-varying but share no common dates")

        # Get the output size and element type. The output size and element type
        # is used by read when initializing the array. Furthermore, the element
        # type is used to provide a concrete type for the cache.
        sample_per_column = map(datasets, time_indices) do dataset, time_index
            var = dataset[varname]
            if time_index == -1
                preprocess_func.(var[:])
            else
                slicer = [
                    i == time_index ? 1 : Colon() for
                    i in 1:length(NCDatasets.dimnames(var))
                ]
                vec(preprocess_func.(var[slicer...]))
            end
        end
        sample = _stack_columns(sample_per_column, file_paths, "data lengths")
        output_size = size(sample)

        _cached_reads = DataStructures.LRUCache{Dates.DateTime, typeof(sample)}(
            max_size = cache_max_size,
        )

        return MultiColumnNCFileReader(
            file_paths,
            varname,
            (lons, lats),
            zs,
            available_dates,
            per_column_dates,
            datasets,
            preprocess_func,
            _cached_reads,
            time_indices,
            output_size,
        )
    catch
        foreach(
            source -> _release_file(source.file_paths, varname),
            opened_sources,
        )
        rethrow()
    end
end

"""
    close(file_reader::MultiColumnNCFileReader)

Close `MultiColumnNCFileReader`. For each underlying file, if no other reader is using it,
close the NetCDF dataset.
"""
function Base.close(file_reader::MultiColumnNCFileReader)
    for column_paths in file_reader.file_paths
        _release_file(column_paths, file_reader.varname)
    end
    return nothing
end

"""
    _read_all_columns(file_reader::MultiColumnNCFileReader)

Helper function to read in the columns of datasets in `file_reader`.

This is only used when the columns do not vary in time.
"""
function _read_all_columns(file_reader::MultiColumnNCFileReader)
    dest = valtype(file_reader._cached_reads)(undef, file_reader.output_size...)
    for (j, dataset) in enumerate(file_reader.datasets)
        # Each column is a single (lon, lat) point, so the data flattens to its
        # `Nz`-long profile (or length 1 when there is no z).
        raw = dataset[file_reader.varname][:]
        @views dest[:, j] .= file_reader.preprocess_func.(raw)
    end
    return dest
end

"""
    read(file_reader::MultiColumnNCFileReader, date::Dates.DateTime)

Read and preprocess the data at the given `date` for every column, returning a array of size
`(Nz, Ncolumn)` (`Nz` is the number of z levels, or 1 when there is no z).
"""
function FileReaders.read(
    file_reader::MultiColumnNCFileReader,
    date::Dates.DateTime,
)
    dest = valtype(file_reader._cached_reads)(undef, file_reader.output_size...)
    FileReaders.read!(dest, file_reader, date)
    return dest
end

"""
    available_dates(file_reader::MultiColumnNCFileReader)

Return the dates common across the columns.
"""
function FileReaders.available_dates(file_reader::MultiColumnNCFileReader)
    return file_reader.available_dates
end

"""
    read(file_reader::MultiColumnNCFileReader)

Read and preprocess data (for static datasets) for every column.
"""
function FileReaders.read(file_reader::MultiColumnNCFileReader)
    dest = valtype(file_reader._cached_reads)(undef, file_reader.output_size...)
    FileReaders.read!(dest, file_reader)
    return dest
end

"""
    read!(dest, file_reader::MultiColumnNCFileReader)

Read and preprocess data (for static datasets), saving the output to `dest`.
"""
function FileReaders.read!(dest, file_reader::MultiColumnNCFileReader)
    isempty(file_reader.available_dates) ||
        error("File contains temporal data, date required")

    # When there are no dates, we use DateTime(0) as the cache key
    dest .= get!(file_reader._cached_reads, Dates.DateTime(0)) do
        _read_all_columns(file_reader)
    end
    return nothing
end

"""
    read!(dest, file_reader::MultiColumnNCFileReader, date::Dates.DateTime)

Read and preprocess the data at the given `date`, saving the output to `dest`.
"""
function FileReaders.read!(
    dest,
    file_reader::MultiColumnNCFileReader,
    date::Dates.DateTime,
)
    # DateTime(0) is the sentinel value for static datasets
    if date == Dates.DateTime(0)
        dest .= get!(file_reader._cached_reads, date) do
            _read_all_columns(file_reader)
        end
        return nothing
    end

    dest .= get!(file_reader._cached_reads, date) do
        # Read each column's slice at `date` into a single preallocated
        # `(Nz, Ncolumn)` array, one column at a time (instead of allocating a
        # vector per column and stacking them).
        read_data = valtype(file_reader._cached_reads)(
            undef,
            file_reader.output_size...,
        )
        for (j, (dataset, time_index, column_dates)) in enumerate(
            zip(
                file_reader.datasets,
                file_reader.time_indices,
                file_reader.per_column_dates,
            ),
        )
            var = dataset[file_reader.varname]
            # `available_dates` is the intersection across columns; the position of `date`
            # within an individual column's time dimension can differ, so look it up in the
            # time dimension of the column
            index = searchsortedfirst(column_dates, date)
            (index <= length(column_dates) && column_dates[index] == date) || error(
                "Date $date is not available in column $j ($(first(file_reader.file_paths[j])))",
            )
            slicer = [
                i == time_index ? index : Colon() for
                i in 1:length(NCDatasets.dimnames(var))
            ]
            # Each column is a single (lon, lat) point, so the slice flattens to
            # its `Nz`-long profile (or length 1 when there is no z).
            raw = vec(var[slicer...])
            @views read_data[:, j] .= file_reader.preprocess_func.(raw)
        end
        return read_data
    end
    return nothing
end

end
