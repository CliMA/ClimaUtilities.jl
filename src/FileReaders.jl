"""
    FileReaders

The `FileReaders` module implements backends to read and process input files.

Given that reading from disk can be an expensive operation, this module provides a pathway
to optimize the performance (if needed).

The FileReaders module contains a global cache of all the NCDatasets that are currently open.
This allows multiple NCFileReader to share the underlying file without overhead.
"""
module FileReaders
import Dates
import ClimaUtilities.Utils: is_pkg_loaded

abstract type AbstractFileReader end

"""
    DataSource

A lightweight description of a variable in one or more datasets which includes
the path(s) to its source(s), the variable name, the dates of its time axis
(empty without a time dimension), and the names of its coordinate variables by
type of coordinate. A `DataSource` holds no data itself. It records what is
needed to read the variable, and the sources are joined along the time dimension
when several are given. It holds no data.
"""
struct DataSource{CN <: NamedTuple, K <: Tuple}
    file_paths::Vector{String}
    varname::String
    available_dates::Vector{Dates.DateTime}
    time_index::Int
    coord_names::CN
    dataset_kwargs::K
end

# Sources built independently from the same files compare equal
# This is needed because Base.:(==) defaults to Base.:(===) if no implementation
# is found and vectors are false with ===
Base.:(==)(a::DataSource, b::DataSource) =
    all(f -> getfield(a, f) == getfield(b, f), fieldnames(DataSource))
Base.hash(s::DataSource, h::UInt) =
    foldl((h, f) -> hash(getfield(s, f), h), fieldnames(DataSource); init = h)

function NCFileReader end

function read end

function read! end

function available_dates end

function close_all_ncfiles end

extension_fns = [
    :NCDatasets => [
        :NCFileReader,
        :DataSource,
        :read,
        :read!,
        :available_dates,
        :close_all_ncfiles,
        :close,
    ],
]

function __init__()
    # Register error hint if a package is not loaded
    if isdefined(Base.Experimental, :register_error_hint)
        Base.Experimental.register_error_hint(
            MethodError,
        ) do io, exc, _argtypes, _kwargs
            for (pkg, fns) in extension_fns
                if Symbol(exc.f) in fns && !is_pkg_loaded(pkg)
                    print(io, "\nImport $pkg to enable `$(exc.f)`.";)
                end
            end
        end
    end
end

end
