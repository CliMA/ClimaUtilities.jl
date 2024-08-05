# `SpaceVaringInputs` and `TimeVaryingInputs`

Most models require external inputs to work. Examples of inputs are an analytic
function that prescribes the sea-surface temperature in time, or a file that
describes the types of plants on the surface of the globe. The
`SpaceVaringInputs` and `TimeVaryingInputs` modules provide a unified
infrastructure to handle all these cases.

## `TimeVaryingInputs`

> This extension is loaded when loading `ClimaCore` is loaded. In addition to
> this, if NetCDF files are used, `NCDatasets` has to be loaded too. Finally, a
> `Regridder` is needed (which might require importing additional packages).

A `TimeVaryingInput` is an object that knows how to fill a `ClimaCore` `Field`
at a given simulation time `t`. `TimeVaryingInputs` can be constructed in a
variety of ways, from using analytic functions, to NetCDF data. They expose one
interface, `evaluate!(dest_field, tv, time)`, which can be used by model
developers to update their `Field`s.

This example shows that `TimeVaryingInput` can take different types of inputs
and be used with a single interface (`evaluate!`). In all of this,
`TimeVaryingInput`s internally handle all the complexity related to reading
files (using [`FileReaders`](@ref)), dealing with parallelism and GPUs,
regridding onto the computational domains (using [`Regridders`](@ref) and
[`DataHandling`](@ref)), and so on.

`TimeVaryingInputs` support:
- analytic functions of time;
- pairs of 1D arrays (for `PointSpaces`);
- 2/3D NetCDF files;
- linear interpolation in time (default) and nearest neighbors;
- boundary conditions and repeating periodic data.

It is possible to pass down keyword arguments to underlying constructors in the
`Regridder` with the `regridder_kwargs` and `file_reader_kwargs`. These have to
be a named tuple or a dictionary that maps `Symbol`s to values.

### Example

Let `target_space` be the computational domain (a `ClimaCore` `Space`) and
`cesm_albedo.nc` a NetCDF file containing albedo data as a function of time in a
variable named `alb`.

```julia
import ClimaUtilities: TimeVaryingInputs
import ClimaCore
import NCDatasets
import ClimaCoreTempestRemap
# Loading ClimaCore, NCDatasets, ClimaCoreTempestRemap loads the extensions we need

function evolve_model(albedo_tv, albedo_field)
    new_t = t + dt
    # First, we update the albedo to the new time
    evaluate!(albedo_field, albedo_tv, new_t)
    # Now we can do all the operations we want we albedo_filed
    # rhs = ...
end

# Let us prepare an empty Field that will contain the albedo
albedo_field = zero(target_space)

# If the albedo is an analytic function of time
albedo_tv_an = TimeVaryingInput((t) -> 0.5)

# If the albedo comes from data

# reference_date is the calendar date at the beginning of our simulation
reference_date = Dates.DateTime(2000, 1, 1)
albedo_tv = TimeVaryingInputs.TimeVaryingInput("cesem_albedo.nc", "alb", target_space;
                                               reference_date, regridder_kwargs = (; regrid_dir = "/tmp"))
# When using data from files, the data is automatically interpolated to the correct
# time

# In either cases, we can always call evolve_model(albedo_tv, albedo_field), so
# model developers do not have to worry about anything :)
```

`TimeVaryingInput`s can have multiple boundary conditions for extrapolation. By
default, the `Throw` condition is used, meaning that interpolating onto a point
that is outside the range of definition of the data is not allowed. Other
boundary conditions are allowed. With the `Flat` boundary condition, when
interpolating outside of the range of definition, return the value of the
of closest boundary is used instead.

Another boundary condition that is often useful is `PeriodicCalendar`, which
repeats data over and over.

In general `PeriodicCalendar` takes two inputs: the `period` and `repeat_date`.
The repeat period is a `Dates.DatePeriod` (e.g., `Dates.Year(1)`) that defines
the duration of the period that has to be repeated. The `repeat_date` defines
what date range needs to be repeated. For example, if `period = Dates.Month(1)`
and `repeat_date = Dates.Date(1993, 11)`, November 1993 will be repeated.

The two inputs are not required. When they are not provided, `ClimaUtilities`
will assume that the input data constitutes one period and use that. For
example, if the data is defined from `t0` to `t1` (e.g., 1 and 5), interpolating
over `t > t1` (e.g., 7) is equivalent to interpolating to `t*` where `t*` is the
modulus of `t` and the range (3 in this case). In this case, `PeriodicCalendar`
requires the data to be uniformly spaced in time. To enable this boundary
condition, pass `LinearInterpolation(PeriodicCalendar())` to the
`TimeVaryingInput` (or `NearestNeighbor(PeriodicCalendar())`).

> Note: this `PeriodicCalendar` is different from what you might be used to, where the
> identification is `t1 = t0`. Here, we identify `t1 + dt = t0`. This is so that
> we can use it to repeat calendar data.


## `SpaceVaryingInputs`

> This extension is loaded when loading `ClimaCore` is loaded. In addition to
> this, if NetCDF files are used, `NCDatasets` has to be loaded too. Finally, a
> `Regridder` is needed (which might require importing additional packages).

`SpaceVaryingInput`s uses the same building blocks as `TimeVaryingInput`
(chiefly the [`DataHandling`](@ref) module) to construct a `Field` from
different sources.

`TimeVaryingInputs` support:
- analytic functions of coordinates;
- pairs of 1D arrays (for columns);
- 2/3D NetCDF files.

In some ways, a `SpaceVaryingInput` can be thought as an alternative constructor
for a `ClimaCore` `Field`.

It is possible to pass down keyword arguments to underlying constructors in the
`Regridder` with the `regridder_kwargs` and `file_reader_kwargs`. These have to
be a named tuple or a dictionary that maps `Symbol`s to values.

### Example

Let `target_space` be a `ClimaCore` `Space` where we want the `Field` to be
defined on and `cesm_albedo.nc` a NetCDF file containing albedo data as a time
in a variable named `alb`.

```julia
```julia
import ClimaUtilities: SpaceVaryingInputs
import ClimaCore
import NCDatasets
import ClimaCoreTempestRemap
# Loading ClimaCore, NCDatasets, ClimaCoreTempestRemap loads the extensions we need

# Albedo as an analytic function of lat and lon
albedo_latlon_fun = (coord) -> 0.5 * coord.long * coord.lat

albedo = SpaceVaryingInputs.SpaceVaryingInput(albedo_latlon_fun)

albedo_from_file = SpaceVaryingInputs.SpaceVaryingInput("cesm_albedo.nc", "alb", target_space, regridder_kwargs = (; regrid_dir = "/tmp"))
```

## API

```@docs
ClimaUtilities.SpaceVaryingInputs.SpaceVaryingInput
ClimaUtilities.TimeVaryingInputs.AbstractInterpolationMethod
ClimaUtilities.TimeVaryingInputs.AbstractInterpolationBoundaryMethod
ClimaUtilities.TimeVaryingInputs.NearestNeighbor
ClimaUtilities.TimeVaryingInputs.LinearInterpolation
ClimaUtilities.TimeVaryingInputs.Throw
ClimaUtilities.TimeVaryingInputs.PeriodicCalendar
ClimaUtilities.TimeVaryingInputs.Flat
ClimaUtilities.TimeVaryingInputs.evaluate!
ClimaUtilities.TimeVaryingInputs.extrapolation_bc
Base.in
Base.close
```

