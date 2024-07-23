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
    GITP,
} <: Regridders.AbstractRegridder

    """ClimaCore.Space where the output Field will be defined"""
    target_space::SPACE

    """ClimaCore.Field of physical coordinates over which the data will be interpolated"""
    coordinates::FIELD

    """Tuple of extrapolation conditions as accepted by Interpolations.jl"""
    extrapolation_bc::BC

    # This is needed because Adapt moves from CPU to GPU and allocates new memory.
    """Dictionary of preallocated areas of memory where to store the GPU interpolant (if
    needed). Every time new data/dimensions are used in regrid, a new entry in the
    dictionary is created. The keys of the dictionary a tuple of tuple
    `(size(dimensions), size(data))`, with `dimensions` and `data` defined in `regrid`.
    """
    _gpuitps::GITP
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
"""
function Regridders.InterpolationsRegridder(
    target_space::ClimaCore.Spaces.AbstractSpace;
    extrapolation_bc::Union{Nothing, Tuple} = nothing,
)
    coordinates = ClimaCore.Fields.coordinate_field(target_space)

    num_dimensions = length(propertynames(coordinates))

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

    num_dimensions == length(extrapolation_bc) || error(
        "Number of boundary conditions does not match the number of dimensions",
    )

    # Let's figure out the type of _gpuitps by creating a simple spline
    FT = ClimaCore.Spaces.undertype(target_space)
    dimensions = ntuple(_ -> [zero(FT), one(FT)], num_dimensions)
    data = zeros(FT, ntuple(_ -> 2, num_dimensions))
    itp = _create_linear_spline(FT, data, dimensions, extrapolation_bc)
    fake_gpuitp = Adapt.adapt(ClimaComms.array_type(target_space), itp)
    gpuitps = Dict((size.(dimensions), size(data)) => fake_gpuitp)

    return InterpolationsRegridder(
        target_space,
        coordinates,
        extrapolation_bc,
        gpuitps,
    )
end

"""
    _create_linear_spline(regridder::InterpolationsRegridder, data, dimensions)

Create a linear spline for the given data on the given dimension (on the CPU).
"""
function _create_linear_spline(FT, data, dimensions, extrapolation_bc)
    dimensions_FT = map(d -> FT.(d), dimensions)

    # Make a linear spline
    return Intp.extrapolate(
        Intp.interpolate(dimensions_FT, FT.(data), Intp.Gridded(Intp.Linear())),
        extrapolation_bc,
    )
end


"""
    regrid(regridder::InterpolationsRegridder, data, dimensions)::Field

Regrid the given data as defined on the given dimensions to the `target_space` in `regridder`.

This function is allocating.
"""
function Regridders.regrid(regridder::InterpolationsRegridder, data, dimensions)
    FT = ClimaCore.Spaces.undertype(regridder.target_space)
    itp =
        _create_linear_spline(FT, data, dimensions, regridder.extrapolation_bc)

    key = (size.(dimensions), size(data))

    if haskey(regridder._gpuitps, key)
        for (k, k_new) in zip(
            regridder._gpuitps[key].itp.knots,
            Adapt.adapt(
                ClimaComms.array_type(regridder.target_space),
                itp.itp.knots,
            ),
        )
            k .= k_new
        end
        regridder._gpuitps[key].itp.coefs .= Adapt.adapt(
            ClimaComms.array_type(regridder.target_space),
            itp.itp.coefs,
        )
    else
        regridder._gpuitps[key] =
            Adapt.adapt(ClimaComms.array_type(regridder.target_space), itp)
    end

    gpuitp = regridder._gpuitps[key]

    return map(regridder.coordinates) do coord
        gpuitp(totuple(coord)...)
    end
end

end
