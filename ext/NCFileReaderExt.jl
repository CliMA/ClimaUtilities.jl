module NCFileReaderExt

import ClimaUtilities.DataStructures
import ClimaUtilities.FileReaders

import Dates
import NCDatasets

include("nc_common.jl")

# We allow multiple NCFileReader to share the same underlying NCDataset. For this, we put
# all the NCDataset into a dictionary where we keep track of them. OPEN_NCFILES is
# dictionary that maps Vector of file paths (or a single string) to a Tuple with the first
# element being the NCDataset and the second element being a Set of Strings, the variables
# that are being read from that file. Every time a NCFileReader is created, this Set is
# modified by adding or removing a varname.
const OPEN_NCFILES =
    Dict{Union{String, Vector{String}}, Tuple{NetCDFDataset, Set{String}}}()

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

    """A tuple with the names of the physcial dimensions, in the same order as `dimensions`"""
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
    For static data sets, a sentinel data `DateTime(0)` is used as key."""
    _cached_reads::CACHE

    """Index of the time dimension in the array (typically first). -1 for static datasets"""
    time_index::Int
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
    # file_paths could be a vector/tuple or a string. Let's start by standarizing to a
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
            is_time = x -> x == "time" || x == "date" || x == "t"
            time_dims = filter(is_time, NCDatasets.dimnames(first_dataset))
            if !isempty(time_dims)
                aggtime_kwarg = (:aggdim => first(time_dims),)
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
    dataset, open_varnames = get!(
        OPEN_NCFILES,
        file_paths,  # We map the collection of files to the dataset
        (
            NCDatasets.NCDataset(file_path_to_ncdataset; aggtime_kwarg...),
            Set([varname]),
        ),
    )
    # push! will do nothing when file is opened for the first time
    push!(open_varnames, varname)

    available_dates = read_available_dates(dataset)

    time_index = -1

    dim_names = NCDatasets.dimnames(dataset[varname])

    if !isempty(available_dates)
        is_time = x -> x == "time" || x == "date" || x == "t"

        time_index_vec = findall(is_time, dim_names)
        length(time_index_vec) == 1 ||
            error("Could not find (unique) time dimension")
        time_index = time_index_vec[]

        issorted(available_dates) || error(
            "Cannot process files that are not sorted in time ($file_path)",
        )

        # Remove time from the dim names
        dim_names = filter(!is_time, dim_names)
    end

    if all(d in keys(dataset) for d in dim_names)
        dimensions =
            Tuple(NCDatasets.nomissing(Array(dataset[d])) for d in dim_names)
    else
        error("$file_path does not contain information about dimensions")
    end

    # Use an LRU cache to store regridded fields
    _cached_reads = DataStructures.LRUCache{Dates.DateTime, Array}(
        max_size = cache_max_size,
    )

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
    )
end

"""
    close(file_reader::NCFileReader)

Close `NCFileReader`. If no other `NCFileReader` is using the same file, close the NetCDF file.
"""
function Base.close(file_reader::NCFileReader)
    # If we don't have the key, we don't have to do anything (we already closed
    # the file)
    files_are_not_open = !haskey(OPEN_NCFILES, file_reader.file_paths)
    files_are_not_open && return nothing

    open_variables = OPEN_NCFILES[file_reader.file_paths][end]
    pop!(open_variables, file_reader.varname)
    if isempty(open_variables)
        NCDatasets.close(file_reader.dataset)
        delete!(OPEN_NCFILES, file_reader.file_paths)
    end
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
    # For cache hits, return a copy to give away ownership of the data (if we were to just
    # return _cached_reads[date], modifying the return value would modify the private state
    # of the file reader)

    if haskey(file_reader._cached_reads, date)
        return copy(file_reader._cached_reads[date])
    end

    # DateTime(0) is the sentinel value for static datasets
    if date == Dates.DateTime(0)
        return get!(file_reader._cached_reads, date) do
            file_reader.preprocess_func.(
                Array(file_reader.dataset[file_reader.varname])
            )
        end
    end

    index = findall(d -> d == date, file_reader.available_dates)
    length(index) == 1 ||
        error("Problem with date $date in $(file_reader.file_path)")
    index = index[]

    var = file_reader.dataset[file_reader.varname]
    slicer = [
        i == file_reader.time_index ? index : Colon() for
        i in 1:length(NCDatasets.dimnames(var))
    ]
    return file_reader.preprocess_func.(
        file_reader.dataset[file_reader.varname][slicer...]
    )
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
    isempty(file_reader.available_dates) ||
        error("File contains temporal data, date required")

    # When there's no dates, we use DateTime(0) as key
    return get!(file_reader._cached_reads, Dates.DateTime(0)) do
        return file_reader.preprocess_func.(
            Array(file_reader.dataset[file_reader.varname])
        )
    end
end

"""
    read!(dest, file_reader::NCFileReader)

Read and preprocess data (for static datasets), saving the output to `dest`.
"""
function FileReaders.read!(dest, file_reader::NCFileReader)
    dest .= FileReaders.read(file_reader)
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
    dest .= FileReaders.read(file_reader, date)
    return nothing
end

"""
    MultiColumnNCFileReader

A struct to read and process NetCDF files for multiple columns.
"""
struct MultiColumnNCFileReader{
    VSTR,
    STR2,
    HDIMS,
    VDIM,
    DATES,
    NC,
    PREP,
    CACHE,
    VEC,
} <: FileReaders.AbstractFileReader

    """Path of the NetCDF file(s)"""
    file_paths::VSTR

    """Name of the dataset in the NetCDF files"""
    varname::STR2

    """A tuple of arrays with the horizontal physical dimensions where the data is
    defined (e.g., (lons, lats))"""
    horizontal_dimensions::HDIMS

    """The per-column vertical levels where the data is defined (e.g., zs), or an
    empty collection when the data has no vertical dimension"""
    vertical_dimension::VDIM

    """A vector of DateTime collecting all the available dates in the files"""
    available_dates::DATES

    """NetCDF dataset opened by NCDataset. Don't forget to close the reader!"""
    datasets::NC

    """Optional function that is applied to the read dataset. Useful to do unit-conversion
    or remove NaNs. Not suitable for anything more complicated than that."""
    preprocess_func::PREP

    """A place where to store values that have been already read. Uses an LRU cache,
    which contains a dictionary mapping dates to arrays, and has a fixed maximum size.
    For static data sets, a sentinel data `DateTime(0)` is used as key."""
    _cached_reads::CACHE

    """Index of the time dimension in the array (typically first). -1 for static datasets"""
    time_index::VEC
end

# TODO: Check this
function _standardize_column_file_paths(file_paths)
    file_paths isa AbstractString && (file_paths = [file_paths])
    isempty(file_paths) &&
        error("`file_paths` must contain at least one column")
    column_file_paths =
        first(file_paths) isa AbstractString ? [[String(f)] for f in file_paths] :
        [collect(String, col) for col in file_paths]
    any(isempty, column_file_paths) &&
        error("Each column must have at least one file path")
    return column_file_paths
end

# TODO: Check this
function _open_multicolumn_dataset(column_paths::Vector{String}, varname)
    only_one_file = length(column_paths) == 1
    aggtime_kwarg = ()
    if !only_one_file
        # Identify the time dimension from the first file so NCDatasets can join
        # the files along it.
        NCDatasets.NCDataset(first(column_paths)) do first_dataset
            is_time = x -> x == "time" || x == "date" || x == "t"
            time_dims = filter(is_time, NCDatasets.dimnames(first_dataset))
            isempty(time_dims) && error(
                "Multiple files given for a column, but no temporal dimension found. Combining multiple files is only possible along the temporal dimension.",
            )
            aggtime_kwarg = (:aggdim => first(time_dims),)
        end
    end
    # A single file is opened by its path; aggregated columns are opened from the
    # collection with the `aggdim` keyword.
    ncdataset_arg = only_one_file ? first(column_paths) : column_paths
    dataset, open_varnames = get!(OPEN_NCFILES, column_paths) do
        (NCDatasets.NCDataset(ncdataset_arg; aggtime_kwarg...), Set([varname]))
    end
    push!(open_varnames, varname)
    return dataset
end

"""
    FileReaders.MultiColumnNCFileReader(
        file_paths,
        varname::AbstractString;
        preprocess_func = identity,
        cache_size::Int = 128,
    )

Create a `MultiColumnNCFileReader` to read `varname` for multiple columns from `file_paths`.

`file_paths` can be given in one of the following forms:
- a single path (`"a.nc"`): a single column read from a single file;
- a vector of paths (`["a.nc", "b.nc"]`): one column per path, each read from a
  single file;
- a vector of vectors of paths (`[["a1.nc", "a2.nc"], ["b.nc"]]`): one column per
  inner vector, where the files of each inner vector are aggregated along the
  time dimension (mirroring the single-column `NCFileReader`).
"""
function FileReaders.MultiColumnNCFileReader(
    file_paths,
    varname::AbstractString;
    preprocess_func = identity,
    cache_size::Int = 128, # TODO: This won't be a LRU cache and probably will be a ring buffer
)
    # TODO: Better to specify the name of the horizontal dimensions (e.g. x and
    # y or lat and lon) as an argument, then DataHandler can handle it

    file_paths = _standardize_column_file_paths(file_paths)

    # Open all the datasets that we need (one per column, aggregating along time
    # when a column spans multiple files).
    datasets =
        map(column_paths -> _open_multicolumn_dataset(column_paths, varname), file_paths)

    # Per-column longitude, latitude, and z levels. Each column file is assumed to
    # hold a single (lon, lat) location.
    lons = [
        only(dataset["longitude"][:]) for
        dataset in datasets if haskey(dataset, "longitude")
    ]
    lats = [
        only(dataset["latitude"][:]) for
        dataset in datasets if haskey(dataset, "latitude")
    ]
    zs = [dataset["z"][:] for dataset in datasets if haskey(dataset, "z")]

    # Per-column index of the time dimension. A column whose variable has no time
    # dimension is "static" and gets -1 (mirrors the single-column reader).
    is_time = x -> x == "time" || x == "date" || x == "t"
    time_indices = map(datasets) do dataset
        time_index_vec = findall(is_time, NCDatasets.dimnames(dataset[varname]))
        if isempty(time_index_vec)
            return -1
        elseif length(time_index_vec) == 1
            return only(time_index_vec)
        else
            error("Could not find (unique) time dimension")
        end
    end
    # Either every column is static, or none is - mixing is not supported
    all(==(-1), time_indices) ||
        all(!=(-1), time_indices) ||
        error("Some columns have a time dimension and some do not")

    # Dates common to all columns, sorted (the DataHandler relies on ordering)
    available_dates =
        sort(reduce(intersect, map(read_available_dates, datasets)))
    if all(!=(-1), time_indices) && isempty(available_dates)
        error("Columns are time-varying but share no common dates")
    end

    # TODO: Temporary use of LRU cache (will replace with ring buffer)
    _cached_reads =
        DataStructures.LRUCache{Dates.DateTime, Array}(max_size = cache_size)

    return MultiColumnNCFileReader(
        file_paths,
        varname,
        (lons, lats),
        zs,
        available_dates,
        datasets,
        preprocess_func,
        _cached_reads,
        time_indices,
    )
end

# TODO: Concerns
# I don't know how the columns is arranged since I don't know the space
# Check if the DataLoader know the space. If it does, then we might need to
# support a permute_columns! function for the data loader which permute the
# columns or add a keyword argument for it

"""
    close(file_reader::MultiColumnNCFileReader)

Close `MultiColumnNCFileReader`. For each underlying file, if no other reader is
using it, close the NetCDF dataset.
"""
function Base.close(file_reader::MultiColumnNCFileReader)
    # Each column's dataset is registered in `OPEN_NCFILES` keyed by that column's
    # file collection (a single-file column is keyed by its one-element vector),
    # so we release them one at a time. This is the single-column `close` wrapped
    # in a loop over columns.
    for (column_paths, dataset) in
        zip(file_reader.file_paths, file_reader.datasets)
        # If we don't have the key, the file is already closed; skip it
        haskey(OPEN_NCFILES, column_paths) || continue
        open_variables = OPEN_NCFILES[column_paths][end]
        delete!(open_variables, file_reader.varname)
        if isempty(open_variables)
            NCDatasets.close(dataset)
            delete!(OPEN_NCFILES, column_paths)
        end
    end
    return nothing
end

# Read and preprocess the full (all-times) array for every column and stack them
# along a new trailing column axis. Shared by the static `read` and the
# `DateTime(0)` sentinel path.
function _read_all_columns(file_reader::MultiColumnNCFileReader)
    per_column = map(file_reader.datasets) do dataset
        # Each column is a single (lon, lat) point, so the data flattens to its
        # `Nz`-long profile (or length 1 when there is no z).
        vec(file_reader.preprocess_func.(Array(dataset[file_reader.varname])))
    end
    return stack(per_column)
end

"""
    read(file_reader::MultiColumnNCFileReader, date::Dates.DateTime)

Read and preprocess the data at the given `date` for every column, returning a
`(Nz, Ncolumn)` array (`Nz` is the number of z levels, or 1 when there is no z).
"""
function FileReaders.read(
    file_reader::MultiColumnNCFileReader,
    date::Dates.DateTime,
)
    # For cache hits, return a copy to give away ownership of the data (mirrors
    # the single-column `read`)
    if haskey(file_reader._cached_reads, date)
        return copy(file_reader._cached_reads[date])
    end

    # DateTime(0) is the sentinel value for static datasets
    if date == Dates.DateTime(0)
        return get!(file_reader._cached_reads, date) do
            _read_all_columns(file_reader)
        end
    end

    # One slice per column. Like the single-column `read`, a normal-date read is
    # NOT inserted into the cache (only the static sentinel is cached).
    per_column = map(
        file_reader.datasets,
        file_reader.time_index,  # NOTE: this field holds a *vector* of per-column time indices
    ) do dataset, time_index
        var = dataset[file_reader.varname]
        # `available_dates` is the intersection across columns; the position of
        # `date` within THIS column's own time axis can differ, so look it up here
        dataset_dates = read_available_dates(dataset)
        index = findall(==(date), dataset_dates)
        length(index) == 1 ||
            error("Problem with date $date in $(file_reader.file_paths)")
        slicer = [
            i == time_index ? only(index) : Colon() for
            i in 1:length(NCDatasets.dimnames(var))
        ]
        # Each column is a single (lon, lat) point, so the slice flattens to its
        # `Nz`-long profile (or length 1 when there is no z); stacking the columns
        # then gives `(Nz, Ncolumn)`.
        # TODO: A better way of doing this is to allocate the array up front
        # and fill it up
        vec(file_reader.preprocess_func.(var[slicer...]))
    end
    return stack(per_column)
end

"""
    available_dates(file_reader::MultiColumnNCFileReader)

Return the dates available across the columns (the shared/intersected dates).
"""
function FileReaders.available_dates(file_reader::MultiColumnNCFileReader)
    return file_reader.available_dates
end

"""
    read(file_reader::MultiColumnNCFileReader)

Read and preprocess data (for static datasets) for every column.
"""
function FileReaders.read(file_reader::MultiColumnNCFileReader)
    isempty(file_reader.available_dates) ||
        error("File contains temporal data, date required")

    # When there are no dates, we use DateTime(0) as the cache key
    return get!(file_reader._cached_reads, Dates.DateTime(0)) do
        _read_all_columns(file_reader)
    end
end

"""
    read!(dest, file_reader::MultiColumnNCFileReader)

Read and preprocess data (for static datasets), saving the output to `dest`.
"""
function FileReaders.read!(dest, file_reader::MultiColumnNCFileReader)
    # TODO: This is strange to me, since read! is suppose to be the full
    # implementation and the implementation of read allocate an array and read!
    # fill it out
    dest .= FileReaders.read(file_reader)
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
    dest .= FileReaders.read(file_reader, date)
    return nothing
end

end
