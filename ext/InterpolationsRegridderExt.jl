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
} <: Regridders.AbstractRegridder

    """ClimaCore.Space where the output Field will be defined"""
    target_space::SPACE

    """ClimaCore.Field of physical coordinates over which the data will be interpolated"""
    coordinates::FIELD

    """Tuple of extrapolation conditions as accepted by Interpolations.jl"""
    extrapolation_bc::BC
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

    return InterpolationsRegridder(target_space, coordinates, extrapolation_bc)
end

"""
    regrid(regridder::InterpolationsRegridder, data, dimensions)::Field

Regrid the given data as defined on the given dimensions to the `target_space` in `regridder`.

This function is allocating.
"""
function Regridders.regrid(regridder::InterpolationsRegridder, data, dimensions)
    # TODO: There is room for improvement in this function...

    FT = ClimaCore.Spaces.undertype(regridder.target_space)
    dimensions_FT = map(d -> FT.(d), dimensions)

    coordinates = ClimaCore.Fields.coordinate_field(regridder.target_space)
    device = ClimaComms.device(regridder.target_space)

    has_3d_z = length(size(last(dimensions))) == 3
    if eltype(coordinates) <: ClimaCore.Geometry.LatLongZPoint && has_3d_z
        # If we have 3D altitudes, we do linear in the vertical and bilinear
        # horizontal separately
        @warn "Ignoring boundary conditions, implementing Periodic, Flat, Flat"

        adapted_data = Adapt.adapt(ClimaComms.array_type(regridder.target_space), data)
        xs, ys, zs = dimensions_FT
        adapted_xs = Adapt.adapt(ClimaComms.array_type(regridder.target_space), xs)
        adapted_ys = Adapt.adapt(ClimaComms.array_type(regridder.target_space), ys)
        adapted_zs = Adapt.adapt(ClimaComms.array_type(regridder.target_space), zs)

        return ClimaComms.allowscalar(ClimaComms.device(regridder.target_space)) do
            map(regridder.coordinates) do coord
                interpolation_3d_z(
                    adapted_data,
                    adapted_xs, adapted_ys, adapted_zs,
                    totuple(coord)...,
                )
            end
        end
    else
        # Make a linear spline
        itp = Intp.extrapolate(
            Intp.interpolate(
                dimensions_FT,
                FT.(data),
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

"""
    interpolation_3d_z(data, xs, ys, zs, target_x, target_y, target_z)

Perform bilinear + vertical interpolation on a 3D dataset.

This function first performs linear interpolation along the z-axis at the four
corners of the cell containing the target (x, y) point. Then, it performs
bilinear interpolation in the x-y plane using the z-interpolated values.

Periodic is implemented on the x direction, Flat on the other ones.

# Arguments
- `data`: A 3D array of data values.
- `xs`: A vector of x-coordinates corresponding to the first dimension of `data`.
- `ys`: A vector of y-coordinates corresponding to the second dimension of `data`.
- `zs`: A 3D array of z-coordinates. `zs[i, j, :]` provides the z-coordinates for the data point `data[i, j, :]`.
- `target_x`: The x-coordinate of the target point.
- `target_y`: The y-coordinate of the target point.
- `target_z`: The z-coordinate of the target point.
"""
function interpolation_3d_z(data, xs, ys, zs, target_x, target_y, target_z)
    # Check boundaries
    # if target_x < xs[begin] || target_x > xs[end]
    #     error(
    #         "target_x is out of bounds: $(target_x) not in [$(xs[1]), $(xs[end])]",
    #     )
    # end
    # if target_y < ys[begin] || target_y > ys[end]
    #     error(
    #         "target_y is out of bounds: $(target_y) not in [$(ys[1]), $(ys[end])]",
    #     )
    # end

    # Find nearest neighbors
    x_period = xs[end] - xs[begin]
    target_x = mod(target_x, x_period)

    x_index = searchsortedfirst(xs, target_x)
    y_index = searchsortedfirst(ys, target_y)

    x0_index = x_index == 1 ? x_index : x_index - 1
    x1_index = x0_index + 1

    y0_index = y_index == 1 ? y_index : y_index - 1
    # Flat
    y0_index = clamp(y0_index, 1, length(ys) - 1)
    y1_index = y0_index + 1
    if y0_index == 1
        target_y = ys[y0_index]
    end
    if y1_index == length(ys)
        target_y = ys[y1_index]
    end


    # Interpolate in z-direction

    z00 = @view zs[x0_index, y0_index, :]
    z01 = @view zs[x0_index, y1_index, :]
    z10 = @view zs[x1_index, y0_index, :]
    z11 = @view zs[x1_index, y1_index, :]

    f00 = linear_interp_z(view(data,x0_index, y0_index, :), z00, target_z)
    f01 = linear_interp_z(view(data,x0_index, y1_index, :), z01, target_z)
    f10 = linear_interp_z(view(data,x1_index, y0_index, :), z10, target_z)
    f11 = linear_interp_z(view(data,x1_index, y1_index, :), z11, target_z)

    # Bilinear interpolation in x-y plane
    val = bilinear_interp(
        f00,
        f01,
        f10,
        f11,
        xs[x0_index],
        xs[x1_index],
        ys[y0_index],
        ys[y1_index],
        target_x,
        target_y,
    )

    return val
end

"""
    linear_interp_z(f, z, target_z)

Perform linear interpolation along the z-axis.

# Arguments
- `f`: A vector of function values corresponding to the z-coordinates in `z`.
- `z`: A vector of z-coordinates.
- `target_z`: The z-coordinate at which to interpolate.

# Returns
The linearly interpolated value at `target_z`.
"""
function linear_interp_z(f, z, target_z)
    # if target_z < z[begin] || target_z > z[end]
    #     error(
    #         "target_z is out of bounds: $(target_z) not in [$(z[1]), $(z[end])]",
    #     )
    # end

    index = searchsortedfirst(z, target_z)
    # Handle edge cases for index
    # Flat
    if index == 1
        z0 = z[index]
        z1 = z[index + 1]
        f0 = f[index]
        f1 = f[index + 1]
    else
        z0 = z[index - 1]
        z1 = z[index]
        f0 = f[index - 1]
        f1 = f[index]
    end

    if index == 1
        target_z = z[index]
    end
    if index == length(z) - 1
        target_z = z[index + 1]
    end
    val = f0 + (target_z - z0) / (z1 - z0) * (f1 - f0)
    return val
end

"""
    bilinear_interp(f00, f01, f10, f11, x0, x1, y0, y1, target_x, target_y)

Perform bilinear interpolation on a 2D plane.

# Arguments
- `f00`: Function value at (x0, y0).
- `f01`: Function value at (x0, y1).
- `f10`: Function value at (x1, y0).
- `f11`: Function value at (x1, y1).
- `x0`: x-coordinate of the first corner.
- `x1`: x-coordinate of the second corner.
- `y0`: y-coordinate of the first corner.
- `y1`: y-coordinate of the second corner.
- `target_x`: The x-coordinate of the target point.
- `target_y`: The y-coordinate of the target point.
"""
function bilinear_interp(f00, f01, f10, f11, x0, x1, y0, y1, target_x, target_y)
    val = (
        (x1 - target_x) * (y1 - target_y) / ((x1 - x0) * (y1 - y0)) * f00 +
        (x1 - target_x) * (target_y - y0) / ((x1 - x0) * (y1 - y0)) * f01 +
        (target_x - x0) * (y1 - target_y) / ((x1 - x0) * (y1 - y0)) * f10 +
        (target_x - x0) * (target_y - y0) / ((x1 - x0) * (y1 - y0)) * f11
    )
    return val
end

end
