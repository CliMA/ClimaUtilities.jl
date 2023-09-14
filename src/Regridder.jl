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

export missings_to_zero!,
    nans_to_zero!, clean_data!, read_from_hdf5, write_to_hdf5

"""
    missings_to_zero!(x::Vector{FT}) where {FT}

Converts `missing`s in a vector to zeros of the vector's float type.
"""
function missings_to_zero!(x::Vector{Union{Missing, FT}}) where {FT}
    x[ismissing.(x)] .= FT(0)
end

"""
    nans_to_zero!(x::Vector{FT}) where {FT}

Converts `NaN`s in a vector to zeros of the same type.
"""
function nans_to_zero!(x::Vector{FT}) where {FT}
    @show isnan.(x)
    @show x[isnan.(x)]
    x[isnan.(x)] .= FT(0)
end

"""
    clean_data!(x::Vector{Union{Missing, FT}}) where {FT}

Cleans a vector of data by converting `missing`s and `NaN`s to zeros.
"""
function clean_data!(x::Vector{Union{Missing, FT}}) where {FT}
    missings_to_zero!(x)
    @show x
    nans_to_zero!(x)
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
    write_field_to_ncdataset(datafile_out, field, name)

Write the data stored in `field` to an NCDataset file `datafile_out`.

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
    NCDataset(datafile_out, "c") do nc
        def_space_coord(nc, space; type = "cgll")
        nc_field = defVar(nc, name, Float64, space)
        nc_field[:, 1] = field

        nothing
    end
end

end # module Regridder
