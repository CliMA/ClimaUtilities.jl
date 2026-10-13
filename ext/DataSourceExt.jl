module DataSourceExt

import Dates
import NCDatasets

import ClimaUtilities.FileReaders
import ClimaUtilities.FileReaders: DataSource
import ..NCFileReaderExt: TIME_NAMES, read_available_dates, detect_z_name

# Possible units for pressure, in lowercase
const PRESSURE_UNITS = (
    "pa",
    "pascal",
    "pascals",
    "hpa",
    "hectopascal",
    "hectopascals",
    "kpa",
    "bar",
    "bars",
    "mbar",
    "millibar",
    "millibars",
    "mb",
    "dbar",
    "decibar",
    "decibars",
    "atm",
    "atmosphere",
    "atmospheres",
)

# Possible units for meters, in lowercase
const METER_UNITS = ("m", "meter", "meters", "metre", "metres")

"""
    DataSource(file_paths, varname; time_transform = identity, z_name = nothing)

Describe the variable `varname` in the NetCDF file `file_paths`, or in several
files joined along its time dimension when a collection of paths is given, in
chronological order and with the same vertical levels in every file.

`time_transform` is applied to each date of the time axis and must return a
`Dates.DateTime`. `z_name` is the name of the vertical dimension of `varname`,
which must have a coordinate variable of the same name. When `z_name` is
`nothing`, it is detected from the dimension names of `varname`. The units of
the vertical coordinate should be in meters. If its units are a unit of
pressure, an error is thrown.
"""
function FileReaders.DataSource(
    file_paths,
    varname::AbstractString;
    time_transform = identity,
    z_name::Union{Nothing, AbstractString} = nothing,
)
    file_paths isa AbstractString && (file_paths = [file_paths])
    isempty(file_paths) && error("file_paths must contain at least one path")
    file_paths = abspath.(collect(file_paths))

    dataset_kwargs = ()
    if length(file_paths) > 1
        aggdim = NCDatasets.NCDataset(first(file_paths)) do ds
            _time_name(ds, varname, file_paths)
        end
        isnothing(aggdim) && error(
            "Multiple files given, but no temporal dimension found. Combining multiple files is only possible along the temporal dimension.",
        )
        # Keep the files open, see https://github.com/JuliaGeo/NCDatasets.jl/issues/277
        dataset_kwargs = (:aggdim => aggdim, :deferopen => false)
    end

    files = length(file_paths) == 1 ? only(file_paths) : file_paths
    source = NCDatasets.NCDataset(files; dataset_kwargs...) do ds
        time_name = _time_name(ds, varname, file_paths)
        time_index =
            isnothing(time_name) ? -1 :
            findfirst(==(time_name), NCDatasets.dimnames(ds[varname]))
        dates =
            isnothing(time_name) ? Dates.DateTime[] :
            time_transform.(read_available_dates(ds, time_name))
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
            _resolve_z_name(ds, z_name, varname, file_paths),
            dataset_kwargs,
        )
    end
    length(file_paths) == 1 ||
        isnothing(source.z_name) ||
        _check_consistent_z(source.z_name, file_paths)
    return source
end

"""
    _time_name(ds, varname, file_paths)

Return the name of the time dimension of `varname` in `ds`, or `nothing` when it
has none.
"""
function _time_name(ds, varname, file_paths)
    varname in keys(ds) || error("$varname is not available in $file_paths")
    time_names = filter(in(TIME_NAMES), NCDatasets.dimnames(ds[varname]))
    length(time_names) <= 1 || error(
        "Could not find (unique) time dimension: $varname in $file_paths has the time dimensions $(join(time_names, ", "))",
    )
    return isempty(time_names) ? nothing : only(time_names)
end

"""
    _resolve_z_name(ds, z_name, varname, file_paths)

Return the given `z_name`, or the one detected for `varname` when `z_name` is
`nothing`, checked against `ds`.
"""
function _resolve_z_name(ds, z_name, varname, file_paths)
    isnothing(z_name) && (z_name = detect_z_name(ds, varname, file_paths))
    isnothing(z_name) && return nothing
    z_name in NCDatasets.dimnames(ds[varname]) && haskey(ds, z_name) || error(
        "$z_name is not available as a dimension of $varname with a coordinate variable in $file_paths",
    )
    _check_z_units(ds, z_name, file_paths)
    return String(z_name)
end

"""
    _check_z_units(ds, z_name, file_paths)

Check that the units of the vertical dimension are in meters. Throw an error
if its units are of pressure and warn when they are missing or other than
meters.
"""
function _check_z_units(ds, z_name, file_paths)
    attrib = ds[z_name].attrib
    if !haskey(attrib, "units")
        @warn "$z_name in $file_paths has no units, but is used as heights in meters"
        return nothing
    end
    units = attrib["units"]
    normalized_units = lowercase(strip(units))
    normalized_units in PRESSURE_UNITS && error(
        "$z_name in $file_paths has units of pressure ($units), but only heights in meters are supported",
    )
    normalized_units in METER_UNITS ||
        @warn "$z_name in $file_paths has units $units, but is used as heights in meters"
    return nothing
end

"""
    _check_consistent_z(z_name, file_paths)

Check that the coordinate variable `z_name` holds the same values in all of
`file_paths`.
"""
function _check_consistent_z(z_name, file_paths)
    reference = NCDatasets.NCDataset(first(file_paths)) do ds
        Array(ds[z_name])
    end
    for path in file_paths[2:end]
        NCDatasets.NCDataset(path) do ds
            haskey(ds, z_name) || error("$z_name is not available in $path")
            values = Array(ds[z_name])
            size(values) == size(reference) && isapprox(values, reference) ||
                error(
                    "$z_name in $path does not match its values in $(first(file_paths)); files joined along the time dimension must hold the same vertical levels",
                )
        end
    end
    return nothing
end

end
