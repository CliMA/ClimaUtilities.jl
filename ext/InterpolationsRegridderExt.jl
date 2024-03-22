module InterpolationsRegridderExt

import Interpolations as Intp

import ClimaCore
import ClimaCore.Fields: Adapt
import ClimaCore.Fields: ClimaComms

import ClimaUtilities.Regridders

"""
    InterpolationsRegridder

An online regridder that uses Interpolations.jl

InterpolationsRegridder is only implemented for LatLong and LatLongZ spaces. It performs
linear interpolation along each of the directions (separately), while imposing periodic
boundary conditions for longitude, flat for latitude, and throwing errors when extrapolating
in z.

InterpolationsRegridder is GPU and MPI compatible in the simplest possible way. Each MPI
process has the entire input data and everything is copied to GPU.
"""
struct InterpolationsRegridder{
    SPACE <: ClimaCore.Spaces.AbstractSpace,
    FIELD <: ClimaCore.Fields.Field,
    BC,
} <: Regridders.AbstractRegridder
    target_space::SPACE
    coordinates::FIELD
    extrapolation_bc::BC
end

# Note, we swap Lat and Long! This is because according to the CF conventions longitude
# should be first, so files will have longitude as first dimension.
totuple(pt::ClimaCore.Geometry.LatLongZPoint) = pt.long, pt.lat, pt.z
totuple(pt::ClimaCore.Geometry.LatLongPoint) = pt.long, pt.lat

function Regridders.InterpolationsRegridder(
    target_space::ClimaCore.Spaces.AbstractSpace,
)
    coordinates = ClimaCore.Fields.coordinate_field(target_space)

    extrapolation_bc = ()
    if eltype(coordinates) <: ClimaCore.Geometry.LatLongPoint
        extrapolation_bc = (Intp.Periodic(), Intp.Flat())
    elseif eltype(coordinates) <: ClimaCore.Geometry.LatLongZPoint
        extrapolation_bc = (Intp.Periodic(), Intp.Flat(), Intp.Throw())
    else
        error("Only lat-long, lat-long-z spaces are supported")
    end

    return InterpolationsRegridder(target_space, coordinates, extrapolation_bc)
end

"""
    regrid(regridder::InterpolationsRegridder, data, dimensions)::Field

Regrid the given data as defined on the given dimensions to the `target_space` in `regridder`.

This function is allocating.
"""
function Regridders.regrid(regridder::InterpolationsRegridder, data, dimensions)
    FT = ClimaCore.Spaces.undertype(regridder.target_space)
    dimensions_FT = map(d -> FT.(d), dimensions)

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
