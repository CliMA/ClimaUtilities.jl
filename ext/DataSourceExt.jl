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
`Dates.DateTime`. `coord_names` names the dimensions of `varname` by type of
coordinate, e.g. `(; lon = "lon", lat = "lat", z = "height")`, each with a
coordinate variable of the same name. When `coord_names` is `nothing`, they are
detected from the dimension names of `varname`. If you are passing a value for
`coord_names`, it must list every coordinate of `varname`.
"""
function FileReaders.DataSource(
    file_paths,
    varname::AbstractString;
    time_transform = identity,
    coord_names = nothing,
)
    file_paths isa AbstractString && (file_paths = [file_paths])
    isempty(file_paths) && error("file_paths must contain at least one path")
    file_paths = abspath.(collect(file_paths))

    dataset_kwargs = ()
    if length(file_paths) > 1
        time_dims = NCDatasets.NCDataset(first(file_paths)) do ds
            filter(in(TIME_NAMES), NCDatasets.dimnames(ds))
        end
        isempty(time_dims) && error(
            "Multiple files given, but no temporal dimension found. Combining multiple files is only possible along the temporal dimension.",
        )
        # Keep the files open, see https://github.com/JuliaGeo/NCDatasets.jl/issues/277
        dataset_kwargs = (:aggdim => first(time_dims), :deferopen => false)
    end

    files = length(file_paths) == 1 ? only(file_paths) : file_paths
    source = NCDatasets.NCDataset(files; dataset_kwargs...) do ds
        varname in keys(ds) || error("$varname is not available in $file_paths")
        time_dims =
            findall(in(TIME_NAMES), NCDatasets.dimnames(ds[varname]))
        length(time_dims) <= 1 ||
            error("Could not find (unique) time dimension")
        time_index = isempty(time_dims) ? -1 : only(time_dims)
        dates =
            time_index == -1 ? Dates.DateTime[] :
            time_transform.(read_available_dates(ds))
        issorted(dates) || error(
            "Dates are not sorted. Check the dates in $file_paths or the time_transform",
        )
        allunique(dates) || error(
            "Dates are not unique. Check the dates in $file_paths or the time_transform",
        )
        DataSource(
            file_paths,
            String(varname),
            dates,
            time_index,
            _resolve_coord_names(coord_names, ds, varname, file_paths),
            dataset_kwargs,
        )
    end
    length(file_paths) == 1 ||
        _check_consistent_coords(source.coord_names, file_paths)
    return source
end

"""
    _resolve_coord_names(coord_names, ds, varname, file_paths)

Return the given `coord_names`, or the ones detected for `varname` when
`coord_names` is `nothing`, checked against `ds`.
"""
function _resolve_coord_names(coord_names, ds, varname, file_paths)
    isnothing(coord_names) &&
        (coord_names = detect_coord_names(ds, varname, file_paths))
    coord_names isa NamedTuple || error(
        "coord_names must be a NamedTuple, e.g. (; lon = \"lon\", lat = \"lat\", z = \"z\")",
    )
    unrecognized = setdiff(keys(coord_names), keys(COORD_NAMES))
    isempty(unrecognized) || error(
        "Unrecognized coordinate types ($(join(unrecognized, ", "))) in coord_names; the recognized coordinate types are $(join(keys(COORD_NAMES), ", "))",
    )
    dims = NCDatasets.dimnames(ds[varname])
    for (coord_type, name) in pairs(coord_names)
        name in dims && haskey(ds, name) || error(
            "$name ($coord_type) is not available as a dimension of $varname with a coordinate variable in $file_paths",
        )
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
