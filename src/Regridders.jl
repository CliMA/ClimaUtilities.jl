"""
    Regridders

The `Regridders` module implement structs and functions to remap datasets to simulation
grids.

Currently, the schemes implemented are `TempestRegridder`, which uses
`ClimaCoreTempestRemap`, and `InterpolationsRegridder`, which uses `Interpolations.jl`.

The key function exposed by `Regridder` is the `regrid` method.
"""
module Regridders

# When adding a new regridder, you also have to change some functions in the DataHandler
# module. Find where :TempestRegridder is used.
abstract type AbstractRegridder end

function TempestRegridder end

function InterpolationsRegridder end

function regrid end

end
