"""
    Regridder

This module contains functions to regrid information between spaces.
Many of the functions used in this module call TempestRemap functions
via ClimaCoreTempestRemap wrappers.
"""
module Regridder

import ClimaCore: Spaces, Fields, InputOutput
import ClimaCoreTempestRemap as CCTR
import ClimaComms
import Dates
import NCDatasets as NCD

export missings_to_zero,
    nans_to_zero,
    clean_data,
    binary_mask,
    dummy_remap!,
    read_from_hdf5,
    write_to_hdf5,
    write_field_to_ncdataset,
    remap_field_cgll_to_rll,
    fill_field!,
    swap_space

"""
    missings_to_zero(x::Vector{FT}) where {FT}

Converts `missing`s in a vector to zeros of the vector's float type.

Note: This function will not work if the input array consists of
entirely `Missing` types.
"""
function missings_to_zero(x::Vector{<:Union{Missing, FT}}) where {FT}
    x[ismissing.(x)] .= FT(0)
    x = Vector{FT}(x)
    return x
end

"""
    nans_to_zero(x::Vector{FT}) where {FT}

Converts `NaN`s in a vector to zeros of the same type.
"""
function nans_to_zero(x::Vector{FT}) where {FT}
    x[isnan.(x)] .= FT(0)
    return x
end

"""
    clean_data(x::Vector{Union{Missing, FT}}) where {FT}

Cleans a vector of data by converting `missing`s and `NaN`s to zeros.

Note: This function will not work if the input array consists of
entirely `Missing` types.
"""
function clean_data(x::Vector{<:Union{Missing, FT}}) where {FT}
    x = missings_to_zero(x)
    x = nans_to_zero(x)
    return x
end

"""
    binary_mask(var::FT; threshold = 0.5)

Returns 1 if `var` is greater or equal than a given
`threshold` value, or 0 otherwise, keeping the same type.

# Arguments
- `var::FT` value to be converted.
- `threshold::FT` cutoff value for conversions.
"""
binary_mask(var::FT; threshold::FT = FT(0.5)) where {FT} =
    var < FT(threshold) ? FT(0) : FT(1)

"""
    dummy_remap!(target, source)

Simple stand-in function for remapping.
For AMIP we don't need regridding of surface model fields.
When we do, we re-introduce the ClimaCoreTempestRemap remapping functions.

# Arguments
- `target::Fields.Field` destination of remapping.
- `source::Fields.Field` source of remapping.
"""
function dummy_remap!(target::Fields.Field, source::Fields.Field)
    parent(target) .= parent(source)
end

"""
    sparse_array_to_field!(field::Fields.Field, TR_in_array::Array, TR_inds::NamedTuple)

Reshapes a sparse vector array `TR_in_array` (CGLL, raw output of the TempestRemap),
and uses its data to populate the input Field object `field`.
The third argument, `TR_inds`, is a NamedTuple containing the indices of the
sparse vector `TR_in_array` using TempestRemap's convention.
Redundant nodes are populated using `dss` operations.

This function is used internally by `hdwrite_regridfile_rll_to_cgll`.

# Arguments
- `field::Fields.Field` object populated with the input array.
- `TR_in_array::Array` input used to fill `field`.
- `TR_inds::NamedTuple` contains `target_idxs` and `row_indices` used for indexing.
"""
# TODO rename keys of TR_inds
function sparse_array_to_field!(
    field::Fields.Field,
    TR_in_array::Array,
    TR_inds::NamedTuple,
)
    field_array = parent(field)

    fill!(field_array, zero(eltype(field_array)))
    Nf = size(field_array, 3)

    for (n, row) in enumerate(TR_inds.row_indices)
        it, jt, et = (
            view(TR_inds.target_idxs[1], n),
            view(TR_inds.target_idxs[2], n),
            view(TR_inds.target_idxs[3], n),
        )
        for f in 1:Nf
            field_array[it, jt, f, et] .= TR_in_array[row]
        end
    end

    # broadcast to the redundant nodes using unweighted dss
    space = axes(field)
    topology = Spaces.topology(space)
    hspace = Spaces.horizontal_space(space)
    target = Fields.field_values(field)

    Spaces.dss!(target, topology, hspace.quadrature_style)
end

"""
    read_from_hdf5(REGIRD_DIR, hd_outfile_root, time, varname,
        comms_ctx = ClimaComms.SingletonCommsContext())

Read in a variable `varname` from an HDF5 file.
If a CommsContext other than SingletonCommsContext is used for `comms_ctx`,
the input HDF5 file must be readable by multiple MPI processes.

# Arguments
- `REGRID_DIR::String` directory to save output files in.
- `hd_outfile_root::String` root of the output file name.
- `time::Dates.DateTime` the timestamp of the data being written.
- `varname::String` variable name of data.
- `comms_ctx::ClimaComms.AbstractCommsContext` context used for this operation.
# Returns
- Field or FieldVector
"""
function read_from_hdf5(
    REGRID_DIR::String,
    hd_outfile_root::String,
    time::Dates.DateTime,
    varname::String,
    comms_ctx::ClimaComms.AbstractCommsContext = ClimaComms.SingletonCommsContext(),
)
    hdfreader = InputOutput.HDF5Reader(
        joinpath(REGRID_DIR, hd_outfile_root * "_" * string(time) * ".hdf5"),
        comms_ctx,
    )

    field = InputOutput.read_field(hdfreader, varname)
    Base.close(hdfreader)
    return field
end

"""
    write_to_hdf5(REGRID_DIR, hd_outfile_root, time, field, varname,
        comms_ctx = ClimaComms.SingletonCommsContext())

Function to save individual HDF5 files after remapping.
If a CommsContext other than SingletonCommsContext is used for `comms_ctx`,
the HDF5 output is readable by multiple MPI processes.

# Arguments
- `REGRID_DIR::String` directory to save output files in.
- `hd_outfile_root::String` root of the output file name.
- `time::Dates.DateTime` the timestamp of the data being written.
- `field::Fields.Field` object to be written.
- `varname::String` variable name of data.
- `comms_ctx::ClimaComms.AbstractCommsContext` context used for this operation.
"""
function write_to_hdf5(
    REGRID_DIR::String,
    hd_outfile_root::String,
    time::Dates.DateTime,
    field::Fields.Field,
    varname::String,
    comms_ctx::ClimaComms.AbstractCommsContext = ClimaComms.SingletonCommsContext(),
)
    t = Dates.datetime2unix.(time)
    hdfwriter = InputOutput.HDF5Writer(
        joinpath(REGRID_DIR, hd_outfile_root * "_" * string(time) * ".hdf5"),
        comms_ctx,
    )

    InputOutput.HDF5.write_attribute(hdfwriter.file, "unix time", t) # TODO: a better way to write metadata, CMIP convention
    InputOutput.write!(hdfwriter, field, string(varname))
    Base.close(hdfwriter)
end

"""
    write_field_to_ncdataset(datafile_out, field, name)

Write the data stored in `field` to an NCDataset file `datafile_out`.

This function is used internally by `remap_field_cgll_to_rll`.

# Arguments
- `datafile_out::String` filename of output file.
- `field::Fields.Field` to be written to file.
- `name::Symbol` variable name.
"""
function write_field_to_ncdataset(
    datafile_out::String,
    field::Fields.Field,
    name::Symbol,
)
    space = axes(field)
    # write data
    NCD.NCDataset(datafile_out, "c") do nc
        CCTR.def_space_coord(nc, space; type = "cgll")
        nc_field = NCD.defVar(nc, name, eltype(field), CCTR.space_dims(space))
        nc_field[:] = field
    end
end

"""
    remap_field_cgll_to_rll(
        name::Symbol,
        field::Fields.Field,
        remap_tmpdir::String,
        datafile_rll::String;
        nlat::Int = 90,
        nlon::Int = 180,
    )

Remap an individual FT-valued Field from model (CGLL) nodes to a lat-lon (RLL)
grid using TempestRemap.

# Arguments
- `name::Symbol`: variable name.
- `field::Fields.Field` data to be remapped.
- `remap_tmpdir::String` directory used for remapping.
- `datafile_rll::String`filename of remapped data output.
- `nlat::Int` number of latitudes in RLL grid.
- `nlon::Int` number of longitudes in RLL grid.
"""
function remap_field_cgll_to_rll(
    name::Symbol,
    field::Fields.Field,
    remap_tmpdir::String,
    datafile_rll::String;
    nlat::Int = 90,
    nlon::Int = 180,
)
    space = axes(field)
    hspace = :topology in propertynames(space) ? space : space.horizontal_space
    Nq = Spaces.Quadratures.polynomial_degree(hspace.quadrature_style) + 1

    # write out our cubed sphere mesh
    meshfile_cc = remap_tmpdir * "/mesh_cubedsphere.g"
    CCTR.write_exodus(meshfile_cc, hspace.topology)

    meshfile_rll = remap_tmpdir * "/mesh_rll.g"
    CCTR.rll_mesh(meshfile_rll; nlat = nlat, nlon = nlon)

    meshfile_overlap = remap_tmpdir * "/mesh_overlap.g"
    CCTR.overlap_mesh(meshfile_overlap, meshfile_cc, meshfile_rll)

    weightfile = remap_tmpdir * "/remap_weights.nc"
    CCTR.remap_weights(
        weightfile,
        meshfile_cc,
        meshfile_rll,
        meshfile_overlap;
        in_type = "cgll",
        in_np = Nq,
    )

    datafile_cc = remap_tmpdir * "/datafile_cc.nc"
    write_field_to_ncdataset(datafile_cc, field, name)

    CCTR.apply_remap( # TODO: this can be done online
        datafile_rll,
        datafile_cc,
        weightfile,
        [string(name)],
    )
end

"""
    fill_field!(field_out::Fields.Field, field_in::Fields.Field)

Fill the values of a `field_out` with those of `field_in`.

# Arguments
- `field_out::Fields.Field` object to be filled with values.
- `field_in::Fields.Field` contains values to fill other field with.
"""
function fill_field!(field_out::Fields.Field, field_in::Fields.Field)
    parent(field_out) .= parent(field_in)
    return field_out
end

"""
    swap_space(field_in::Fields.Field, new_space::Spaces.AbstractSpace)

Remap the values of a field onto a new space, and return a new field.

# Arguments
- `field::Fields.Field` object containing values used to populate new field.
- `new_space::Spaces.AbstractSpace` space to remap `field_in` onto.
"""
function swap_space(field::Fields.Field, new_space::Spaces.AbstractSpace)
    field_out = zeros(new_space)
    parent(field_out) .= parent(field)
    return field_out
end
end # module Regridder
