module DataSourceExt

import Dates
import NCDatasets

import ClimaUtilities.FileReaders
import ClimaUtilities.FileReaders: DataSource
import ..NCFileReaderExt:
    TIME_NAMES, COORD_NAMES, read_available_dates, detect_coord_names

"""
    DataSource(file_paths, varname; time_transform = identity, coord_names = nothing)

Describe the variable `varname` in the NetCDF file `file_paths`, or in several
files joined along the time dimension when a collection of paths is given, in
chronological order and with the same coordinate values in every file.

`time_transform` is applied to each date of the time axis and must return a
`Dates.DateTime`. `coord_names` names the coordinate variables by type of
coordinate, e.g. `(; lon = "lon", lat = "lat", z = "height")`; when `nothing`,
they are automatically detected.
"""
function FileReaders.DataSource(
    file_paths,
    varname::AbstractString;
    time_transform = identity,
    coord_names = nothing,
)
    file_paths isa AbstractString && (file_paths = [file_paths])
    isempty(file_paths) && error("file_paths must contain at least one path")
    file_paths = String.(collect(file_paths))
    is_time = in(TIME_NAMES)

    dataset_kwargs = ()
    if length(file_paths) > 1
        time_dims = NCDatasets.NCDataset(first(file_paths)) do ds
            filter(is_time, NCDatasets.dimnames(ds))
        end
        isempty(time_dims) && error(
            "Multiple files given, but no temporal dimension found. Combining multiple files is only possible along the temporal dimension.",
        )
        # Keep the files open, see https://github.com/JuliaGeo/NCDatasets.jl/issues/277
        dataset_kwargs = (:aggdim => first(time_dims), :deferopen => false)
    end

    files = length(file_paths) == 1 ? only(file_paths) : file_paths
    time_index, available_dates, coord_names =
        NCDatasets.NCDataset(files; dataset_kwargs...) do ds
            varname in keys(ds) ||
                error("$varname is not available in $file_paths")
            time_dims = findall(is_time, NCDatasets.dimnames(ds[varname]))
            length(time_dims) <= 1 ||
                error("Could not find (unique) time dimension")
            time_index = isempty(time_dims) ? -1 : only(time_dims)
            dates =
                time_index == -1 ? Dates.DateTime[] :
                time_transform.(read_available_dates(ds))
            issorted(dates) || error("Dates are not sorted in $file_paths")
            allunique(dates) || error("Dates are not unique in $file_paths")
            (
                time_index,
                dates,
                _resolve_coord_names(coord_names, ds, file_paths),
            )
        end
    length(file_paths) == 1 || _check_consistent_coords(coord_names, file_paths)

    return DataSource(
        file_paths,
        String(varname),
        available_dates,
        time_index,
        coord_names,
        dataset_kwargs,
    )
end

"""
    _resolve_coord_names(coord_names, ds, file_paths)

Return the given `coord_names` checked against `ds`, or detect them when
`coord_names` is `nothing`.
"""
function _resolve_coord_names(coord_names, ds, file_paths)
    isnothing(coord_names) && return detect_coord_names(ds, file_paths)
    coord_names isa NamedTuple || error(
        "coord_names must be a NamedTuple, e.g. (; lon = \"lon\", lat = \"lat\", z = \"z\")",
    )
    unrecognized = setdiff(keys(coord_names), keys(COORD_NAMES))
    isempty(unrecognized) || error(
        "Unrecognized coordinate types ($(join(unrecognized, ", "))) in coord_names; the recognized coordinate types are $(join(keys(COORD_NAMES), ", "))",
    )
    for (coord_type, name) in pairs(coord_names)
        haskey(ds, name) ||
            error("$name ($coord_type) is not available in $file_paths")
    end
    return map(String, coord_names)
end

"""
    _check_consistent_coords(coord_names, file_paths)

Check that every coordinate variable in `coord_names` holds the same values in
all of `file_paths`.
"""
function _check_consistent_coords(coord_names, file_paths)
    reference = NCDatasets.NCDataset(first(file_paths)) do ds
        map(name -> Array(ds[name]), coord_names)
    end
    for path in file_paths[2:end]
        NCDatasets.NCDataset(path) do ds
            for (coord_type, name) in pairs(coord_names)
                haskey(ds, name) ||
                    error("$name ($coord_type) is not available in $path")
                values = Array(ds[name])
                size(values) == size(reference[coord_type]) &&
                isapprox(values, reference[coord_type]) || error(
                    "$name in $path does not match its values in $(first(file_paths)); files joined along the time dimension must hold the same coordinate values",
                )
            end
        end
    end
    return nothing
end

end
