module DataSourceExt

import ClimaUtilities.FileReaders

import Dates
import NCDatasets

include("nc_common.jl")

"""
    DataSource

A lightweight description of a variable in one or more datasets which includes
the path(s) to its source(s), the variable name, and its time axis. A
`DataSource` holds no data itself. It records what is needed to read the
variable, and the sources are joined along the time dimension when several are
given.
"""
struct DataSource{CN <: NamedTuple, DS_KWARGS <: Tuple}
    """Path(s) to the variable's source data: a single path, or several paths
    to be joined along the time dimension."""
    file_paths::Vector{String}

    """Name of the variable this source reads."""
    varname::String

    """Calendar dates available in the source(s). Empty when the variable has
    no time dimension."""
    available_dates::Vector{Dates.DateTime}

    """Index of the time dimension within the variable's dimensions, or `-1`
    when the variable has no time dimension."""
    time_index::Int

    """Names of the coordinate variables in the source(s) by type of
    coordinates."""
    coord_names::CN

    """Keyword arguments forwarded when opening the datasets."""
    dataset_kwargs::DS_KWARGS
end

"""
    FileReaders.DataSource(
        file_paths,
        varname::String;
        time_transform = identity,
        coord_names = nothing,
    )

Create a `DataSource` from `file_paths` for the variable `varname`.

The argument `file_paths` is a single path or a collection of paths. If multiple
paths are specified, then the datasets are joined along the time dimension. The
paths must be in chronological order, and the coordinate variables must hold
the same values in every file.

The keyword argument `time_transform` is applied element-wise to each available
date and must return a `Dates.DateTime`. The keyword argument `time_transform`
is ignored for dataset with no time dimension.

The keyword argument `coord_names` names the coordinate variables in the dataset
by type of coordinate, e.g. `(; lon = "lon", lat = "lat", z = "height")`. When
`coord_names` is `nothing`, the coordinates are automatically detected.
"""
function FileReaders.DataSource(
    file_paths,
    varname::String;
    time_transform = identity,
    coord_names = nothing,
)
    file_paths isa String && (file_paths = [file_paths])

    isempty(file_paths) &&
        error("The argument file_paths must contain at least one path")

    # Open dataset by itself or by concating the datasets along the time
    # dimension
    only_one_file = length(file_paths) == 1
    dataset_kwargs = ()
    is_time = x -> x in TIME_NAMES
    if !only_one_file
        # Identify the time dimension from the first file so NCDatasets can join
        # the files along it.
        NCDatasets.NCDataset(first(file_paths)) do first_dataset
            time_dims = filter(is_time, NCDatasets.dimnames(first_dataset))
            isempty(time_dims) && error(
                "Multiple files given for datasets, but no temporal dimension found. Combining multiple files is only possible along the temporal dimension.",
            )

            # When loading multifile dataset using NCDatasets.jl, the NetCDF files are
            # not kept open due to the common limitation of 1024 open files per user on
            # Linux. However, for our use case, we will not reach this limit. Hence, we
            # keep the files open with deferopen = false.
            # See: https://github.com/JuliaGeo/NCDatasets.jl/issues/277
            dataset_kwargs = (:aggdim => first(time_dims), :deferopen => false)
        end
    end

    # Open a single path by itself and open multiple paths by aggregating along
    # the time dimension
    files = only_one_file ? first(file_paths) : file_paths
    time_index, available_dates, coord_names =
        NCDatasets.NCDataset(files; dataset_kwargs...) do dataset

            # Check varname exists in the dataset
            varname in keys(dataset) ||
                error("$varname is not available in $file_paths")

            # Find the (unique) time dimension of the variable, if any
            time_index_vec =
                findall(is_time, NCDatasets.dimnames(dataset[varname]))
            if isempty(time_index_vec)
                time_index = -1
            elseif length(time_index_vec) == 1
                time_index = only(time_index_vec)
            else
                error("Could not find (unique) time dimension")
            end

            available_dates =
                time_index != -1 ?
                time_transform.(read_available_dates(dataset)) :
                Dates.DateTime[]

            if !isempty(available_dates)
                issorted(available_dates) ||
                    error("Dates are not sorted in $file_paths")
                allunique(available_dates) ||
                    error("Dates are not unique in $file_paths")
            end

            return time_index,
            available_dates,
            _resolve_coord_names(coord_names, dataset, file_paths)
        end

    only_one_file || _check_consistent_coords(coord_names, file_paths)

    return DataSource(
        file_paths,
        varname,
        available_dates,
        time_index,
        coord_names,
        dataset_kwargs,
    )
end

"""
    _resolve_coord_names(coord_names, dataset, file_paths)

Return the coordinate names to store on a `DataSource` for `dataset`.
"""
function _resolve_coord_names(coord_names, dataset, file_paths)
    isnothing(coord_names) && return detect_coord_names(dataset, file_paths)
    coord_names isa NamedTuple || error(
        "coord_names must be a NamedTuple, e.g. (; lon = \"lon\", lat = \"lat\", z = \"z\")",
    )
    unrecognized = setdiff(keys(coord_names), keys(COORD_NAMES))
    isempty(unrecognized) || error(
        "Unrecognized coordinate types ($(join(unrecognized, ", "))) in coord_names; the recognized coordinate types are $(join(keys(COORD_NAMES), ", "))",
    )
    for (coord_type, name) in pairs(coord_names)
        haskey(dataset, name) ||
            error("$name ($coord_type) is not available in $file_paths")
    end
    return map(String, coord_names)
end

"""
    _check_consistent_coords(coord_names, file_paths)

Check that each coordinate variable in `coord_names` holds the same values in
every file of a multi-file dataset.
"""
function _check_consistent_coords(coord_names, file_paths)
    isempty(coord_names) && return nothing
    reference = NCDatasets.NCDataset(first(file_paths)) do dataset
        map(name -> Array(dataset[name]), coord_names)
    end
    for path in file_paths[2:end]
        NCDatasets.NCDataset(path) do dataset
            for (coord_type, name) in pairs(coord_names)
                haskey(dataset, name) ||
                    error("$name ($coord_type) is not available in $path")
                values = Array(dataset[name])
                (
                    size(values) == size(reference[coord_type]) &&
                    isapprox(values, reference[coord_type])
                ) || error(
                    "$name in $path does not match its values in $(first(file_paths)); files joined along the time dimension must hold the same coordinate values",
                )
            end
        end
    end
    return nothing
end

end
