module SpaceVaryingInputsExt

using ClimaCore
using ClimaCore: ClimaComms
import ClimaUtilities.Utils: searchsortednearest, linear_interpolation
import ClimaUtilities.DataHandling: DataHandler, regridded_snapshot

import ClimaUtilities.SpaceVaryingInputs

"""
    SpaceVaryingInput(data_handler::DataHandler)
    SpaceVaryingInput(file_path::AbstractString,
                      varname::AbstractString,
                      target_space::Spaces.AbstractSpace;
                      regridder_type::Symbol)

Returns the parameter field to be used in the model; appropriate when
a parameter is defined on the surface of the Earth.

Returns a ClimaCore.Fields.Field of scalars; analogous to the 1D case which also
returns a ClimaCore.Fields.Field of scalars.
"""
function SpaceVaryingInputs.SpaceVaryingInput(data_handler)
    return regridded_snapshot(data_handler)
end

function SpaceVaryingInputs.SpaceVaryingInput(
    file_path,
    varname,
    target_space;
    regridder_type = :TempestRegridder,
)
    return SpaceVaryingInputs.SpaceVaryingInput(
        DataHandler(file_path, varname, target_space; regridder_type),
    )
end


end
