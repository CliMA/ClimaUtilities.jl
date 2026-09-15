module MultiSiteInputsExt

import Dates
import NCDatasets

import ClimaCore

import ClimaUtilities.Utils: interpolate_columns!
import ClimaUtilities.FileReaders: DataSource
import ClimaUtilities.TimeVaryingInputs
import ClimaUtilities.TimeVaryingInputs:
    AbstractInterpolationMethod, LinearInterpolation

const PRESSURE_UNITS = ("Pa", "hPa", "mb", "mbar", "millibar", "bar")

"""
    TimeVaryingInput(sources::AbstractVector{<:DataSource}, space; start_date, method, preprocess_func, max_bytes)

Construct an input with one time series per column of `space` from `sources`,
one per column. Each source is a time-varying variable of one site, given on the
levels of a vertical coordinate in metres, which are interpolated linearly onto
the levels of `space` and held constant beyond them, or without levels for a
space with a single level. Columns whose sources are equal share one time
series.

`preprocess_func` is applied to every value read, the dates of each source are
counted from `start_date`, and `max_bytes` bounds the memory of the values,
erroring before anything is read.
"""
function TimeVaryingInputs.TimeVaryingInput(
    sources::AbstractVector{<:DataSource},
    space::ClimaCore.Spaces.AbstractSpace;
    start_date::Union{Dates.DateTime, Dates.Date},
    method::AbstractInterpolationMethod = LinearInterpolation(),
    preprocess_func = identity,
    max_bytes = nothing,
)
    unique_sources = unique(sources)
    column_segment = [findfirst(==(s), unique_sources) for s in sources]
    model_z = _model_levels(space)

    num_levels = isnothing(model_z) ? 1 : length(model_z)
    bytes =
        sizeof(ClimaCore.Spaces.undertype(space)) *
        num_levels *
        sum(s -> length(s.available_dates), unique_sources)
    @debug "TimeVaryingInput from $(length(unique_sources)) sources needs $bytes bytes"
    isnothing(max_bytes) ||
        bytes <= max_bytes ||
        error("The values need $bytes bytes, more than max_bytes = $max_bytes")

    segments = map(unique_sources) do source
        dates, block, z_src = _read_block(source, preprocess_func)
        isnothing(z_src) ||
            (block = _regrid_block(block, z_src, model_z, source))
        (dates, block)
    end
    return TimeVaryingInputs.TimeVaryingInput(
        first.(segments),
        last.(segments),
        space;
        column_segment,
        method,
        epoch = start_date,
    )
end

"""
    _model_levels(space)

Heights of the levels of one column of `space`, or `nothing` when `space` has a
single level.
"""
function _model_levels(space)
    coords = ClimaCore.Fields.coordinate_field(space)
    :z in propertynames(coords) || return nothing
    z = Array(ClimaCore.Fields.field2array(coords.z))
    return ndims(z) == 1 ? nothing : z[:, 1]
end

"""
    _read_block(source::DataSource, preprocess_func)

Read the variable of `source` as `(dates, block, z_src)`, where `block` has one
column per date and one row per level of the vertical coordinate `z_src`, or a
single row when there is none and `z_src` is `nothing`.
"""
function _read_block(source::DataSource, preprocess_func)
    source.time_index == -1 && error(
        "$(source.varname) in $(source.file_paths) has no time dimension; use SpaceVaryingInput for static data",
    )
    files =
        length(source.file_paths) == 1 ? only(source.file_paths) :
        source.file_paths
    return NCDatasets.NCDataset(files; source.dataset_kwargs...) do ds
        var = ds[source.varname]
        dims = NCDatasets.dimnames(var)
        z_name = get(source.coord_names, :z, nothing)
        z_index = findfirst(==(z_name), dims)
        for i in eachindex(dims)
            i == source.time_index ||
                i == z_index ||
                size(var, i) == 1 ||
                error(
                    "$(source.varname) in $(source.file_paths) has dimensions $dims, but only time and the vertical coordinate may have more than one entry",
                )
        end
        data = preprocess_func.(Array(var))
        any(ismissing, data) && error(
            "Missing values in $(source.varname) of $(source.file_paths); handle them in preprocess_func",
        )
        # Vertical coordinate first and time last; the other dimensions have
        # length one
        order = filter(!=(source.time_index), 1:ndims(data))
        isnothing(z_index) || (order = [z_index; filter(!=(z_index), order)])
        block = reshape(
            permutedims(NCDatasets.nomissing(data), [order; source.time_index]),
            :,
            size(data, source.time_index),
        )
        z_src = isnothing(z_index) ? nothing : _heights(ds[z_name], source)
        (source.available_dates, block, z_src)
    end
end

"""
    _heights(zvar, source)

Return the values of the vertical coordinate `zvar` of `source`, checking that
they are not pressures.
"""
function _heights(zvar, source)
    units = get(zvar.attrib, "units", "m")
    units in PRESSURE_UNITS && error(
        "The vertical coordinate of $(source.varname) in $(source.file_paths) is in $units; heights in metres are required",
    )
    return NCDatasets.nomissing(Array(zvar))
end

"""
    _regrid_block(block, z_src, model_z, source)

Interpolate `block`, given on the levels `z_src`, onto the levels `model_z`.
"""
function _regrid_block(block, z_src, model_z, source)
    isnothing(model_z) && error(
        "$(source.varname) in $(source.file_paths) has a vertical coordinate, but the space has no levels",
    )
    out = Matrix{eltype(model_z)}(undef, length(model_z), size(block, 2))
    return interpolate_columns!(out, model_z, z_src, block)
end

end
