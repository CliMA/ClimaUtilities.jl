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
            is_time =
                x -> x == "time" || x == "date" || x == "t" || x == "valid_time"
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
            is_time =
                x -> x == "time" || x == "date" || x == "t" || x == "valid_time"

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

end
