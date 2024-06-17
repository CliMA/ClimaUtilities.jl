"""
    Regridders

The `Regridders` module implement structs and functions to remap datasets to simulation
grids.

Currently, the schemes implemented are `TempestRegridder`, which uses
`ClimaCoreTempestRemap`, and `InterpolationsRegridder`, which uses `Interpolations.jl`.

The key function exposed by `Regridders` is the `regrid` method.
"""
module Regridders

import ..ClimaUtilities

# When adding a new regridder, you also have to change some functions in the DataHandler
# module. Find where :TempestRegridder is used.
abstract type AbstractRegridder end

function TempestRegridder end

function InterpolationsRegridder end

function regrid end

"""
    default_regridder_type()

Return the type of regridder to be used if the user doesn't specify one.
This function returns the first available regridder in the following order:
  - InterpolationsRegridder
  - TempestRegridder
based on which regridder(s) are currently loaded.
"""
function default_regridder_type()
    # Use InterpolationsRegridder if available
    if !isnothing(
        Base.get_extension(
            ClimaUtilities,
            :ClimaUtilitiesClimaCoreInterpolationsExt,
        ),
    )
        regridder_type = :InterpolationsRegridder
        # If InterpolationsRegridder isn't available, and TempestRegridder is, use TempestRegridder
    elseif !isnothing(
        Base.get_extension(
            ClimaUtilities,
            :ClimaUtilitiesClimaCoreTempestRemapExt,
        ),
    )
        regridder_type = :TempestRegridder
    else
        error("No regridder available")
    end
    return regridder_type
end

end
