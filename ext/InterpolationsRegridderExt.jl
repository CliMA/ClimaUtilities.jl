module InterpolationsRegridderExt

import Interpolations as Intp

import ClimaCore
import ClimaCore.Fields: Adapt
import ClimaCore.Fields: ClimaComms

import ClimaUtilities.Regridders

import ClimaUtilities.Utils: isequispaced

struct InterpolationsRegridder{
    SPACE <: ClimaCore.Spaces.AbstractSpace,
    FIELD <: ClimaCore.Fields.Field,
    IM,
    BC,
    DT <: Tuple,
    DN <: Union{Nothing, Tuple},
} <: Regridders.AbstractRegridder

    """ClimaCore.Space where the output Field will be defined"""
    target_space::SPACE

    """ClimaCore.Field of physical coordinates over which the data will be interpolated"""
    coordinates::FIELD

    """Method of gridded interpolation as accepted by Interpolations.jl"""
    interpolation_method::IM

    """Tuple of extrapolation conditions as accepted by Interpolations.jl"""
    extrapolation_bc::BC

    """Tuple of booleans signifying if the dimension is monotonically increasing. True for
    dimensions that are monotonically increasing, false for dimensions that are monotonically decreasing."""
    dim_increasing::DT

    """Tuple of dimension names (e.g., ("lon", "lat", "z")) from the input data. Nothing if not provided."""
    dim_names::DN
end

# Note, we swap Lat and Long! This is because according to the CF conventions longitude
# should be first, so files will have longitude as first dimension.
totuple(pt::ClimaCore.Geometry.LatLongZPoint) = pt.long, pt.lat, pt.z
totuple(pt::ClimaCore.Geometry.LatLongPoint) = pt.long, pt.lat
totuple(pt::ClimaCore.Geometry.XYZPoint) = pt.x, pt.y, pt.z
totuple(pt::ClimaCore.Geometry.ZPoint) = pt.z

"""
    InterpolationsRegridder(target_space::ClimaCore.Spaces.AbstractSpace
                            [; extrapolation_bc::Tuple,
                               dim_increasing::Union{Nothing, Tuple},
                               interpolation_method = Interpolations.Linear()])

An online regridder that uses Interpolations.jl

Currently, InterpolationsRegridder is implemented for LatLong, LatLongZ, XYZ, and Z spaces. It
performs linear interpolation along each of the directions (separately). By default, it
imposes periodic boundary conditions for longitude, flat for latitude, and throwing errors
when extrapolating in z. For Z spaces, it throws errors when extrapolating. This can be 
customized by passing the `extrapolation_bc` keyword argument.

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

The optional keyword argument `dim_names` provides dimension names for the input data
(e.g., ("lon", "lat", "z")). When provided with `dim_increasing`, they must be in the same
order: `dim_increasing[i]` applies to `dim_names[i]` and the i-th dimension. This is
particularly important for Z-only spaces where vertical dimensions need to be identified
by name.

!!! note "Centers of cells heuristic for longitude dimension"
    For the longitude dimension, the points along the dimension can either
    represent the centers of cells or the edges of cells.
    `InterpolationsRegridder` automatically detects whether the points represent
    the centers of cells or the edges of cells by checking if the dimension is
    equispaced and spans all 360 degrees. When this condition is met and a
    periodic boundary condition is used, then the points are treated as the
    centers of cells.
"""
function Regridders.InterpolationsRegridder(
    target_space::ClimaCore.Spaces.AbstractSpace;
    extrapolation_bc::Union{Nothing, Tuple} = nothing,
    dim_increasing::Union{Nothing, Tuple} = nothing,
    dim_names::Union{Nothing, Tuple} = nothing,
    interpolation_method = Intp.Linear(),
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
    elseif eltype(coordinates) <: ClimaCore.Geometry.XYZPoint
        isnothing(extrapolation_bc) &&
            (extrapolation_bc = (Intp.Flat(), Intp.Flat(), Intp.Throw()))
        isnothing(dim_increasing) && (dim_increasing = (true, true, true))
    elseif eltype(coordinates) <: ClimaCore.Geometry.ZPoint
        isnothing(extrapolation_bc) && (extrapolation_bc = (Intp.Throw(),))
        isnothing(dim_increasing) && (dim_increasing = (true,))
    else
        error("Only lat-long, lat-long-z, x-y-z, and z spaces are supported")
    end

    return InterpolationsRegridder(
        target_space,
        coordinates,
        interpolation_method,
        extrapolation_bc,
        dim_increasing,
        dim_names,
    )
end

"""
    find_lon_idx(field::ClimaCore.Fields.Field)

Return the index of longitude dimension in the interpolation given the
coordinate field of the space.
"""
find_lon_idx(field::ClimaCore.Fields.Field) = find_lon_idx(eltype(field))
find_lon_idx(::Type{T}) where {T <: ClimaCore.Geometry.LatLongPoint} = 1
find_lon_idx(::Type{T}) where {T <: ClimaCore.Geometry.LatLongZPoint} = 1
find_lon_idx(::Type{T}) where {T <: ClimaCore.Geometry.XYZPoint} = nothing
find_lon_idx(::Type{T}) where {T <: ClimaCore.Geometry.ZPoint} = nothing

"""
    regrid(regridder::InterpolationsRegridder, data, dimensions)::Field

Regrid the given data as defined on the given dimensions to the `target_space` in `regridder`.

This function is allocating.
"""
function Regridders.regrid(regridder::InterpolationsRegridder, data, dimensions)
    FT = ClimaCore.Spaces.undertype(regridder.target_space)

    # For a 2D space with LatLongZ coordinates, we need to drop the z dimension to regrid 2D data.
    if eltype(regridder.coordinates) <: ClimaCore.Geometry.LatLongZPoint &&
       !(
           regridder.target_space isa
           ClimaCore.Spaces.ExtrudedFiniteDifferenceSpace
       ) &&
       length(dimensions) == 2

        coords = map(regridder.coordinates) do coord
            ClimaCore.Geometry.LatLongPoint(coord.lat, coord.long)
        end
    else
        coords = regridder.coordinates
    end

    # For a Z-only space with 3D input data, extract the vertical column at the center
    if eltype(coords) <: ClimaCore.Geometry.ZPoint && length(dimensions) == 3
        # Find the vertical dimension index
        if !isnothing(regridder.dim_names)
            # Use dimension names to identify the vertical dimension
            z_names = ("z", "lev", "level", "plev", "height", "altitude")
            z_idx = findfirst(name -> name in z_names, regridder.dim_names)
            if isnothing(z_idx)
                error(
                    "Could not identify vertical dimension in $(regridder.dim_names). Expected one of: $z_names",
                )
            end
            # Get horizontal dimension indices (all dimensions except vertical)
            horiz_indices = [i for i in 1:3 if i != z_idx]
            # Extract center point of horizontal domain
            h1_idx = round(Int, length(dimensions[horiz_indices[1]]) / 2 + 0.5)
            h2_idx = round(Int, length(dimensions[horiz_indices[2]]) / 2 + 0.5)
            # Extract data based on dimension order
            if z_idx == 1
                data = data[:, h1_idx, h2_idx]
            elseif z_idx == 2
                data = data[h1_idx, :, h2_idx]
            else  # z_idx == 3
                data = data[h1_idx, h2_idx, :]
            end
            dimensions = (dimensions[z_idx],)
        else
            @warn """dim_names not provided to InterpolationsRegridder for \
                Z-only space with 3D input data. Assuming dimensions are ordered \
                 as (lon, lat, z). To avoid this assumption and potential incorrect \
                 results, provide dim_names when creating the regridder."""

            # Fallback: assume dimensions are (lon, lat, z)
            h1_idx = round(Int, length(dimensions[1]) / 2 + 0.5)
            h2_idx = round(Int, length(dimensions[2]) / 2 + 0.5)
            data = data[h1_idx, h2_idx, :]
            dimensions = (dimensions[3],)
        end
    end

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

    # This is a hack to determine if the points should be treated as centers of
    # cells or edges of cells by seeing if the longitude dimension covers 360
    # degrees and is equispaced
    lon_dim_idx = find_lon_idx(coords)
    lon_oncell =
        if !isnothing(lon_dim_idx) && lon_dim_idx <= length(dimensions_FT)
            dim = dimensions_FT[lon_dim_idx]
            extp_bc = regridder.extrapolation_bc[lon_dim_idx]

            extp_bc == Intp.Periodic() &&
                length(dim) > 1 &&
                begin
                    d_dim = dim[2] - dim[1]
                    span_all_360_degrees =
                        last(dim) - first(dim) + d_dim ≈ 360.0
                    span_all_360_degrees && isequispaced(dim)
                end
        else
            false
        end

    # If needed, add virtual points at the end of the longitude dimension
    if lon_oncell
        data_transformed = _append_first_slice(data_transformed, lon_dim_idx)
        lon = dimensions_FT[lon_dim_idx]
        dlon = lon[2] - lon[1]
        push!(lon, last(lon) + dlon)
    end

    # Make a spline
    itp = Intp.extrapolate(
        Intp.interpolate(
            dimensions_FT,
            FT.(data_transformed),
            Intp.Gridded(regridder.interpolation_method),
        ),
        regridder.extrapolation_bc,
    )

    # Move it to GPU (if needed)
    gpuitp = Adapt.adapt(ClimaComms.array_type(regridder.target_space), itp)

    return map(coords) do coord
        gpuitp(totuple(coord)...)
    end
end

"""
    _append_first_slice(data, dim_idx::Int)

Append the first slice along the `dim_idx`th dimension to the end of the
`dim_idx`th dimension of `data`.
"""
function _append_first_slice(data, dim_idx::Int)
    slice_indices = ntuple(i -> i == dim_idx ? [1] : Colon(), ndims(data))
    first_lon_slice = view(data, slice_indices...)
    return cat(data, first_lon_slice, dims = dim_idx)
end

"""
     Regridders.regrid!(output, regridder::InterpolationsRegridder, data::AbstractArray{FT, N}, dimensions::NTuple{N, AbstractVector{FT}})

Regrid the given data as defined on the given dimensions to the `target_space` in `regridder`, and store the result in `output`.
This method does not automatically reverse dimensions, so the dimensions must be sorted before calling this method.
"""
function Regridders.regrid!(
    output,
    regridder::InterpolationsRegridder,
    data::AbstractArray{FT, N},
    dimensions::NTuple{N, AbstractVector{FT}},
) where {FT, N}
    all(regridder.dim_increasing) || error(
        "Dimensions must be monotonically increasing to use regrid!. Sort the dimensions first, or use regrid.",
    )

    # This is a hack to determine if the points should be treated as centers of
    # cells or edges of cells by seeing if the longitude dimension covers 360
    # degrees and is equispaced
    lon_dim_idx = find_lon_idx(regridder.coordinates)
    lon_oncell = if !isnothing(lon_dim_idx) && lon_dim_idx <= length(dimensions)
        dim = dimensions[lon_dim_idx]
        extp_bc = regridder.extrapolation_bc[lon_dim_idx]

        extp_bc == Intp.Periodic() &&
            length(dim) > 1 &&
            begin
                d_dim = dim[2] - dim[1]
                span_all_360_degrees =
                    last(dim) - first(dim) + d_dim ≈ 360.0
                span_all_360_degrees && isequispaced(dim)
            end
    else
        false
    end

    # If needed, add virtual points at the end of the longitude dimension
    if lon_oncell
        data = _append_first_slice(data, lon_dim_idx)
        dimensions = deepcopy(dimensions)
        lon = dimensions[lon_dim_idx]
        dlon = lon[2] - lon[1]
        push!(lon, last(lon) + dlon)
    end

    itp = Intp.extrapolate(
        Intp.interpolate(
            dimensions,
            data,
            Intp.Gridded(regridder.interpolation_method),
        ),
        regridder.extrapolation_bc,
    )
    gpuitp = Adapt.adapt(ClimaComms.array_type(regridder.target_space), itp)
    output .= splat(gpuitp).(totuple.(regridder.coordinates))
    return nothing
end

end
