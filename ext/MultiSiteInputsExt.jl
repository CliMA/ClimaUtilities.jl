module MultiSiteInputsExt

import Dates
import NCDatasets

import ClimaCore

import ClimaUtilities.Utils: interpolate_columns!
import ClimaUtilities.FileReaders: DataSource
import ClimaUtilities.SpaceVaryingInputs
import ClimaUtilities.TimeVaryingInputs
import ClimaUtilities.TimeVaryingInputs:
    AbstractInterpolationMethod, LinearInterpolation

include("column_spaces.jl")

"""
    TimeVaryingInput(
        sources::AbstractVector{<:AbstractVector{<:DataSource}},
        space;
        start_date,
        compose_function,
        method,
        preprocess_func
    )
    TimeVaryingInput(sources::AbstractVector{<:DataSource}, space; kwargs...)
    TimeVaryingInput(source::DataSource, space; kwargs...)

Construct a time varying input that gives every column of `space` the time
series of its own site, read from the NetCDF variables described by
`DataSource`s.

`sources` has one vector per file variable, and each vector has one source per
column of `space`, in the order of the columns of
`ClimaCore.Fields.field2array`. A single vector is shorthand for one variable,
and a single source is read for every column. For example, two variables of a
space with one column are passed as `[[ta], [hus]]`, since `[ta, hus]` is one
variable on two columns. With more than one variable,
`compose_function` is required: it receives the values of each variable of a
column as an array with one row per level and one column per time, and returns
the values of the input. `preprocess_func` is applied to every value before
that.

Each source is a time-varying variable of one site: one value per time for a
space with a single level, or one value per time and level otherwise, on a
vertical coordinate in metres. Levels are interpolated linearly onto the levels
of `space` and held constant above and below the file's levels. The variables of
one column must share their dates and levels. Dates are counted from
`start_date`, and `method` sets the interpolation in time. Columns whose sources
compare equal share one time series in memory.

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
        end
        reads = [_read_block(source, preprocess_func) for source in col]
        (; dates, z_src) = first(reads)
        all(r -> r.dates == dates && isequal(r.z_src, z_src), reads) ||
            error(
                "The variables of one column must share their dates and vertical coordinate: $(join(("$(s.varname) in $(s.file_paths)" for s in col), ", "))",
            )
        block = compose_function((r.block for r in reads)...)

        # Preprocess the data by regridding to the dest z
        (dates, _regrid_block(block, z_src, model_z, first(col)))
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

Heights of the levels of one column of `space`, or `nothing` when `space` has a
single level.
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
        z_name = get(source.coord_names, :z, nothing)
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
    _regrid_block(block, z_src, model_z, source)

Interpolate `block`, given on the levels `z_src`, onto the levels `model_z`, or
return it as is when both are `nothing`.
"""
function _regrid_block(block, z_src, model_z, source)
    if isnothing(z_src)
        isnothing(model_z) || error(
            "$(source.varname) in $(source.file_paths) has no vertical coordinate, but the space has levels",
        )
        return block
    end
    isnothing(model_z) && error(
        "$(source.varname) in $(source.file_paths) has a vertical coordinate, but the space has no levels",
    )
    out = Matrix{eltype(model_z)}(undef, length(model_z), size(block, 2))
    return interpolate_columns!(out, model_z, z_src, block)
end

"""
    SpaceVaryingInput(
        sources::AbstractVector{<:DataSource},
        space;
        preprocess_func = identity
    )
    SpaceVaryingInput(source::DataSource, space; kwargs...)

Return a `Field` on `space` holding in each column the static variable of the
corresponding source, one per column, or of `source` in every column. Each
source is given on the levels of a vertical coordinate in metres, which are
interpolated linearly onto the levels of `space` and held constant beyond them,
or is a single value for a space with a single level. `preprocess_func` is
applied to every value read.
"""
function SpaceVaryingInputs.SpaceVaryingInput(
    sources::AbstractVector{<:DataSource},
    space::ColumnSpace;
    preprocess_func = identity,
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
        source.time_index == -1 || error(
            "$(source.varname) in $(source.file_paths) has a time dimension; use TimeVaryingInput for time-varying data",
        )
        (; block, z_src) = _read_block(source, preprocess_func)
        block = _regrid_block(block, z_src, model_z, source)
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
