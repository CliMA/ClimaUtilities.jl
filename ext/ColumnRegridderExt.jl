module ColumnRegridderExt

import ClimaInterpolations

import ClimaCore
import ClimaComms

import ClimaUtilities.Regridders

"""
    ColumnRegridder

A regridder that interpolates data on each column's vertical levels onto the
vertical levels of `target_space`, using `ClimaInterpolations.jl`. If there are
no vertical levels, then no vertical interpolation is done.

Unlike `InterpolationsRegridder`, this does no horizontal interpolation. The
columns are assumed to already be aligned with the target space's columns.
"""
struct ColumnRegridder{
    SPACE <: ClimaCore.Spaces.AbstractSpace,
    OR,
    EX,
    SRC <: AbstractArray,
    TARGET <: AbstractArray,
    SCR <: Union{AbstractArray, Nothing},
} <: Regridders.AbstractRegridder
    """ClimaCore space to interpolate onto."""
    target_space::SPACE

    """Interpolation order (e.g.
    `ClimaInterpolations.Interpolation1D.Linear()`)."""
    order::OR

    """Extrapolation condition (e.g.
    `ClimaInterpolations.Interpolation1D.Flat()`)."""
    extrapolate::EX

    """Source vertical levels whose size is `n_source_levels` x `n_columns`.
    Empty when there is no vertical dimension."""
    src_vertical_levels::SRC

    """Vertical levels of the target space. Empty when there is no vertical
    dimension."""
    target_vertical_levels::TARGET

    """Whether the data passed to `regrid` must be reversed along the vertical
    dimension to match the direction of `src_vertical_levels`."""
    flip_data::Bool

    """Whether the target vertical levels are stored in increasing
    order."""
    is_target_vertical_levels_increasing::Bool

    """Scratch space used in `regrid`."""
    scratch_data::SCR
end

"""
    _check_strictly_monotonic(levels, src_or_target::String)

Check that each column of `levels` is strictly increasing or strictly
decreasing, with the same direction for every column, and return whether the
levels are increasing.

Repeated levels are not allowed, as they break the vertical interpolation. The
argument `src_or_target` (e.g. "source" or "target") is used in the error
messages.
"""
function _check_strictly_monotonic(levels, src_or_target::String)
    # Move to CPU since issorted can sometimes use scalar indexing
    levels = Array(levels)
    is_increasing = true
    for (i, c) in enumerate(axes(levels, 2))
        col = view(levels, :, c)
        col_increasing = issorted(col; lt = <=)
        col_decreasing = issorted(col; rev = true, lt = <=)
        col_increasing ||
            col_decreasing ||
            error(
                "The $src_or_target vertical levels of column $c are neither strictly increasing nor strictly decreasing",
            )
        if isone(i)
            is_increasing = col_increasing
        elseif is_increasing != col_increasing
            error(
                "The $src_or_target vertical levels have inconsistent directions across columns (some increasing, some decreasing)",
            )
        end
    end
    return is_increasing
end

"""
    ColumnRegridder(target_space::ClimaCore.Spaces.AbstractSpace,
                    src_vertical_levels = nothing;
                    order = ClimaInterpolations.Interpolation1D.Linear(),
                    extrapolate = ClimaInterpolations.Interpolation1D.Flat())

Create a `ColumnRegridder` that interpolates data on the source vertical levels
onto the vertical levels of `target_space`.

The levels of each column in `src_vertical_levels` must be strictly increasing
or strictly decreasing, with the same direction for every column. If `nothing`
or an empty array is passed to `src_vertical_levels`, then a regridder that
copies per-column values without vertical interpolation (e.g. for surface data)
is used.

Keyword arguments
=================

- `order`: the `ClimaInterpolations` interpolation order (e.g.
  `ClimaInterpolations.Interpolation1D.Linear()`).
- `extrapolate`: the `ClimaInterpolations` extrapolation conditions (e.g.
  `ClimaInterpolations.Interpolation1D.Flat()`).
"""
function Regridders.ColumnRegridder(
    target_space::Union{
        ClimaCore.Spaces.FiniteDifferenceSpace,
        ClimaCore.Spaces.MultiColumnFiniteDifferenceSpace,
        ClimaCore.Spaces.PointSpace,
        ClimaCore.Spaces.PointCloudSpace,
    },
    src_vertical_levels = nothing;
    order = ClimaInterpolations.Interpolation1D.Linear(),
    extrapolate = ClimaInterpolations.Interpolation1D.Flat(),
)
    FT = ClimaCore.Spaces.undertype(target_space)
    AT = ClimaComms.array_type(target_space)

    if isnothing(src_vertical_levels) || isempty(src_vertical_levels)
        empty_levels = Matrix{FT}(undef, 0, 0)
        return ColumnRegridder(
            target_space,
            order,
            extrapolate,
            empty_levels,
            empty_levels,
            false,
            true,
            nothing,
        )
    end

    target_space isa Union{
        ClimaCore.Spaces.FiniteDifferenceSpace,
        ClimaCore.Spaces.MultiColumnFiniteDifferenceSpace,
    } || error(
        "Cannot regrid onto the target space: $(nameof(typeof(target_space)))",
    )

    # FT.(...) materializes the lazy array returned by field2array into a
    # dense array, which interpolate1d! needs to dispatch to its GPU kernel
    target_vertical_levels = FT.(
        ClimaCore.Fields.field2array(
            ClimaCore.Fields.coordinate_field(target_space).z,
        )
    )

    num_src_cols = size(src_vertical_levels, 2)
    num_target_cols = size(target_vertical_levels, 2)
    num_src_cols == num_target_cols || error(
        "The source vertical levels have $num_src_cols columns, but the target space has $num_target_cols columns",
    )

    # Check the vertical levels are strictly increasing or decreasing
    is_target_increasing =
        _check_strictly_monotonic(target_vertical_levels, "target")
    is_src_increasing = _check_strictly_monotonic(src_vertical_levels, "source")

    # Store the source levels in the same vertical direction as the
    # target levels
    # ClimaInterpolations expect either the source and target vertical
    # levels to be strictly increasing or decreasing
    flip_data = is_src_increasing != is_target_increasing
    src_vertical_levels = FT.(src_vertical_levels)
    flip_data && reverse!(src_vertical_levels, dims = 1)

    src_vertical_levels = AT(src_vertical_levels)
    return ColumnRegridder(
        target_space,
        order,
        extrapolate,
        src_vertical_levels,
        target_vertical_levels,
        flip_data,
        is_target_increasing,
        similar(src_vertical_levels),
    )
end

"""
    regrid(regridder::ColumnRegridder, data)

Interpolate `data` on the regridder's source vertical levels onto the
vertical levels of `regridder.target_space`, returning a
`ClimaCore.Fields.Field`.

The argument `data` is an array with size `n_source_levels` x `n_columns`.

If there is no vertical dimension, the per-column values are copied into the
field without interpolation.
"""
function Regridders.regrid(regridder::ColumnRegridder, data)
    AT = ClimaComms.array_type(regridder.target_space)

    field = zeros(regridder.target_space)
    target_array = ClimaCore.Fields.field2array(field)

    # This can happen with surface data (e.g. LAI data in ClimaLand)
    if isempty(regridder.src_vertical_levels)
        copyto!(target_array, vec(data))
        return field
    end

    size(data) == size(regridder.src_vertical_levels) || error(
        "The size of the data $(size(data)) does not match the size of the source vertical levels $(size(regridder.src_vertical_levels))",
    )

    # `interpolate1d!` requires all arrays to share the same element type
    copyto!(regridder.scratch_data, data)
    regridder.flip_data && reverse!(regridder.scratch_data, dims = 1)

    ClimaInterpolations.Interpolation1D.interpolate1d!(
        target_array,
        regridder.src_vertical_levels,
        regridder.target_vertical_levels,
        regridder.scratch_data,
        regridder.order,
        regridder.extrapolate;
        reverse = !regridder.is_target_vertical_levels_increasing,
    )
    return field
end

end
