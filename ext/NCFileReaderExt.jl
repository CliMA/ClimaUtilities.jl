module NCFileReaderExt

import ClimaUtilities.FileReaders

import Dates
import NCDatasets

include("nc_common.jl")

# We allow multiple NCFileReader to share the same underlying NCDataset. For this, we put
# all the NCDataset into a dictionary where we keep track of them. OPEN_NCFILES is
# dictionary that maps file paths to a Tuple with the first element being the NCDataset and
# the second element being a Set of Strings, the variables that are being read from that
# file. Every time a NCFileReader is created, this Set is modified by adding or removing a
# varname.
const OPEN_NCFILES = Dict{String, Tuple{NCDatasets.NCDataset, Set{String}}}()

"""
    NCFileReader

A struct to read and process NetCDF files.

NCFileReader wants to be smart, e.g., caching reads, or spinning the I/O off to a different
thread (not implemented yet).
"""
struct NCFileReader{
    STR1 <: AbstractString,
    STR2 <: AbstractString,
    DIMS <: Tuple,
    NC <: NCDatasets.NCDataset,
    DATES <: AbstractArray{<:Dates.DateTime},
    CACHE,
    PREP <: Function,
} <: FileReaders.AbstractFileReader
    """Path of the NetCDF file"""
    file_path::STR1

    """Name of the dataset in the NetCDF file"""
    varname::STR2

    """A tuple of arrays with the various physical dimensions where the data is defined
    (e.g., lon/lat)"""
    dimensions::DIMS

    """A vector of DateTime collecting all the available dates in the file"""
    available_dates::DATES

    """NetCDF file opened by NCDataset. Don't forget to close the reader!"""
    dataset::NC

    """Optional function that is applied to the read dataset. Useful to do unit-conversion
    or remove NaNs. Not suitable for anything more complicated than that."""
    preprocess_func::PREP

    """A place where to store values that have been already read. A dictionary mapping dates
    to arrays. For static data sets, a sentinel data DateTime(0) is used as key."""
    _cached_reads::CACHE

    """Index of the time dimension in the array (typically first). -1 for static datasets"""
    time_index::Int
end

"""
    NCFileReader(file_path::AbstractString, varname::AbstractString)

A struct to efficiently read and process NetCDF files.
"""
function FileReaders.NCFileReader(
    file_path::AbstractString,
    varname::AbstractString;
    preprocess_func = identity,
)

    # Get dataset from global dictionary. If not available, open new file and add entry to
    # global dictionary
    dataset, open_varnames = get!(
        OPEN_NCFILES,
        file_path,
        (NCDatasets.NCDataset(file_path), Set([varname])),
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

    # NOTE: This is not concretely typed.
    _cached_reads = Dict{Dates.DateTime, Array}()

    return NCFileReader(
        file_path,
        varname,
        dimensions,
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
    file_is_not_open = !haskey(OPEN_NCFILES, file_reader.file_path)
    file_is_not_open && return nothing

    open_variables = OPEN_NCFILES[file_reader.file_path][end]
    pop!(open_variables, file_reader.varname)
    if isempty(open_variables)
        NCDatasets.close(file_reader.dataset)
        delete!(OPEN_NCFILES, file_reader.file_path)
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

    return get!(file_reader._cached_reads, date) do
        var = file_reader.dataset[file_reader.varname]
        slicer = [
            i == file_reader.time_index ? index : Colon() for
            i in 1:length(NCDatasets.dimnames(var))
        ]
        return file_reader.preprocess_func.(
            file_reader.dataset[file_reader.varname][slicer...]
        )
    end
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

end
