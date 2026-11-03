module MultiSiteInputsExt

import Dates
import NCDatasets

import ClimaCore

import ClimaUtilities.FileReaders: DataSource
import ClimaUtilities.SpaceVaryingInputs
import ClimaUtilities.TimeVaryingInputs
import ClimaUtilities.TimeVaryingInputs:
    AbstractInterpolationMethod, LinearInterpolation, Throw, Flat, Linear

include("column_spaces.jl")

"""
    TimeVaryingInput(
        sources::AbstractVector{<:AbstractVector{<:DataSource}},
        space;
        start_date,
        compose_function = identity,
        method = LinearInterpolation(),
        preprocess_func = identity,
        vertical_extrapolation_bc = TimeVaryingInputs.Flat()
    )
    TimeVaryingInput(sources::AbstractVector{<:DataSource}, space; kwargs...)
    TimeVaryingInput(source::DataSource, space; kwargs...)

Construct a time varying input that gives every column of `space` the time
series of its own site, read from the NetCDF variables described by
`DataSource`s. `space` is a point, column, multi-point or multi-column space.

`sources` has one vector per file variable, and each vector has one source per
column of `space`, in the order of the columns of
`ClimaCore.Fields.field2array`. A single vector is shorthand for one variable,
and a single source is read for every column. For example, two variables of a
space with one column are passed as `[[ta], [hus]]`, since `[ta, hus]` is one
variable on two columns. With more than one variable, `compose_function` is
required: it receives the values of each variable of a column as an array with
one row per level of the file and one column per time, and returns the values of
the input. Use broadcasting in `compose_function`, e.g. `ta .* hus`, since
`ta * hus` is a matrix product. `preprocess_func` is applied to every value
before that. Unlike for 2D and 3D files, it is passed directly rather than
through `file_reader_kwargs`.

Each source is a time-varying variable of one site: one value per time for a
space with a single level, or one value per time and level otherwise, on a
vertical coordinate in meters. Levels are interpolated linearly onto the levels
of `space`. Above and below the file's levels, `vertical_extrapolation_bc`
holds the values of the closest level with `TimeVaryingInputs.Flat()`, the
default, extends the line through the two closest levels with
`TimeVaryingInputs.Linear()`, or errors with `TimeVaryingInputs.Throw()`. The
variables of one column must share their dates and levels. Columns whose sources
compare equal share one time series in memory.

`start_date` is required: it is the date at which the simulation time is zero.
`method` sets the interpolation in time. The default, `LinearInterpolation()`,
errors at times outside the dates of a column.
`LinearPeriodFillingInterpolation` and `PeriodicCalendar(period, date)` are not
supported.

# Examples

If we want to use the same air temperature for all columns, we can do

```julia
input = TimeVaryingInput(
    DataSource("site_a.nc", "ta"),
    space;
    start_date = DateTime(2010, 7, 1),
)
```

If we want site specific air temperature for two columns, we can do

```julia
sources = [DataSource("site_a.nc", "ta"), DataSource("site_b.nc", "ta")]
input = TimeVaryingInput(sources, space; start_date = DateTime(2010, 7, 1))
```

If we want to compute virtual temperature of three columns from temperature and
humidity, with the first and the third column reading the same site:

```julia
files = ["site_a.nc", "site_b.nc", "site_a.nc"]
ta = [DataSource(f, "ta") for f in files]
hus = [DataSource(f, "hus") for f in files]
input = TimeVaryingInput(
    [ta, hus],
    space;
    start_date = DateTime(2010, 7, 1),
    compose_function = (ta, hus) -> ta .* (1 .+ 0.61 .* hus),
)
```
"""
function TimeVaryingInputs.TimeVaryingInput(
    sources::AbstractVector{<:AbstractVector{<:DataSource}},
    space::ColumnSpace;
    start_date::Union{Dates.DateTime, Dates.Date},
    compose_function = identity,
    method::AbstractInterpolationMethod = LinearInterpolation(),
    preprocess_func = identity,
    vertical_extrapolation_bc::Union{Throw, Flat, Linear} = Flat(),
)
    num_columns =
        space isa ClimaCore.Spaces.PointSpace ? 1 :
        ClimaCore.Spaces.ncolumns(space)
    all(==(num_columns), length.(sources)) || error(
        "Every variable needs one source per column, but there are $(join(length.(sources), ", ")) sources for a space with $num_columns columns",
    )
    length(sources) == 1 ||
        compose_function != identity ||
        error(
            "compose_function is required to combine $(length(sources)) variables",
        )
    # The sources of each column, one per variable
    per_column = collect(zip(sources...))
    # If the same time series data is used for multiple columns, reuse the data
    # instead of duplicating it
    unique_columns = unique(per_column)
    column_segment = Int.(indexin(per_column, unique_columns))
    model_z = _model_levels(space)

    segments = map(unique_columns) do col
        for source in col
            source.time_index == -1 && error(
                "$(source.varname) in $(source.file_paths) has no time dimension; use SpaceVaryingInput for static data",
            )
            length(source.available_dates) >= 2 || error(
                "$(source.varname) in $(source.file_paths) has one date, but at least two times are needed; use SpaceVaryingInput for static data",
            )
        end
        reads = [_read_block(source, preprocess_func) for source in col]
        (; dates, z_src) = first(reads)
        all(r -> r.dates == dates && isequal(r.z_src, z_src), reads) ||
            error(
                "The variables of one column must share their dates and vertical coordinate: $(join(("$(s.varname) in $(s.file_paths)" for s in col), ", "))",
            )
        block = compose_function((r.block for r in reads)...)

        # Preprocess the data by regridding to the dest z
        block = _regrid_block(
            block,
            z_src,
            model_z,
            first(col),
            vertical_extrapolation_bc,
        )
        (dates, block)
    end
    # This calls the constructor for RaggedInterpolatingTimeVaryingInput
    return TimeVaryingInputs.TimeVaryingInput(
        first.(segments),
        last.(segments),
        space;
        column_segment,
        method,
        epoch = start_date,
    )
end

TimeVaryingInputs.TimeVaryingInput(
    sources::AbstractVector{<:DataSource},
    space::ColumnSpace;
    kwargs...,
) = TimeVaryingInputs.TimeVaryingInput([sources], space; kwargs...)

function TimeVaryingInputs.TimeVaryingInput(
    source::DataSource,
    space::ColumnSpace;
    kwargs...,
)
    num_columns =
        space isa ClimaCore.Spaces.PointSpace ? 1 :
        ClimaCore.Spaces.ncolumns(space)
    # Use the same sites for all columns
    sources = fill(source, num_columns)
    return TimeVaryingInputs.TimeVaryingInput(sources, space; kwargs...)
end

"""
    _model_levels(space)

Heights of the levels of one column of `space`, or `nothing` when the columns of
`space` are points.
"""
_model_levels(::Union{ClimaCore.Spaces.PointSpace, MultiPointSpace}) = nothing
# Every column shares the vertical grid
function _model_levels(space)
    z = ClimaCore.Fields.coordinate_field(space).z
    return Array(ClimaCore.Fields.field2array(z))[:, 1]
end

"""
    _read_block(source::DataSource, preprocess_func)

Read the variable of `source` as `(; dates, block, z_src)`, where `block` has
one row per level of the vertical coordinate `z_src`, or a single row when there
is none and `z_src` is `nothing`, and one column per date, or a single column
for a static variable.
"""
function _read_block(source::DataSource, preprocess_func)
    files =
        length(source.file_paths) == 1 ? only(source.file_paths) :
        source.file_paths
    return NCDatasets.NCDataset(files; source.dataset_kwargs...) do ds
        var = ds[source.varname]
        dims = NCDatasets.dimnames(var)
        z_name = source.z_name
        z_index = findfirst(==(z_name), dims)
        others = filter(!in((z_index, source.time_index)), eachindex(dims))
        all(i -> size(var, i) == 1, others) || error(
            "$(source.varname) in $(source.file_paths) has dimensions $dims, but only time and the vertical coordinate may have more than one entry",
        )
        data = map(preprocess_func, Array(var))
        any(ismissing, data) && error(
            "Missing values in $(source.varname) of $(source.file_paths); handle them in preprocess_func",
        )
        # Vertical coordinate first and time last; the other dimensions have
        # length one
        order = filter(!in((z_index, source.time_index)), 1:ndims(data))
        isnothing(z_index) || pushfirst!(order, z_index)
        source.time_index == -1 || push!(order, source.time_index)
        num_levels = isnothing(z_index) ? 1 : size(data, z_index)
        data = NCDatasets.nomissing(data)
        # On Julia 1.10, permutedims errors for 0-dimensional arrays
        issorted(order) || (data = permutedims(data, order))
        block = reshape(data, num_levels, :)
        z_src = nothing
        if !isnothing(z_index)
            z_src = NCDatasets.nomissing(Array(ds[z_name]))
            # Heights that vary in time are stored like the data, levels first
            first(NCDatasets.dimnames(ds[z_name])) == z_name ||
                (z_src = permutedims(z_src))
        end
        (; dates = source.available_dates, block, z_src)
    end
end

"""
    _regrid_block(block, z_src, model_z, source, extrapolation_bc)

Interpolate `block`, given on the levels `z_src`, onto the levels `model_z`,
using `extrapolation_bc` outside of `z_src`, or return it as is when there is no
`z_src` and the space has a single level.
"""
function _regrid_block(block, z_src, model_z, source, extrapolation_bc)
    if isnothing(z_src)
        isnothing(model_z) ||
            length(model_z) == 1 ||
            error(
                "$(source.varname) in $(source.file_paths) has no vertical coordinate, but the space has levels",
            )
        return block
    end
    isnothing(model_z) && error(
        "$(source.varname) in $(source.file_paths) has a vertical coordinate, but the space has no levels",
    )
    all(isfinite, z_src) || error(
        "The levels of $(source.varname) in $(source.file_paths) are not all finite",
    )
    is_monotonic(zs) = issorted(zs; lt = <=) || issorted(zs; lt = >=)
    all(is_monotonic, eachcol(z_src)) || error(
        "The levels of $(source.varname) in $(source.file_paths) are not strictly monotonic",
    )
    out = Matrix{eltype(model_z)}(undef, length(model_z), size(block, 2))
    return interpolate_columns!(out, model_z, z_src, block, extrapolation_bc)
end

"""
    interpolate_columns!(dest, z_target, z_src, data, extrapolation_bc = Flat())

Interpolate each column of `data`, given at the levels `z_src`, onto the levels
`z_target` and write the result to `dest`. `z_src` is a vector shared by every
column or a matrix with one column per column of `data`, each finite and
strictly increasing or strictly decreasing.

Outside the source levels, `extrapolation_bc` is `Flat()` to use the closest
value in the column, `Linear()` to extend the line through the two closest
values in the column, or `Throw()` to error.
"""
function interpolate_columns!(
    dest,
    z_target,
    z_src,
    data,
    extrapolation_bc = Flat(),
)
    size(z_src, 1) >= 2 || error("At least two source levels are needed")
    size(z_src, 1) == size(data, 1) ||
        error("z_src and data have different numbers of levels")
    z_src isa AbstractVector ||
        size(z_src, 2) == size(data, 2) ||
        error("z_src and data have different numbers of columns")
    size(dest) == (length(z_target), size(data, 2)) ||
        error("dest must have size (length(z_target), size(data, 2))")
    for c in axes(data, 2)
        zs = z_src isa AbstractVector ? z_src : view(z_src, :, c)
        ys = view(data, :, c)
        all(isfinite, zs) ||
            error("The source levels of column $c are not all finite")
        if !issorted(zs; lt = <=)
            issorted(zs; lt = >=) || error(
                "The source levels of column $c are not strictly monotonic",
            )
            zs, ys = reverse(zs), reverse(ys)
        end
        for (k, z) in enumerate(z_target)
            i1, i2, w = _level_stencil(z, zs, extrapolation_bc)
            dest[k, c] = ys[i1] + (ys[i2] - ys[i1]) * w
        end
    end
    return dest
end

"""
    _level_stencil(z, zs, extrapolation_bc)

Return the stencil `(i1, i2, w)` for the level `z` on the increasing levels
`zs`, using `extrapolation_bc` outside the range of `zs`. The value at `z` is
`ys[i1] + (ys[i2] - ys[i1]) * w`, where `ys` are the values at `zs`.
"""
@inline function _level_stencil(z, zs, extrapolation_bc)
    FT = float(promote_type(typeof(z), eltype(zs)))
    i1, i2, w =
        zs[begin] <= z <= zs[end] ? _interior_level_stencil(z, zs) :
        _boundary_level_stencil(z, zs, extrapolation_bc)
    return (i1, i2, FT(w))
end

"""
    _interior_level_stencil(z, zs)

Return the stencil for the level `z` within the range of `zs`.

A `z` that falls exactly on a level of `zs` returns that level with zero weight.
"""
function _interior_level_stencil(z, zs)
    i = searchsortedfirst(zs, z)
    # Also avoids indexing before the first level when z == zs[begin]
    zs[i] == z && return (i, i, 0)
    return (i - 1, i, (z - zs[i - 1]) / (zs[i] - zs[i - 1]))
end

"""
    _boundary_level_stencil(z, zs, extrapolation_bc)

Return the stencil for the level `z` outside the range of `zs` given the
`extrapolation_bc`.
"""
function _boundary_level_stencil(z, zs, ::Throw)
    return error(
        "The source levels from $(zs[begin]) to $(zs[end]) do not cover the level $z",
    )
end

function _boundary_level_stencil(z, zs, ::Flat)
    i = z < zs[begin] ? firstindex(zs) : lastindex(zs)
    return (i, i, 0)
end

function _boundary_level_stencil(z, zs, ::Linear)
    i = z < zs[begin] ? firstindex(zs) : lastindex(zs) - 1
    return (i, i + 1, (z - zs[i]) / (zs[i + 1] - zs[i]))
end

"""
    SpaceVaryingInput(
        sources::AbstractVector{<:DataSource},
        space;
        preprocess_func = identity,
        vertical_extrapolation_bc = TimeVaryingInputs.Flat()
    )
    SpaceVaryingInput(source::DataSource, space; kwargs...)

Return a `Field` on `space` holding in each column the static variable of the
corresponding source, one per column, or of `source` in every column.

Each source is given on the levels of a vertical coordinate in meters, which are
interpolated linearly onto the levels of `space`, or is a single value for a
space with a single level. A variable with a time dimension of a single date is
read as static. `preprocess_func` is applied to every value read.

Above and below the levels of a source, `vertical_extrapolation_bc` holds the
values of the closest level with `TimeVaryingInputs.Flat()`, the default,
extends the line through the two closest levels with
`TimeVaryingInputs.Linear()`, or errors with `TimeVaryingInputs.Throw()`.
"""
function SpaceVaryingInputs.SpaceVaryingInput(
    sources::AbstractVector{<:DataSource},
    space::ColumnSpace;
    preprocess_func = identity,
    vertical_extrapolation_bc::Union{Throw, Flat, Linear} = Flat(),
)
    field = ClimaCore.Fields.zeros(space)
    arr = ClimaCore.Fields.field2array(field)
    num_columns = ndims(arr) == 1 ? length(arr) : size(arr, 2)
    length(sources) == num_columns || error(
        "$(length(sources)) sources for a space with $num_columns columns",
    )
    model_z = _model_levels(space)
    unique_sources = unique(sources)
    columns = map(unique_sources) do source
        length(source.available_dates) <= 1 || error(
            "$(source.varname) in $(source.file_paths) has a time dimension with $(length(source.available_dates)) dates; use TimeVaryingInput for time-varying data",
        )
        (; block, z_src) = _read_block(source, preprocess_func)
        block = _regrid_block(
            block,
            z_src,
            model_z,
            source,
            vertical_extrapolation_bc,
        )
        vec(block)
    end
    copyto!(arr, stack(columns[indexin(sources, unique_sources)]))
    return field
end

function SpaceVaryingInputs.SpaceVaryingInput(
    source::DataSource,
    space::ColumnSpace;
    kwargs...,
)
    num_columns =
        space isa ClimaCore.Spaces.PointSpace ? 1 :
        ClimaCore.Spaces.ncolumns(space)
    sources = fill(source, num_columns)
    return SpaceVaryingInputs.SpaceVaryingInput(sources, space; kwargs...)
end

end
