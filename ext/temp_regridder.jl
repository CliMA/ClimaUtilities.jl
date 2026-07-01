# TEMPORARY: a placeholder regridder for the `MultiColumnDataHandler`.
#
# The real regridder will interpolate each column's profile onto the target
# space's vertical levels (linear interpolation via ClimaInterpolations.jl).
# Until that exists, and since the current test cases have no vertical
# component, "regridding" is just a memcpy: the read data is copied straight
# into a `Field` on the target space.
#
# TODO: replace this whole file with a real column regridder.

struct TempRegridder{SPACE <: ClimaCore.Spaces.AbstractSpace} <:
       Regridders.AbstractRegridder
    """ClimaCore space where the output `Field` is defined."""
    target_space::SPACE
end

"""
    regrid(regridder::TempRegridder, data, dimensions...)

Placeholder regrid: copy `data` into a `Field` on the target space, performing
no interpolation (a memcpy).

Assumes `data` matches the target field's layout size - true when the data has
no vertical component (or its vertical resolution already matches the target
space) and its columns are already in the target space's column order. The
column ordering is guaranteed upstream by `find_file_paths_for_cols`.
"""
function Regridders.regrid(regridder::TempRegridder, data, _dimensions...)
    field = zeros(regridder.target_space)
    ClimaCore.Fields.field2array(field) .= vec(data)
    return field
end
