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
    DT,
} <: Regridders.AbstractRegridder

    """ClimaCore.Space where the output Field will be defined"""
    target_space::SPACE

    """ClimaCore.Field of physical coordinates over which the data will be interpolated"""
    coordinates::FIELD

    """Tuple of extrapolation conditions as accepted by Interpolations.jl"""
    extrapolation_bc::BC

    """Tuple of functions applied to each spatial dimension before interpolation"""
    dim_transforms::DT
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

The optional keyword argument `dim_transforms` controls what transformations should be
done to the data before performing interpolation. This must be a tuple of N functions, where
N is the number of spatial dimensions. The default is the identity function for each
spatial dimension.
"""
function Regridders.InterpolationsRegridder(
    target_space::ClimaCore.Spaces.AbstractSpace;
    extrapolation_bc::Union{Nothing, Tuple} = nothing,
    dim_transforms::Union{Nothing, Tuple} = nothing,
)
    coordinates = ClimaCore.Fields.coordinate_field(target_space)

    if isnothing(extrapolation_bc)
        extrapolation_bc = ()
        if eltype(coordinates) <: ClimaCore.Geometry.LatLongPoint
            extrapolation_bc = (Intp.Periodic(), Intp.Flat())
        elseif eltype(coordinates) <: ClimaCore.Geometry.LatLongZPoint
            extrapolation_bc = (Intp.Periodic(), Intp.Flat(), Intp.Throw())
        else
            error("Only lat-long, lat-long-z spaces are supported")
        end
    end

    if isnothing(dim_transforms)
        if eltype(coordinates) <: ClimaCore.Geometry.LatLongPoint
            dim_transforms = (identity, identity)
        elseif eltype(coordinates) <: ClimaCore.Geometry.LatLongZPoint
            dim_transforms = (identity, identity, identity)
        end
    end

    return InterpolationsRegridder(
        target_space,
        coordinates,
        extrapolation_bc,
        dim_transforms,
    )
end

"""
    regrid(regridder::InterpolationsRegridder, data, dimensions)::Field

Regrid the given data as defined on the given dimensions to the `target_space` in `regridder`.

This function is allocating.
"""
function Regridders.regrid(regridder::InterpolationsRegridder, data, dimensions)
    FT = ClimaCore.Spaces.undertype(regridder.target_space)
    dimensions_FT = map(dimensions, regridder.dim_transforms) do dim, transform
        FT.(transform(dim))
    end
    # apply the specified transformation to each dimension of the data
    if length(dimensions) == 2
        for i in 1:length(dimensions_FT[1])
            data[i, :] .= regridder.dim_transforms[2](data[i, :])
        end
        for i in 1:length(dimensions_FT[2])
            data[:, i] .= regridder.dim_transforms[1](data[:, i])
        end
    elseif length(dimensions) == 3
        for i in 1:length(dimensions_FT[1])
            for j in 1:length(dimensions_FT[2])
                data[i, j, :] .= regridder.dim_transforms[3](data[i, j, :])
            end
        end
        for i in 1:length(dimensions_FT[1])
            for j in 1:length(dimensions_FT[3])
                data[i, :, j] .= regridder.dim_transforms[2](data[i, :, j])
            end
        end
        for i in 1:length(dimensions_FT[2])
            for j in 1:length(dimensions_FT[3])
                data[:, i, j] .= regridder.dim_transforms[1](data[:, i, j])
            end
        end
    else
        error("Only 2D and 3D data is supported")
    end
    # Make a linear spline
    itp = Intp.extrapolate(
        Intp.interpolate(dimensions_FT, FT.(data), Intp.Gridded(Intp.Linear())),
        regridder.extrapolation_bc,
    )

    # Move it to GPU (if needed)
    gpuitp = Adapt.adapt(ClimaComms.array_type(regridder.target_space), itp)

    return map(regridder.coordinates) do coord
        gpuitp(totuple(coord)...)
    end
end

end
