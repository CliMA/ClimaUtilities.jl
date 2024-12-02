module InterpolationsRegridderExt

import Interpolations as Intp

import ClimaCore
import ClimaCore.Fields: Adapt
import ClimaCore.Fields: ClimaComms

import ClimaUtilities.Regridders

struct InterpolationsRegridder{
    SPACE <: ClimaCore.Spaces.AbstractSpace,
    FIELD <: ClimaCore.Fields.Field,
    BC,
    DT <: Tuple,
} <: Regridders.AbstractRegridder

    """ClimaCore.Space where the output Field will be defined"""
    target_space::SPACE

    """ClimaCore.Field of physical coordinates over which the data will be interpolated"""
    coordinates::FIELD

    """Tuple of extrapolation conditions as accepted by Interpolations.jl"""
    extrapolation_bc::BC

    """Tuple of booleans signifying if the dimension is monotonically increasing. True for
    dimensions that are monotonically increasing, false for dimensions that are monotonically decreasing."""
    dim_increasing::DT
end

# Note, we swap Lat and Long! This is because according to the CF conventions longitude
# should be first, so files will have longitude as first dimension.
totuple(pt::ClimaCore.Geometry.LatLongZPoint) = pt.long, pt.lat, pt.z
totuple(pt::ClimaCore.Geometry.LatLongPoint) = pt.long, pt.lat

"""
    InterpolationsRegridder(target_space::ClimaCore.Spaces.AbstractSpace
                            [; extrapolation_bc::Tuple])

An online regridder that uses Interpolations.jl

Currently, InterpolationsRegridder is only implemented for LatLong and LatLongZ spaces. It
performs linear interpolation along each of the directions (separately). By default, it
imposes periodic boundary conditions for longitude, flat for latitude, and throwing errors
when extrapolating in z. This can be customized by passing the `extrapolation_bc` keyword
argument.

InterpolationsRegridder is GPU and MPI compatible in the simplest possible way: each MPI
process has the entire input data and everything is copied to GPU.

Keyword arguments
=================

The optional keyword argument `extrapolation_bc` controls what should be done when the
interpolation point is not in the domain of definition. This has to be a tuple of N
elements, where N is the number of spatial dimensions. For 3D spaces, the default is
`(Interpolations.Periodic(), Interpolations.Flat(), Interpolations.Throw())`.

The optional keyword argument `dim_increasing` controls which dimensions should
be reversed before performing interpolation. This must be a tuple of N booleans, where
N is the number of spatial dimensions. The default is the `true` for each
spatial dimension.
"""
function Regridders.InterpolationsRegridder(
    target_space::ClimaCore.Spaces.AbstractSpace;
    extrapolation_bc::Union{Nothing, Tuple} = nothing,
    dim_increasing::Union{Nothing, Tuple} = nothing,
)
    coordinates = ClimaCore.Fields.coordinate_field(target_space)
    # set default values for the extrapolation_bc and dim_increasing if they are not provided
    if eltype(coordinates) <: ClimaCore.Geometry.LatLongPoint
        isnothing(extrapolation_bc) &&
            (extrapolation_bc = (Intp.Periodic(), Intp.Flat()))
        isnothing(dim_increasing) && (dim_increasing = (true, true))
    elseif eltype(coordinates) <: ClimaCore.Geometry.LatLongZPoint
        isnothing(extrapolation_bc) &&
            (extrapolation_bc = (Intp.Periodic(), Intp.Flat(), Intp.Throw()))
        isnothing(dim_increasing) && (dim_increasing = (true, true, true))
    else
        error("Only lat-long, lat-long-z spaces are supported")
    end

    return InterpolationsRegridder(
        target_space,
        coordinates,
        extrapolation_bc,
        dim_increasing,
    )
end

"""
    regrid(regridder::InterpolationsRegridder, data, dimensions)::Field

Regrid the given data as defined on the given dimensions to the `target_space` in `regridder`.

This function is allocating.
"""
function Regridders.regrid(regridder::InterpolationsRegridder, data, dimensions)
    FT = ClimaCore.Spaces.undertype(regridder.target_space)
    dimensions_FT = map(dimensions, regridder.dim_increasing) do dim, increasing
        !increasing ? reverse(FT.(dim)) : FT.(dim)
    end

    data_transformed = data
    # Reverse the data if needed. This allocates, so ideally it should be done in preprocessing
    if !all(regridder.dim_increasing)
        decreasing_indices =
            Tuple([i for (i, d) in enumerate(regridder.dim_increasing) if !d])
        data_transformed = reverse(data, dims = decreasing_indices)
    end
    # Make a linear spline
    itp = Intp.extrapolate(
        Intp.interpolate(
            dimensions_FT,
            FT.(data_transformed),
            Intp.Gridded(Intp.Linear()),
        ),
        regridder.extrapolation_bc,
    )

    # Move it to GPU (if needed)
    gpuitp = Adapt.adapt(ClimaComms.array_type(regridder.target_space), itp)

    return map(regridder.coordinates) do coord
        gpuitp(totuple(coord)...)
    end
end

end
