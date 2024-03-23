# Regridders

Simulations often need to import external data directly onto the computational
grid. The `Regridders` module implements different schemes to accomplish this
goal.

Currently, `Regridders` comes with two implementations:
1. `TempestRegridder` uses
   [TempestRemap](https://github.com/ClimateGlobalChange/tempestremap) (through
   `ClimaCoreTempestRemap`) to perform conservative interpolation onto lat-long
   grids. `TempestRegridder` only works for single-threaded CPU runs and works
   directly with files.
2. `InterpolationsRegridder` uses
   [Interpolations.jl](https://github.com/JuliaMath/Interpolations.jl) to
   perform non-conservative linear interpolation onto lat-long(-z) grids.
   `InterpolationsRegridder` works directly with data.

> ⚠️ Note: While the `Regridders` can be used independently, most users will find
> their needs are immediately met by the [`SpaceVaryingInputs` and
> `TimeVaryingInputs`](@ref) interfaces. These higher-level objects implement
> everything that is needed to read a file to the model grid (internally using
> the `Regridders`).

## `TempestRegridder`

> This extension is loaded when loading `ClimaCoreTempestRemap`

`TempestRegridder` performs conservative interpolation of lat-lon grids onto
computational domains. `TempestRegridder` performs all the interpolation ahead
of time and saves the regridded fields to HDF5 files that can be read during the
simulation.

### Example

Assuming `target_space` is a `ClimaCore` 2D spherical field, the input data is
the variable `u` in the file `era5_example.nc`, and we want to read the data
associated with date `target_date`.

```julia
import ClimaUtilities.Regridders
import ClimaCoreTempestRemap
# Loading ClimaCoreTempest automatically loads TempestRegridder

reg = Regridders.TempestRegridder(target_space, "regrid_output", "u", "era5_example.nc")
# When reg is created, the variable `u` is regridded and the output files
# are saved to the `regrid_output` folder

regridded_u = Regridders.regrid(reg, target_date)
```

## `InterpolationsRegridder`

> This extension is loaded when loading `ClimaCore` and `Interpolations`

`InterpolationsRegridder` performs linear interpolation of input data (linear
along each direction) and returns a `ClimaCore` `Field` defined on the
`target_space`.

Currently, `InterpolationsRegridder` only supports spherical shells and extruded
spherical shells (but it could be easily extended to other domains).

> Note: it is easy to change the spatial interpolation type and extrapolation
> conditions, if needed.

`InterpolationsRegridder` are created once, they are tied to a `target_space`,
but can be used with any input data. With MPI runs, every process computes the
interpolating function. This is always done on the CPU and moved to GPU for
accelerated runs.

### Example

Assuming `target_space` is a `ClimaCore` 2D spherical field.
```julia
import ClimaUtilities.Regridders
import ClimaCore, Interpolations
# Loading ClimaCore and Interpolations automatically loads InterpolationsRegridder

reg = Regridders.InterpolationsRegridder(target_space)

# Now we can regrid any data
lon = collect(-180:1:180)
lat = collect(-90:1:90)
# It has to be lon, lat (because this is the assumed order in the CF conventions)
dimensions = (lon, lat)

data = rand((length(lon), length(lat)))

interpolated_data = Regridders.InterpolationsRegridder(reg, data, dimensions)
interpolated_2data = Regridders.InterpolationsRegridder(reg, 2.*data, dimensions)
```

## API

```@docs
ClimaUtilities.Regridders.TempestRegridder
ClimaUtilities.Regridders.InterpolationsRegridder
ClimaUtilities.Regridders.regrid
```
